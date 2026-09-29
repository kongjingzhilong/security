# 🛡️ 基于 Falco 与 OPA 的云原生容器多步攻击检测与动态准入控制系统

> 全离线一键部署版：git clone 后全程不访问外网即可完成部署。
> 完全规避 Kind `kind load docker-image` digest 校验 bug，多节点集群镜像 100% 导入成功。

## 架构

```
┌────────────┐    告警Webhook     ┌──────────────────────────┐     动态策略      ┌──────────────┐
│   Falco    │ ─────────────────▶ │  Python 联动服务 (main.py) │ ───────────────▶ │ OPA Gatekeeper│
│ (eBPF/驱动) │   HMAC 签名        │  解析→时间窗口→DREAD→策略 │   Constraint     │  (准入拦截)    │
└────────────┘                    └─────────────┬────────────┘                  └──────────────┘
       ▲                                         │ 写入告警/评分/策略
       │                                         ▼
┌──────┴──────┐                          ┌──────────────┐
│Falcosidekick│                          │    MySQL     │
│  (转发器)    │                          │ falco_alerts │
└─────────────┘                          └──────────────┘
```

## 目录结构

```
security/
├── charts/                    # 离线 Helm Chart tgz 包
│   ├── gatekeeper-3.23.1.tgz
│   ├── falco-4.10.0.tgz
│   └── falcosidekick-0.7.16.tgz
├── images/                    # 离线镜像 tar 包
│   ├── kindest-node.tar       #   宿主机 docker load
│   ├── mysql.tar              #   宿主机 docker run
│   ├── gatekeeper.tar         #   节点 ctr import
│   └── falco.tar              #   节点 ctr import(falco + falcosidekick 合并)
├── scripts/
│   └── download-offline-resources.sh   # 外网机执行,生成上述离线资源
├── deploy/
│   ├── kind/kind.yaml         # Kind 多节点集群配置(control-plane + 2 worker)
│   └── helm/helm.yaml         # OPA ConstraintTemplate + Constraint
├── src/
│   ├── db.py                  # MySQL 数据库操作(pymysql)
│   ├── dread.py               # DREAD 风险评估
│   ├── parser.py              # Falco 告警解析
│   ├── time_window.py         # 时间窗口攻击链关联
│   ├── hmac_auth.py           # Webhook HMAC 认证
│   ├── image_policy.py        # 动态策略生成
│   └── k8s_client.py          # K8s API 客户端
├── sql/init.sql               # 数据库初始化(alerts/dread_scores/dynamic_policies)
├── tests/pochack             # POC 攻击模拟脚本
├── dataset/test              # 离线测试数据集
├── docs/项目计划书.md
├── main.py                    # Webhook 核心入口
├── Makefile                   # 一键离线部署脚本(核心)
├── Deployment                # venv 创建辅助脚本
├── requirements.txt
└── Warning.md                 # 安全警告
```

## 离线部署流程

### 步骤 1:在外网机生成离线资源(一次性)

```bash
# 在能联网的机器上执行,生成 charts/ 与 images/ 资源
bash scripts/download-offline-resources.sh
```

完成后将整个项目目录打包拷贝到内网部署机。

### 步骤 2:内网部署机一键部署

```bash
# 前置:Docker + Kind + kubectl + Helm 已安装(本身不联网)
cd security
make deploy          # 建集群 → 导镜像 → Gatekeeper → Falco → MySQL → 策略
make start-service    # 启动 Python 联动服务(前台)
# 另开终端:
make attack           # 执行多步攻击 POC 演示
```

### 步骤 3:已有集群时只补组件

```bash
make deploy-components   # 跳过建集群,只做镜像导入+组件安装
```

## Makefile 目标一览

| 目标 | 说明 |
|------|------|
| `make help` | 显示所有可用目标 |
| `make load-host-images` | 载入宿主机 Docker 镜像(kindest/node + mysql) |
| `make cluster` | 创建 Kind 多节点集群 |
| `make load-images` | **离线导入镜像到全部节点**(docker cp + ctr import,不使用 kind load) |
| `make install-gatekeeper` | 本地 Chart 安装 Gatekeeper |
| `make install-falco` | 本地 Chart 安装 Falco + Falcosidekick(module 驱动) |
| `make install-db` | 启动 MySQL 容器并加载表结构 |
| `make load-policies` | 加载 OPA ConstraintTemplate/Constraint |
| `make start-service` | 启动 Python 联动服务 |
| `make attack` | 执行攻击 POC 演示 |
| `make deploy` | **一键完整部署** |
| `make deploy-components` | 已有集群时只装组件 |
| `make clean` | 清理集群与 MySQL 容器 |

## 关键设计:为何不用 `kind load`

`kind load docker-image` 在多架构镜像经镜像代理中转后,镜像摘要与官方不一致,必然报 `content digest not found` 校验失败。本仓库改用底层路径:

```
docker save 镜像 → tar
   ↓ docker cp 传入每个 Kind 节点容器(节点名 = Docker 容器名)
   ↓ docker exec 节点内 `ctr -n k8s.io images import` 导入
```

且 Kind 节点是独立 containerd,Pod 随机调度,只要任一节点缺镜像就 ErrImagePull。故 `make load-images` 通过 `kubectl get nodes` 遍历全部 control-plane + worker 节点批量导入。

部署顺序严格为:集群 → **导入镜像** → 安装组件。先铺镜像再装组件,避免 Gatekeeper CRD Hook 启动 Pod 时无镜像导致 `helm install --wait` 超时失败。

## 部署验证

```bash
# 1) 集群节点
kubectl get nodes                                    # 全部 Ready

# 2) Gatekeeper
kubectl get pods -n gatekeeper-system                # 全部 Running

# 3) Falco
kubectl get ds -n falco-system                       # DESIRED = 节点数
kubectl get pods -n falco-system -o wide

# 4) 节点镜像已就位(无 ImagePull)
docker exec falco-opa-demo-control-plane ctr -n k8s.io images ls | grep -E 'gatekeeper|falco'
docker exec falco-opa-demo-worker ctr -n k8s.io images ls | grep -E 'gatekeeper|falco'

# 5) MySQL
docker exec -it falco-db mysql -u root -p0 -e 'USE falco_alerts; SHOW TABLES;'
# 期望:alerts / dread_scores / dynamic_policies 三张表

# 6) OPA 策略生效
kubectl get constrainttemplates
kubectl get k8simagepolicy
# 测试拦截(应被拒绝):
kubectl run test-priv --image=alpine:latest --overrides='{"spec":{"containers":[{"name":"test","image":"alpine:latest","securityContext":{"privileged":true}}]}}'
```

## 环境变量

联动服务 `main.py` 支持以下环境变量(默认值见 [src/db.py](src/db.py) 与 [src/hmac_auth.py](src/hmac_auth.py)):

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DB_HOST` | 127.0.0.1 | MySQL 主机 |
| `DB_PORT` | 3306 | MySQL 端口 |
| `DB_USER` | root | MySQL 用户 |
| `DB_PASS` | 0 | MySQL 密码(与 `make install-db` 一致) |
| `DB_NAME` | falco_alerts | 数据库名 |
| `WEBHOOK_SECRET` | falco-opa-shared-secret-key | Falcosidekick HMAC 共享密钥 |
| `KUBECONFIG` | ~/.kube/config | K8s 配置 |

## 业务流程

1. Falco 捕获容器系统调用(shell 创建、敏感文件读取、提权、hostPath 等)
2. Falcosidekick 加 HMAC 签名转发到 `http://webhook-service.default.svc:8080/webhook`
3. `main.py` 校验 HMAC → 解析告警 → 时间窗口聚合 → DREAD 评分 → 入库
4. 攻击链完成(≥3 阶段)或风险等级 HIGH/CRITICAL 时,生成动态 OPA Constraint
5. Gatekeeper 准入引擎拦截后续恶意 Pod(镜像黑名单 / 特权容器 / hostPath)

## ⚠️ 安全警告

见 [Warning.md](Warning.md)。本项目含攻击模拟代码(`tests/pochack`),仅用于安全研究和教学演示:
- **禁止**在生产环境运行 POC
- **禁止**用于任何非法目的
- 演示必须在隔离的测试环境进行
- 测试完成后执行 `make clean` 清理环境

Falco module 驱动需要内核版本 ≥ 4.14,Rocky Linux 9 默认内核(5.14)完全支持。
