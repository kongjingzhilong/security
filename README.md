# 🛡️ 基于 Falco 与 OPA 的云原生容器多步攻击检测与动态准入控制系统

> 全离线一键部署：可全程不访问外网完成部署。
> 规避 Kind `kind load docker-image` 的 digest 校验问题，改用
> `docker save → docker cp → 节点内 ctr import`，多节点集群镜像 100% 导入成功。

## 架构

```
┌────────────┐   告警 Webhook   ┌──────────────────────────┐   动态策略   ┌──────────────┐
│   Falco    │ ───────────────▶ │ Python 联动服务 (main.py) │ ──────────▶ │ OPA Gatekeeper│
│ (modern_ebpf)│   (可 HMAC 签名) │ 解析→时间窗口→DREAD→策略  │  Constraint │  (准入拦截)   │
└────────────┘                  └─────────────┬────────────┘              └──────────────┘
       ▲                                       │ 写入告警/评分/策略
       │                                       ▼
┌──────┴──────┐                        ┌──────────────┐
│Falcosidekick│                        │    MySQL     │
│  (转发器)    │                        │ falco_alerts │
└─────────────┘                        └──────────────┘
```

## 文档索引

| 文档 | 内容 |
|---|---|
| **本文件** | 项目总览、部署流程、验证方法 |
| [docs/OFFLINE-RESOURCES.md](docs/OFFLINE-RESOURCES.md) | **离线资源获取指南**：需要哪些 Chart/镜像/wheel、怎么获取、体积与配额 |
| [RUN-DEMO.md](RUN-DEMO.md) | **演示运行指南**：三步启动、验证命令、实测结果、注意事项 |
| [CHANGES-offline-falco.md](CHANGES-offline-falco.md) | 离线化改造的完整变更台账（含每项问题的根因取证与回滚方法） |
| [docs/项目计划书.md](docs/项目计划书.md) | 系统设计、DREAD 模型、实验方案 |
| [Warning.md](Warning.md) | 安全与法律须知（**运行 POC 前必读**） |

## 目录结构

```
security/
├── charts/                    # 离线 Helm Chart（Git LFS 管理）
│   ├── falco-9.2.0.tgz        #   自包含包：sidekick/metacollector/talon 已内嵌
│   └── gatekeeper-3.23.1.tgz
├── images/                    # 离线镜像 tar（不入库，由下载脚本生成）
│   ├── kindest-node.tar       #   宿主机 docker load
│   ├── mysql.tar              #   宿主机 docker run
│   ├── gatekeeper.tar         #   节点 ctr import
│   └── falco.tar              #   节点 ctr import（falco+falcoctl+driver-loader+sidekick）
├── wheels/                    # Python 离线依赖（32 个 wheel）
├── scripts/
│   └── download-offline-resources.sh   # 外网机执行，产出上述资源
├── deploy/
│   ├── kind/kind.yaml         # Kind 多节点集群配置（control-plane + 2 worker）
│   ├── helm/helm.yaml         # OPA ConstraintTemplate + Constraint
│   └── falco/custom-rules.yaml # 自定义攻击链规则 [STAGE1]~[STAGE4]
├── src/
│   ├── db.py                  # MySQL 操作（pymysql）
│   ├── dread.py               # DREAD 风险评估
│   ├── parser.py              # Falco 告警解析（优先读结构化 output_fields）
│   ├── time_window.py         # 时间窗口攻击链关联
│   ├── hmac_auth.py           # Webhook HMAC 认证（可开关）
│   ├── image_policy.py        # 动态策略生成
│   └── k8s_client.py          # K8s API 客户端
├── sql/init.sql               # 数据库初始化（alerts/dread_scores/dynamic_policies）
├── tests/pochack              # POC 多步攻击模拟脚本
├── dataset/test               # 离线测试数据集
├── main.py                    # Webhook 核心入口
└── Makefile                   # 一键离线部署
```

## 快速开始

### 步骤 1：在外网机生成离线资源（一次性）

```bash
bash scripts/download-offline-resources.sh
```

详见 [docs/OFFLINE-RESOURCES.md](docs/OFFLINE-RESOURCES.md)。
完成后把整个目录拷贝到内网部署机。

### 步骤 2：内网部署

```bash
# 前置：Docker + Kind + kubectl + Helm 已安装，且磁盘留足 8~10GB
make deploy              # 建集群 → 导镜像 → Gatekeeper → Falco → MySQL → 策略
# 已有集群时改用：
make deploy-components   # 跳过建集群
```

### 步骤 3：启动联动服务

```bash
python3 -m venv venv
./venv/bin/pip install --no-index --find-links=wheels -r requirements.txt

export KUBECONFIG=$HOME/.kube/config
WEBHOOK_REQUIRE_SIGNATURE=false ./venv/bin/python -u main.py
```

### 步骤 4：执行攻击演示

```bash
make attack              # 另开终端
```

完整演示说明与实测结果见 [RUN-DEMO.md](RUN-DEMO.md)。

## Makefile 目标一览

| 目标 | 说明 |
|---|---|
| `make help` | 显示所有可用目标 |
| `make load-host-images` | 载入宿主机 Docker 镜像（kindest/node + mysql） |
| `make cluster` | 创建 Kind 多节点集群 |
| `make load-images` | **离线导入镜像到全部节点**（docker cp + ctr import） |
| `make install-gatekeeper` | 本地 Chart 安装 Gatekeeper |
| `make install-falco` | 本地 Chart 安装 Falco（modern_ebpf + 自定义规则） |
| `make install-db` | 启动 MySQL 容器并加载表结构 |
| `make load-policies` | 加载 OPA ConstraintTemplate/Constraint |
| `make start-service` | 启动 Python 联动服务 |
| `make attack` | 执行攻击 POC 演示 |
| `make deploy` | 一键完整部署 |
| `make deploy-components` | 已有集群时只装组件 |
| `make clean` | 清理集群与 MySQL 容器 |

## 关键设计说明

### 为何不用 `kind load`

`kind load docker-image` 在多架构镜像经镜像代理中转后，镜像摘要与官方不一致，
会报 `content digest not found`。本仓库改用底层路径：

```
docker save 镜像 → tar
   ↓ docker cp 传入每个 Kind 节点容器（节点名 = Docker 容器名）
   ↓ docker exec 节点内 `ctr -n k8s.io images import`
```

> 注意：Kind 节点内 `/tmp` 是 tmpfs，会遮挡 `docker cp` 写入 overlay 的文件，
> 因此导入路径用 `/root/` 而非 `/tmp/`。

### 为何用 modern_ebpf 而非 kmod

`driver.kind=module`（kmod）需要 DKMS 在本机编译内核模块，要求安装 `kernel-devel`
并能下载预编译驱动 —— 离线环境下两者都不具备，必然失败。
本项目改用 `driver.kind=modern_ebpf`（CO-RE），无需内核头文件与网络，
前提是内核支持 BTF（`/sys/kernel/btf/vmlinux` 存在）。

### 部署顺序

严格为：集群 → **导入镜像** → 安装组件。先铺镜像再装组件，
避免 Gatekeeper CRD Hook 启动 Pod 时无镜像导致 `helm install --wait` 超时。

## 部署验证

```bash
# 1) 集群节点
kubectl get nodes                                    # 全部 Ready

# 2) Gatekeeper
kubectl get pods -n gatekeeper-system                # 全部 Running

# 3) Falco（3 节点应有 3 个 Pod，1/1 Running）
kubectl get ds -n falco-system
kubectl get pods -n falco-system -o wide

# 4) 自定义攻击链规则已加载
kubectl exec -n falco-system \
  $(kubectl get pods -n falco-system -l app.kubernetes.io/name=falco -o name | head -1) \
  -c falco -- ls /etc/falco/rules.d/
# 期望: custom-rules.yaml

# 5) MySQL
docker exec falco-db mysql -u root -p0 -e 'USE falco_alerts; SHOW TABLES;'
# 期望: alerts / dread_scores / dynamic_policies

# 6) OPA 策略生效
kubectl get constrainttemplates
kubectl get k8simagepolicy
```

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DB_HOST` | 127.0.0.1 | MySQL 主机 |
| `DB_PORT` | 3306 | MySQL 端口 |
| `DB_USER` | root | MySQL 用户 |
| `DB_PASS` | 0 | MySQL 密码（与 `make install-db` 一致） |
| `DB_NAME` | falco_alerts | 数据库名 |
| `WEBHOOK_SECRET` | falco-opa-shared-secret-key | Falcosidekick HMAC 共享密钥 |
| `WEBHOOK_REQUIRE_SIGNATURE` | `true` | 是否强制校验 HMAC 签名。设为 `false` 可放行无签名请求 |
| `KUBECONFIG` | ~/.kube/config | K8s 配置 |
| `IMAGE_PREFIX` | 空 | 镜像加速器前缀（仅下载脚本使用） |
| `POC_IMAGE` | alpine:latest | 攻击演示所用镜像（仅 pochack 使用） |

> **关于 `WEBHOOK_REQUIRE_SIGNATURE`**：falcosidekick 的 webhook 输出
> **不支持生成 HMAC 签名**（仅有静态 `customHeaders`，无法对逐条变化的 payload
> 计算摘要）。因此在演示/联调环境需设为 `false`；**生产环境应保持 `true`**，
> 并在网关或反向代理层注入签名。

## 业务流程

1. Falco（modern_ebpf）捕获容器系统调用，命中自定义规则 `[STAGE1]`~`[STAGE4]`
   或默认规则（如 `Read sensitive file untrusted`）
2. Falcosidekick 转发到 Python 服务（可选 HMAC 签名）
3. `main.py`：校验签名 → 解析告警（优先取结构化字段）→ 时间窗口聚合攻击链
   → DREAD 评分 → 入库
4. 攻击链完成（≥3 阶段）或风险等级达 HIGH/CRITICAL 时，生成动态 OPA Constraint
5. Gatekeeper 准入引擎拦截后续恶意 Pod（镜像黑名单 / 特权容器 / hostPath）

## ⚠️ 安全警告

见 [Warning.md](Warning.md)。本项目含攻击模拟代码（`tests/pochack`），
仅用于安全研究和教学演示：

- **禁止**在生产环境运行 POC
- **禁止**用于任何非法目的
- 演示必须在隔离的测试环境进行
- 测试完成后执行 `make clean` 清理环境
