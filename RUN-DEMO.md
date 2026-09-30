# 演示运行指南（RUN-DEMO）

> 全部命令均于 2026-09-30 在本机（192.168.21.134）**实测通过**。
> 详细变更记录见 [CHANGES-offline-falco.md](CHANGES-offline-falco.md)。

---

## 一、环境状态（全部就绪，无需外网）

| 组件 | 状态 |
|---|---|
| Kind 集群 `falco-opa-demo` | ✅ 3 节点 Ready（control-plane + 2 worker，v1.37.0） |
| Gatekeeper | ✅ 4 pod Running，准入拦截已实测生效 |
| Falco | ✅ 3 pod Running，**modern_ebpf** 引擎 + **自定义 STAGE 规则已加载** |
| Falcosidekick | ✅ 2 pod Running，webhook 指向宿主机 Python 服务 |
| MySQL `falco-db` | ✅ 库 `falco_alerts`，3 张表已建 |
| Python 联动服务 | ✅ venv 依赖已装（离线 wheels） |
| 离线资源 | ✅ `charts/` `images/` `wheels/` 齐备 |

---

## 二、启动演示（三步）

### 步骤 1：启动 Python 联动服务

```bash
cd /root/security
export KUBECONFIG=$HOME/.kube/config
WEBHOOK_REQUIRE_SIGNATURE=false ./venv/bin/python -u main.py
```

监听 `0.0.0.0:8080`；集群内经宿主机网关 `172.18.0.1:8080` 访问。
自检：`curl -s http://127.0.0.1:8080/health` → `{"status":"ok"}`

> `WEBHOOK_REQUIRE_SIGNATURE=false` 的原因见第五节第 1 条。

### 步骤 2：确认 Falcosidekick 指向该服务（已配好，通常无需操作）

```bash
kubectl get secret -n falco-system falco-falcosidekick \
  -o jsonpath='{.data.WEBHOOK_ADDRESS}' | base64 -d; echo
# 期望输出： http://172.18.0.1:8080/webhook
```

如需重新指向：

```bash
helm upgrade falco charts/falco-9.2.0.tgz -n falco-system --reuse-values \
  --set falcosidekick.enabled=true \
  --set falcosidekick.config.webhook.address=http://172.18.0.1:8080/webhook \
  --timeout 8m
```

### 步骤 3：执行攻击演示

```bash
make attack          # 等价于 bash tests/pochack
```

---

## 三、实测结果（本机真实输出）

执行 `make attack` 后：

```
[Stage 1] 模拟异常 shell 启动...        → pod/stage1-shell    created (Running)
[Stage 2] 模拟敏感文件读取...            → pod/stage2-read     created (Completed)
[Stage 3] 模拟特权容器创建（提权）...    → pod/stage3-privileged created (Completed)
[Stage 4] 模拟 hostPath 挂载（容器逃逸）...
  Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request:
    [dynamic-block-chain-b7ba35123f9c] [DYNAMIC BLOCK] hostPath 挂载已被动态策略禁止
```

**Stage 4 在准入阶段就被拦下，Pod 根本没能创建** —— 这正是"检测 → 联动 → 动态准入"闭环的体现。

### 各环节验证

```bash
# 1) Falco 告警（自定义 STAGE 规则 + 默认规则同时命中）
kubectl logs -n falco-system -l app.kubernetes.io/name=falco -c falco --tail=50 \
  | grep -oE '"rule":"\[STAGE[0-9]\][^"]*"' | sort | uniq -c
#  实测： 2 "[STAGE1] Shell Spawned In Container"
#        33 "[STAGE3] Privilege Escalation Attempt In Container"

# 2) 告警入库 + 攻击阶段识别
docker exec falco-db mysql -u root -p0 -e \
  "USE falco_alerts; SELECT id,rule_name,priority,attack_stage FROM alerts ORDER BY id DESC LIMIT 8;"
#  实测含： [STAGE1] ... stage=1
#           Read sensitive file untrusted  stage=2
#           [STAGE3] ... stage=2

# 3) DREAD 评分
docker exec falco-db mysql -u root -p0 -e \
  "USE falco_alerts; SELECT alert_id,total_score,risk_level FROM dread_scores ORDER BY id DESC LIMIT 5;"
#  实测： 8.80  CRITICAL

# 4) 自动生成的动态策略
docker exec falco-db mysql -u root -p0 -e \
  "USE falco_alerts; SELECT policy_name,blocked_images,severity FROM dynamic_policies;"
#  实测： dynamic-block-chain-b7ba35123f9c | docker.io/library/alpine | CRITICAL

# 5) 集群中的 OPA 约束
kubectl get k8simagepolicy
#  实测： baseline-image-policy              dryrun   20
#        dynamic-block-chain-b7ba35123f9c   deny     20
```

---

## 四、攻击链是怎么串起来的

```
Falco(modern_ebpf) 捕获 syscall
   │  自定义规则 [STAGE1..4] + 默认规则，output 中携带 container_image=
   ▼
Falcosidekick  ── webhook ──▶  http://172.18.0.1:8080/webhook  (宿主机 Python)
   │
   ▼
main.py：解析(output_fields 优先) → 时间窗口聚合攻击链 → DREAD 评分 → 入库
   │  risk_level 达 HIGH/CRITICAL（或攻击链 ≥3 阶段）
   ▼
src/image_policy.py 生成 K8sImagePolicy Constraint  ──▶  K8s API (deny)
   │
   ▼
Gatekeeper 拦截后续恶意 Pod（黑名单镜像 / 特权容器 / hostPath）
```

`src/parser.py` 的 `attack_stage` 按规则名/输出中的关键词判定：
`STAGE1`→1、`STAGE2`/`shadow`/`sensitive file`→2、`STAGE3`/`privilege`→3、
`STAGE4`/`drop and execute`→4。**自定义规则名刻意带上 `[STAGE1]`~`[STAGE4]` 前缀**，
就是为了和这套判定对齐（Falco 默认规则名不含这些关键词）。

---

## 五、注意事项与已知限制

### 1. HMAC 签名在演示时已关闭（生产须恢复）
`main.py` 默认强制校验 `X-Signature`，但 **falcosidekick 无法生成 HMAC 签名**
（只支持静态 `customHeaders`，不能对逐条变化的 payload 计算摘要）。
故演示用 `WEBHOOK_REQUIRE_SIGNATURE=false` 启动。
**生产环境应保持默认 `true`**，并在网关/反向代理层注入签名。

### 2. POC 必须用 `imagePullPolicy: Never`（离线关键）
`kubectl run --image=alpine:latest` 对 `:latest` 标签默认 `imagePullPolicy=Always`，
会强制 kubelet 联网校验 digest，**离线必然 ImagePullBackOff**。
`tests/pochack` 已改为显式 YAML + `imagePullPolicy: Never`（只用节点本地镜像）。
若更换镜像名，需先 `make load-images` 或手工导入。

### 3. 基线策略是 dryrun，动态策略才是 deny
`baseline-image-policy` 设为 `enforcementAction: dryrun`（仅审计），
目的是让攻击阶段能成功创建、从而被 Falco 检测到；
真正的阻断由**攻击链触发生成的 `deny` 策略**体现。这是刻意设计，不是缺陷。

### 4. 集群 DNS 曾故障（已修复，但需留意）
CoreDNS 的 kubernetes 插件曾未同步（`waiting for Kubernetes API`），
导致 `falco-falcosidekick` 域名无法解析、Falco 报 `Couldn't resolve host name`，
告警送不出去。已用 `kubectl rollout restart deployment coredns -n kube-system` 恢复。
**若发现告警不入库，先查 CoreDNS。**

### 5. Kind 节点无法自行拉镜像
`registry-1.docker.io` 被污染（实测解析到 `31.13.82.33`/`174.37.54.20` 等 → `connection refused`）。
所有镜像必须走 `make load-images`（`docker save` → `docker cp` → 节点内 `ctr import`）。

### 6. 告警噪声
宿主机 kubelet 的 mount/umount 会持续触发 `Drop and execute new binary in container`
（DREAD 8.8 CRITICAL）。这类事件 `k8s_pod_name=<NA>`、无镜像信息，不会误生成封禁策略，
但会占用告警表。如需降噪可调 `falcosidekick.config.minimumpriority` 或补充 falco 规则例外。

---

## 六、从零重新部署

```bash
cd /root/security
export KUBECONFIG=$HOME/.kube/config
# 本机已有集群 → 用 deploy-components（make deploy 会尝试重建集群而失败）
helm uninstall falco -n falco-system 2>/dev/null   # install-falco 用 helm install,需先卸载
make deploy-components
```

> 之后按第二节三步启动服务并演示。
