# 🛡️ 基于 Falco 与 OPA 的云原生容器多步攻击检测与动态准入控制系统
## 架构

## 快速部署

```bash
# 1. 环境准备（Rocky Linux 9）
# Docker + Kind + kubectl + Helm 安装

# 2. 创建集群
kind create cluster --config deploy/kind/1 --name falco-opa-demo

# 3. 安装 OPA Gatekeeper
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm install gatekeeper gatekeeper/gatekeeper --namespace gatekeeper-system --create-namespace --wait

# 4. 安装 Falco + Falcosidekick
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco --namespace falco-system --create-namespace --set falco.engine.kind=ebpf --wait
helm install falcosidekick falcosecurity/falcosidekick --namespace falco-system \
  --set config.webhook.address=http://webhook-service.default.svc:8080/webhook --wait

# 5. 启动数据库
docker run -d --name falco-db -e MYSQL_ROOT_PASSWORD=root123 \
  -e MYSQL_DATABASE=falco_alerts -p 3306:3306 mysql:8.0
sleep 15
mysql -h 127.0.0.1 -u root -proot123 falco_alerts < sql/init.sql

# 6. 加载 OPA 策略
kubectl apply -f deploy/helm/1

# 7. 启动联动服务
source venv/bin/activate
export KUBECONFIG=~/.kube/config
python3 main.py &

# 8. 运行 POC 攻击演示
bash tests/poc/0
├── main.py                 # Webhook 核心入口
├── requirements.txt        # Python 依赖
├── deploy/
│   ├── kind/1             # Kind 集群配置
│   └── helm/1             # OPA ConstraintTemplate + Constraint
├── src/
│   ├── db.py              # MySQL 数据库操作
│   ├── dread.py           # DREAD 风险评估
│   ├── parser.py          # Falco 告警解析
│   ├── time_window.py     # 时间窗口攻击链关联
│   ├── hmac_auth.py       # Webhook HMAC 认证
│   ├── image_policy.py    # 动态策略生成
│   └── k8s_client.py      # K8s API 客户端
├── sql/init.sql           # 数据库初始化
├── tests/poc/0            # POC 攻击模拟脚本
└── dataset/0              # 离线测试数据集

---

#### 📄 `Warning.md`（项目根目录）

```markdown
# ⚠️ 安全警告

本项目包含攻击模拟代码（`tests/poc/`），仅用于安全研究和教学演示。

## 使用限制

- **禁止**在生产环境中运行 POC 攻击脚本
- **禁止**将本系统用于任何非法目的
- 所有演示必须在隔离的测试环境中进行

## 注意事项

- 本项目会动态修改集群的准入策略，可能影响正常 Pod 调度
- 测试完成后请执行 `kind delete cluster --name falco-opa-demo` 清理环境
- Falco eBPF 模式需要内核版本 ≥ 4.14，Rocky Linux 9 默认内核 (5.14) 完全支持

