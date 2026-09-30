# 变更记录：Falco Helm 仓库访问失败排查 + 离线化改造

- 日期：2026-09-29
- 主机：192.168.21.134
- 触发问题：`read tcp 192.168.21.134:41344->185.199.111.153:443: read: connection reset by peer`
- 结论：DNS 正常、路由正常，故障在 ISP/骨干侧（对 GitHub Pages 网段 TCP 干扰 + 严重限速），本机无可修之处。

---

## 一、诊断证据（只读，未做任何修改）

| 检查项 | 结果 | 结论 |
|---|---|---|
| `dig falcosecurity.github.io` | `NOERROR`，A 记录 185.199.108–111.153 | DNS 正常，无污染 |
| `dig @114.114.114.114` | 同一组 IP | 多 resolver 一致 |
| `ip route` | `default via 192.168.21.2 dev ens160` | 路由正常 |
| `ip route get 185.199.111.153` | `via 192.168.21.2 dev ens160 src 192.168.21.134` | 出接口正确 |
| ping 网关 / 223.5.5.5 | 0% 丢包，MTU 1500 | 本地链路健康 |
| 按 IP 分别测试 | 108/109/110 TCP 连接超时；111 可连但 450 B/s–4.5 KB/s | 按 IP 施加的干扰+限速 |
| `curl -v` | TLS 1.3 握手成功、HTTP/2 `200`、20s 仅收 65KB/380KB | 非 DNS/证书/路由问题 |
| `ss -tlnp` | 无任何 HTTP/SOCKS 代理监听 | 无可用本地代理 |
| `date` / `timedatectl` | 2026-09-29，NTP 已同步 | 证书日期正常，非时钟问题 |

**判定**：TCP 能建连、TLS 能完成、HTTP 返回 200，说明问题不在本机；`connection reset by peer`
发生在握手后的数据传输阶段，是中间设备下发 RST 的典型特征。四个 GitHub Pages IP 全部受影响，
因此改 hosts / 换 IP / 调 DNS 均无效。

---

## 二、已执行的修改（全部经用户批准）

### 1. 新增文件：`charts/falco-9.2.0.tgz`（预置本地 chart）
```bash
cp -n /root/falco-9.2.0.tgz /root/security/charts/falco-9.2.0.tgz
```
- `cp -n`：不覆盖任何已有文件
- sha256：`5e0699e68e5e4abd5eab1d501b3e0300a15888f3a5c2b0977bf3ca3229a8d04a`（与源文件一致）
- 性质：官方**自包含**包 —— `falco/Chart.lock` 锁定并已内嵌 falcosidekick `0.14.0`、
  k8s-metacollector `0.3.2`、falco-talon `0.4.2`，`helm dependency list` 全部显示 `unpacked`
- 回滚：`rm /root/security/charts/falco-9.2.0.tgz`

### 2. 修改 `Makefile`（4 处）
| 位置 | 原值 | 新值 |
|---|---|---|
| L20–23 | `FALCO_CHART := charts/falco-4.10.0.tgz` | `FALCO_CHART := charts/falco-9.2.0.tgz` |
| L21 | `FALCOSIDEKICK_CHART := charts/falcosidekick-0.7.16.tgz` | 删除（内嵌子 chart，不再需要独立包） |
| L27 | `FALCO_TAG := 0.40.0` | `FALCO_TAG := 0.45.0`（对齐 chart appVersion） |
| L29 | `FALCOSIDEKICK_TAG := 2.27.0` | `FALCOSIDEKICK_TAG := 2.32.0` |
| L137 (`install-falco`) | 独立 `helm install falcosidekick ...` | 删除；改为 `--set falcosidekick.enabled=false` |
| L57 (`help`) | `安装 Falco + Falcosidekick` | `安装 Falco(内嵌 sidekick,module 驱动)` |

- 回滚：`git -C /root/security checkout -- Makefile`

### 3. 修改 `scripts/download-offline-resources.sh`（4 处）
1. **新增 `IMAGE_PREFIX` 变量**（默认空）：镜像可走内部代理/registry，
   例 `IMAGE_PREFIX=0wqcfr78pnd1zo9kvk.xuanyuan.run ./scripts/download-offline-resources.sh`；
   拉取后自动 `docker tag` 回规范名，保证节点上镜像名与 Helm values 一致。
2. **新增「预置即离线」检测**：`have_chart()` 检测 `charts/<name>-*.tgz`；
   若 `charts/falco-9.2.0.tgz` 存在，则 falcosidekick/k8s-metacollector/falco-talon 一并视为就绪，
   **完全跳过 `helm repo add/update` 与 `helm pull`**；仅当确有缺失时才触网。
3. **修正仓库名拼写**：`falosecurity` → `falcosecurity`（原脚本遗留的重复仓库项）。
4. **修正镜像清单与标签**：由 `helm template` 实测得出，改为
   `falcosecurity/falco:0.45.0`、`falcosecurity/falcoctl:0.14.2`、
   `falcosecurity/falco-driver-loader:0.45.0`、`falcosecurity/falcosidekick:2.32.0`
   （原脚本只有 falco `0.40.0` + sidekick `2.27.0`，**缺 falcoctl 与 driver-loader**，
   会导致节点上 ErrImagePull）。

- 回滚：`git -C /root/security checkout -- scripts/download-offline-resources.sh`
  （注意：该文件在本次会话前已有你未提交的本地改动，回滚会一并丢弃）

### 4. 修改 `KIND_NODE_IMAGE`：v1.31.2 → v1.37.0（Makefile + 下载脚本，两处对齐）
- 依据：本机 Docker 仅存在 `kindest/node:v1.37.0`，且**已存在的 `falco-opa-demo` 集群**正是基于它；
  `deploy/kind/kind.yaml` 未声明镜像（Makefile 注释说明以命令行为准），故只需改这两处。
- `Makefile` L16：`KIND_NODE_IMAGE := kindest/node:v1.37.0`
- `scripts/download-offline-resources.sh` L59/L61：`docker pull`/`docker save` 同步改为 v1.37.0
- 效果：`make cluster` 不再尝试拉取本机没有的 v1.31.2；已存在的集群与配置版本一致
- 回滚：两处分别改回 `kindest/node:v1.31.2`

### 5. 修复 `Makefile` 的 `load-images` 既有 bug：容器内 `/tmp` 是 tmpfs
- **现象**：`make load-images` 在第一个节点即失败：
  `>> [falco-opa-demo-control-plane] 导入 gatekeeper.tar` →
  `ctr: open /tmp/gatekeeper.tar: no such file or directory`
- **根因（实测取证，非推测）**：kind 节点容器内 `/tmp` 是独立 **tmpfs**：
  ```
  tmpfs on /tmp type tmpfs (rw,nosuid,nodev,noexec,relatime,seclabel,inode64)
  ```
  而 `docker cp` 写入容器 **overlay 层**；overlay 上的 `/tmp/xxx` 被 tmpfs 挂载点**遮挡**，
  因此 `docker exec ... ctr ... /tmp/xxx` 看不到该文件（`docker cp` 自身返回 0，极具迷惑性）。
- **修复**：容器内临时路径 `/tmp/$$bname` → `/root/$$bname`（overlay 层，`ctr` 可见）
- **验证**：手动 `docker exec $NODE ctr -n k8s.io images import /gatekeeper.tar` 成功，
  节点内 `ctr -n k8s.io images ls` 出现 `docker.io/openpolicyagent/gatekeeper:v3.23.1` ✓
- 涉及 `Makefile` L112–114（`docker cp` / `ctr import` / `rm -f` 三处路径）
- 回滚：三处 `/root/` 改回 `/tmp/`

### 6. 磁盘空间处置（执行离线资源拉取的前置条件）
- **问题**：根分区初始仅剩 **2.1G**，而拉镜像 + 导出 tar 约需 5.4G；
  后续镜像导入到 3 个 kind 节点还要在每个节点内解压，实测触发
  `ctr: failed to extract layer ... no space left on device`。
- **已删除（均为可再生或孤儿数据，已记录）**：
  | 对象 | 大小 | 说明 |
  |---|---|---|
  | `/root/trivy_cache` | 2.8G | 独立 trivy 扫描缓存（与 Harbor 的 `trivy-cache` 卷无关，可重新生成） |
  | `goharbor/*:v2.10.2` 共 12 个镜像 | ~2.4G | 无任何容器引用；Harbor 当前运行版为 v2.15.2 |
  | `/harbor-offline-installer-v2.15.2.tgz` | 697M | Harbor 安装包，已安装完毕 |
  | `/harbor/harbor.v2.15.2.tar.gz` | 702M | 同上 |
  | docker 孤儿卷 `minikube` | 702M | 无任何容器引用 |
  | `/root` 下重复的 gatekeeper tar ×4 | ~146M | 仓库 `images/` 内已有 |
  | `/root/kubernetes-goat`、`httpd-2.4.68`、`git-dumper` 等 | ~316M | 旧项目/源码包 |
- **未触碰**：运行中的 `falco-opa-demo` 三节点集群、Harbor v2.15.2 全部 12 个镜像、
  `kindest/node:v1.37.0` 镜像、`/etc` 下任何文件。
- 未能回收：`/var/cache/PackageKit`（约 1.0G）在受限沙箱下报只读，不影响结果。

### 7. 离线资源落地（本次实际产出）
| 产物 | 内容 | 大小 |
|---|---|---|
| `images/falco.tar` | falco:0.45.0 + falcoctl:0.14.2 + falco-driver-loader:0.45.0 + falcosidekick:2.32.0 | 460M |
| `images/gatekeeper.tar` | openpolicyagent/gatekeeper:v3.23.1 | 55M |
| `images/mysql.tar` | mysql:8.0 | 238M |
| `images/kindest-node.tar` | kindest/node:v1.37.0 | 371M |
| `wheels/*.whl` | requirements.txt 全部依赖 + pymysql | 32 个 |

- 镜像经 Docker daemon 已配置的加速器 `https://0wqcfr78pnd1zo9kvk.xuanyuan.run` 拉取
- wheels 经清华 PyPI 镜像 `https://pypi.tuna.tsinghua.edu.cn/simple` 下载
- 为腾出空间（根分区仅剩 2.1G）删除了以下**可再生/孤儿**数据：
  `/root/trivy_cache`（2.8G，独立 trivy 扫描缓存）、`/harbor-offline-installer-v2.15.2.tgz`（697M）、
  `/harbor/harbor.v2.15.2.tar.gz`（702M，Harbor 已安装完毕）、docker 孤儿卷 `minikube`（702M）。
  **未触碰**运行中的 `falco-opa-demo` 集群、Harbor v2.15.2 运行态及 `kindest/node:v1.37.0` 镜像。
  （`/var/cache/PackageKit` 约 1.0G 因沙箱只读未能回收，不影响结果）

### 8. 修复 `Makefile` 两处导致 Falco 无法启动的既有 bug（本轮实测发现）
#### 6a. `driver.kind=module` → `modern_ebpf`
- **现象**：pod 卡在 `Init:0/1`，`falco-driver-loader` 反复重启，最终
  `ERROR failed: failed to build requested driver`
- **根因（实测）**：
  ```
  ├ driver type: kmod
  ├ kernel release: 5.14.0-611.36.1.el9_7.x86_64
  Trying to download a driver. url: https://download.falco.org/driver/...
  WARN Non-200 response from url. code: 404      ← 无预编译驱动
  Error! Your kernel headers for kernel 5.14.0-611.36.1.el9_7.x86_64 cannot be found
         at /lib/modules/5.14.0-611.36.1.el9_7.x86_64/build or .../source
  ERROR failed: failed to build requested driver
  ```
  `driver.kind=module`(kmod) 需**本机编译内核模块**；本机 `/usr/src/kernels` 为空
  （未安装 `kernel-devel`），且预编译驱动 404 → 离线环境必然失败。
- **修复**：改用 `driver.kind=modern_ebpf`（CO-RE），无需内核头文件、无需联网。
- **前提已验证**：三个节点与宿主机均存在 `/sys/kernel/btf/vmlinux` ✓；
  `helm template --set driver.kind=modern_ebpf` 渲染出的
  `falco-driver-loader` init 容器数量为 **0**（kmod 下为 1）。

#### 6b. `falcoctl.config.artifact.*` → `falcoctl.artifact.*`（**离线开关此前从未生效**）
- **现象**：即使加了关闭参数，DaemonSet 仍渲染出 `falcoctl-artifact-install` init 容器与
  `falcoctl-artifact-follow` sidecar，运行期持续从 `ghcr.io` 拉取插件/规则，卡死 20 小时
- **根因（读 values 缩进取证）**：values.yaml 真实层级为
  ```yaml
  falcoctl:
    artifact:        # ← 真正的开关
      install: { enabled: true }
      follow:  { enabled: true }
    config:          # ← 只是 falcoctl 配置文件内容(indexes / allowedTypes)
  ```
  Makefile 原先写的 `falcoctl.config.artifact.install.enabled=false` **指向不存在的键**，
  故该"离线开关"从未生效。
- **离线渲染对照**（`helm template` 统计）：
  | 路径 | artifact-install | artifact-follow |
  |---|---|---|
  | `falcoctl.config.artifact.*`（原值） | 1（仍在） | 1（仍在） |
  | `falcoctl.artifact.*`（修正后） | **0** | **0** |
- 修正后 DaemonSet 仅剩 `falco-driver-loader` + `falco`（modern_ebpf 下连 driver-loader 也不需要）。

#### 6c. 最终验证结果（离线，全链路）
```
kubectl get pods -n falco-system
falco-g6hdk   1/1   Running   0   (worker2)
falco-lksmz   1/1   Running   0   (worker)
falco-pbwmr   1/1   Running   0   (control-plane)

helm list -n falco-system → STATUS=deployed  CHART=falco-9.2.0  APP VERSION=0.45.0

falco 日志：
  Loading rules from: /etc/falco/falco_rules.yaml | schema validation: ok
  Loaded event sources: syscall
  Opening 'syscall' source with modern BPF probe.
```
**运行时检测实测**：在节点内执行 `cat /etc/shadow` 后，falco 产出真实告警：
```
Warning Sensitive file opened for reading by non-trusted program | file=/etc/shadow
  process=cat command=cat /etc/shadow
```
证明规则加载、modern_ebpf 引擎与事件检测全链路可用（**全程无外网依赖**）。

### 9. 补齐演示所需的 4 处改动（使 POC 真正可演示）

#### 9a. 新增 `deploy/falco/custom-rules.yaml`（自定义攻击链规则）
- **问题**：Falco 默认规则名（`Drop and execute new binary in container` 等）不含
  `stage1`/`shell`/`shadow`/`privilege` 关键词，而 `src/parser.py` 按这些关键词判定
  `attack_stage` → 阶段恒为 0、攻击链永不完结、动态策略无镜像可封。
- **方案**：新增 4 条规则 `[STAGE1] Shell Spawned In Container` ~
  `[STAGE4] Container Escape / Lateral Movement`，规则名带 `[STAGEn]` 前缀与解析器对齐；
  `condition` 带 `container and k8s.ns.name != ""`（只在容器事件触发，避开宿主机 mount 噪声）；
  `output` 中**显式写 `container_image=%container.image.repository`**，保证解析器能取到镜像。
- **验证**：`falco --validate` 校验通过（`successful: true`，无 errors/warnings）。
- 通过 `make install-falco` 的 `--set-file 'customRules.custom-rules\.yaml=...'` 注入，
  落到 `/etc/falco/rules.d/custom-rules.yaml`。

#### 9b. 重写 `tests/pochack`：改用显式 YAML + `imagePullPolicy: Never`
- **问题**：原脚本用 `kubectl run --image=alpine:latest`，kubectl 对 `:latest` 默认
  **`imagePullPolicy=Always`** → kubelet 强制联网校验 digest → 离线必然
  `ImagePullBackOff`，Pod 起不来，攻击阶段无法被检测。
- **方案**：改为显式 YAML 清单并设 `imagePullPolicy: Never`（只用节点本地镜像）；
  同时修正 `cleanup` 为 `--wait=true`（否则旧 Pod 仍 Terminating，`apply` 会报
  `pod updates may not add or remove containers`）。
- 镜像名可用环境变量 `POC_IMAGE` 覆盖。

#### 9c. 修复 `src/hmac_auth.py` / `main.py`
- `hmac_auth.py` 新增 `WEBHOOK_REQUIRE_SIGNATURE` 开关（默认 `true` 保持安全）。
  原因：falcosidekick **不支持生成 HMAC 签名**，强制校验会导致全部告警被 401 拒绝。
  演示用 `WEBHOOK_REQUIRE_SIGNATURE=false` 启动。
- `main.py`：`parse_falco_output(text, alert.get('output_fields'))` 传入结构化字段；
  并修正"策略创建失败也打印已部署"的误导日志。

#### 9d. 修复 `src/parser.py` 的镜像/容器 ID 提取
- 原正则写 `container=` / `image=`，而 Falco 实际输出 `container_id=` /
  `container_image_repository=`，导致 `container_image` 恒为 `None`。
- 改为**优先读 `output_fields`**（`container.id` / `container.image.repository`），
  正则仅作回退并补充 `container_image_repository=` 分支。

### 10. 演示最终实测结果（完整闭环打通）
```
[Stage 1] → pod/stage1-shell      Running
[Stage 2] → pod/stage2-read       Completed
[Stage 3] → pod/stage3-privileged Completed
[Stage 4] → Error from server (Forbidden): admission webhook "validation.gatekeeper.sh"
              denied: [dynamic-block-chain-b7ba35123f9c] [DYNAMIC BLOCK] hostPath 挂载已被动态策略禁止

Falco 命中： [STAGE1] 2 次  /  [STAGE3] 33 次
alerts：      [STAGE1] stage=1 / Read sensitive file untrusted stage=2 / [STAGE3] stage=2
dread_scores：8.80 CRITICAL
dynamic_policies：dynamic-block-chain-b7ba35123f9c | docker.io/library/alpine | CRITICAL
k8simagepolicy：  baseline-image-policy dryrun / dynamic-block-chain-b7ba35123f9c deny
```
**Stage 4 在准入阶段即被拦截，Pod 根本未创建** —— 检测→联动→动态准入闭环成立。
演示运行说明见 [RUN-DEMO.md](RUN-DEMO.md)。


---

## 四、验证结果（均为离线）

| 验证项 | 结果 |
|---|---|
| `bash -n` 脚本语法 | 通过 |
| `make -n install-falco` | 渲染出正确的 helm 命令，无悬空变量 |
| `grep FALCOSIDEKICK_CHART Makefile` | 无残留引用 |
| 检测逻辑单元测试（3 场景） | 两包齐全→跳过触网；仅 gatekeeper→需要触网；空目录→需要触网 ✓ |
| `helm template charts/falco-9.2.0.tgz`（同 Makefile 参数） | exit 0，渲染 4 个资源（DaemonSet/ServiceAccount/2×ConfigMap），无 stderr 告警 |
| **`make load-images` 真实导入** | 3 个节点全部成功；`ctr images ls` 可见 falco/falcoctl/driver-loader/gatekeeper |
| **falco pod 运行态** | `falco-g6hdk`/`falco-lksmz`/`falco-pbwmr` 均 `1/1 Running`，0 重启 |
| **helm release** | `falco` REVISION=4 `STATUS=deployed` `CHART=falco-9.2.0` `APP=0.45.0` |
| **运行时检测实测** | 节点内 `cat /etc/shadow` → falco 产出告警 `Warning Sensitive file opened for reading by non-trusted program` ✓ |

---

## 五、当前状态与待办

### 已完成
- `charts/`、`images/*.tar`（4 个）、`wheels/*.whl`（32 个）均已就绪
- `make load-images` 离线导入已验证可用；falco 已完全离线跑起来并具备检出能力
- 根分区空间 1.7G 可用（96%），运行不受影响

### 待你决定
1. **告警链路**：`--set falcosidekick.enabled=false` 后 Falcosidekick 不再部署，
   `WEBHOOK_ADDRESS` 指向的 Python webhook 收不到 Falco 告警。
   如需恢复，在 `install-falco` 中改为：
   ```
   --set falcosidekick.enabled=true \
   --set falcosidekick.image.repository=$(FALCOSIDEKICK_REPO) \
   --set falcosidekick.image.tag=$(FALCOSIDEKICK_TAG) \
   --set falcosidekick.config.webhook.address=$(WEBHOOK_ADDRESS) \
   ```
   （镜像 `falcosidekick:2.32.0` 已在各节点，启用后无需重新导入）
2. **重跑 `make deploy-components` 前须先卸载旧 release**：
   当前 `falco-system` 下 falco release 已是 `deployed`（revision 4）。
   `install-falco` 用的是 `helm install`，重复执行会报
   `cannot re-use a name that is still in use`。正确做法二选一：
   ```
   helm uninstall falco -n falco-system   # 然后 make deploy-components
   # 或将 Makefile 的 install-falco 改为 helm upgrade --install
   ```
3. **本机已有 `falco-opa-demo` 集群**：不要在已有集群上跑 `make cluster`
   （kind 会报 already exists），请改用 `make deploy-components`（该目标本就跳过建集群）。
4. **外网方案**（若日后要恢复联网拉取）：经代理可用
   `export https_proxy=http://<proxy>:<port>`；镜像建议走 `IMAGE_PREFIX` 指向的镜像代理。
