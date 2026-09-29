# ============================================================================
#  Falco-OPA 多步攻击检测与动态准入系统 · 全离线一键部署 Makefile
#  ----------------------------------------------------------------------------
#  设计原则：
#    1. 全程不联网：Helm 使用本地 tgz，镜像读取本地 tar，无 helm repo add/update
#    2. 规避 kind digest bug：镜像经 docker save 出 tar → docker cp 进节点 →
#       节点内 `ctr -n k8s.io images import` 导入，绝不使用 `kind load`
#    3. 全节点覆盖：遍历 kubectl get nodes 得到全部节点(control-plane+worker)
#       批量导入，杜绝单节点缺镜像导致 ErrImagePull
#    4. 镜像先于组件：CRD Hook 启动 Pod 前已把镜像铺到所有节点，避免安装超时
# ============================================================================
SHELL := /bin/bash

# ---------- 可调配置区(版本需与 charts/ 与 images/ 内文件名一致) ----------
CLUSTER_NAME        := falco-opa-demo
KIND_NODE_IMAGE     := kindest/node:v1.31.2

# Helm Chart 本地包(相对路径,与 helm pull 默认输出名一致)
GATEKEEPER_CHART    := charts/gatekeeper-3.23.1.tgz
FALCO_CHART         := charts/falco-4.10.0.tgz
FALCOSIDEKICK_CHART := charts/falcosidekick-0.7.16.tgz

# 镜像仓库与标签(必须与 images/*.tar 内导出的镜像一致)
GATEKEEPER_REPO     := openpolicyagent/gatekeeper
GATEKEEPER_TAG      := v3.23.1
FALCO_REPO          := falcosecurity/falco
FALCO_TAG           := 0.40.0
FALCOSIDEKICK_REPO  := falcosecurity/falcosidekick
FALCOSIDEKICK_TAG   := 2.27.0
MYSQL_IMAGE         := mysql:8.0
# MySQL root 口令:与 src/db.py 默认值 '0' 保持一致
MYSQL_ROOT_PASSWORD := 0
MYSQL_DATABASE      := falco_alerts

# Falcosidekick 回调地址(沿用原项目设计)
WEBHOOK_ADDRESS     := http://webhook-service.default.svc:8080/webhook

# 部署超时
HELM_TIMEOUT        := 5m

.PHONY: help load-host-images cluster load-images \
        install-gatekeeper install-falco install-db load-policies \
        start-service attack deploy deploy-components clean

help:
	@echo "============ Falco-OPA 离线部署 · 可用目标 ============"
	@echo "  make help                显示本帮助"
	@echo "  make load-host-images    载入宿主机 Docker 镜像(kindest/node + mysql)"
	@echo "  make cluster             创建 Kind 多节点集群(节点镜像已离线就绪)"
	@echo "  make load-images         离线导入 gatekeeper/falco 镜像到所有节点"
	@echo "  make install-gatekeeper  本地 Chart 安装 Gatekeeper(OPA 准入)"
	@echo "  make install-falco       本地 Chart 安装 Falco + Falcosidekick(module 驱动)"
	@echo "  make install-db          启动本地 MySQL 容器并加载表结构"
	@echo "  make load-policies       加载 OPA ConstraintTemplate/Constraint"
	@echo "  make start-service       启动 Python 联动服务"
	@echo "  make attack              执行攻击 POC 演示"
	@echo "  make deploy              一键完整部署(建集群→导镜像→装组件→加载策略)"
	@echo "  make deploy-components   已有集群时跳过建集群,只做镜像导入+组件安装"
	@echo "  make clean               清理集群与数据库容器"

# ============================================================================
# 1) 宿主机镜像载入
#    kind 节点容器由宿主机 Docker 用 kindest/node 创建;MySQL 作为宿主机容器运行
#    这两个镜像必须存在于宿主机 Docker,故用 docker load(不进 kind 节点)
# ============================================================================
load-host-images:
	@set -e; \
	for tar in images/kindest-node.tar images/mysql.tar; do \
	  if [ -f "$$tar" ]; then \
	    echo "==> 载入宿主机 Docker: $$tar"; \
	    docker load -i "$$tar"; \
	  else \
	    echo "⚠️  跳过(未找到): $$tar —— 将依赖宿主机已有镜像或联网拉取"; \
	  fi; \
	done

# ============================================================================
# 2) 创建 Kind 多节点集群
#    --image 显式指定节点镜像,kind.yaml 未声明 image,故以命令行为准
# ============================================================================
cluster: load-host-images
	kind create cluster --config deploy/kind/kind.yaml --name $(CLUSTER_NAME) --image $(KIND_NODE_IMAGE)
	@echo "✅ Kind 集群创建完成: $(CLUSTER_NAME)"

# ============================================================================
# 3) 离线镜像导入到全部节点(核心:规避 kind load digest 校验 bug)
#    方案:docker cp 镜像 tar 进每个节点容器 → 节点内 ctr import
#    节点名取自 kubectl get nodes(Kind 节点名即 Docker 容器名)
#    全节点遍历:control-plane + 所有 worker,任一缺镜像都会导致 ErrImagePull
# ============================================================================
load-images:
	@set -e; \
	echo "==> 离线导入集群镜像到所有 Kind 节点 (docker cp + ctr import, 不使用 kind load)"; \
	if ! ls images/gatekeeper.tar images/falco.tar >/dev/null 2>&1; then \
	  echo "❌ images/ 下未发现 gatekeeper.tar / falco.tar,请先在外网机器执行下载脚本"; \
	  exit 1; \
	fi; \
	nodes=$$(kubectl get nodes -o name | sed 's|node/||'); \
	if [ -z "$$nodes" ]; then \
	  echo "❌ 未获取到节点,请确认集群已创建: make cluster"; exit 1; \
	fi; \
	for tar in images/gatekeeper.tar images/falco.tar; do \
	  bname=$$(basename "$$tar"); \
	  for node in $$nodes; do \
	    echo ">>  [$$node] 导入 $$bname"; \
	    docker cp "$$tar" "$$node:/tmp/$$bname"; \
	    docker exec "$$node" ctr -n k8s.io images import "/tmp/$$bname"; \
	    docker exec "$$node" rm -f "/tmp/$$bname"; \
	  done; \
	done; \
	echo "✅ 所有节点镜像导入完成"

# ============================================================================
# 4) 安装 Gatekeeper(本地 Chart,无 helm repo add)
#    Gatekeeper CRD 由 Chart 模板直接安装,无需单独的 gatekeeper-crds 镜像
# ============================================================================
install-gatekeeper:
	helm install gatekeeper $(GATEKEEPER_CHART) \
	  --namespace gatekeeper-system --create-namespace \
	  --set image.repository=$(GATEKEEPER_REPO) \
	  --set image.tag=$(GATEKEEPER_TAG) \
	  --wait --timeout $(HELM_TIMEOUT)
	@echo "✅ Gatekeeper 安装完成"

# ============================================================================
# 5) 安装 Falco + Falcosidekick(本地 Chart,module 驱动适配 Kind)
#    关键:关闭 falcoctl 的 install/follow,禁止运行期从外网拉取规则/插件
# ============================================================================
install-falco:
	helm install falco $(FALCO_CHART) \
	  --namespace falco-system --create-namespace \
	  --set image.repository=$(FALCO_REPO) \
	  --set image.tag=$(FALCO_TAG) \
	  --set driver.kind=module \
	  --set falcoctl.config.artifact.install.enabled=false \
	  --set falcoctl.config.artifact.follow.enabled=false \
	  --wait --timeout $(HELM_TIMEOUT)
	helm install falcosidekick $(FALCOSIDEKICK_CHART) \
	  --namespace falco-system \
	  --set image.repository=$(FALCOSIDEKICK_REPO) \
	  --set image.tag=$(FALCOSIDEKICK_TAG) \
	  --set config.webhook.address=$(WEBHOOK_ADDRESS) \
	  --wait --timeout $(HELM_TIMEOUT)
	@echo "✅ Falco + Falcosidekick 安装完成"

# ============================================================================
# 6) 本地 MySQL(告警与攻击链存储)
#    用 docker exec -i 把 SQL 灌入容器,免装宿主机 mysql 客户端
# ============================================================================
install-db:
	@set -e; \
	echo "==> 启动本地 MySQL 容器 ($(MYSQL_IMAGE))"; \
	docker rm -f falco-db >/dev/null 2>&1 || true; \
	docker run -d --name falco-db --restart unless-stopped \
	  -e MYSQL_ROOT_PASSWORD=$(MYSQL_ROOT_PASSWORD) \
	  -e MYSQL_DATABASE=$(MYSQL_DATABASE) \
	  -p 3306:3306 $(MYSQL_IMAGE); \
	echo "==> 等待 MySQL 就绪..."; \
	for i in $$(seq 1 60); do \
	  docker exec falco-db mysqladmin ping -h 127.0.0.1 -u root -p$(MYSQL_ROOT_PASSWORD) --silent 2>/dev/null && break; \
	  sleep 2; \
	done; \
	docker exec falco-db mysqladmin ping -h 127.0.0.1 -u root -p$(MYSQL_ROOT_PASSWORD) --silent || { echo "❌ MySQL 启动失败"; exit 1; }; \
	echo "==> 初始化数据库表结构"; \
	docker exec -i falco-db mysql -u root -p$(MYSQL_ROOT_PASSWORD) $(MYSQL_DATABASE) < sql/init.sql; \
	echo "✅ MySQL 就绪并已加载表结构"

# ============================================================================
# 7) 加载 OPA 约束策略(ConstraintTemplate + Constraint)
# ============================================================================
load-policies:
	kubectl apply -f deploy/helm/helm.yaml
	@echo "✅ OPA 策略已加载"

# ============================================================================
# 8) 启动 Python 联动服务(需先 source venv)
# ============================================================================
start-service:
	export KUBECONFIG=$$HOME/.kube/config && \
	python3 main.py

# ============================================================================
# 9) 攻击 POC 演示
# ============================================================================
attack:
	bash tests/pochack

# ============================================================================
# 10) 一键完整部署(严格顺序:集群→镜像→Gatekeeper→Falco→MySQL→策略)
# ============================================================================
deploy: load-host-images cluster load-images install-gatekeeper install-falco install-db load-policies
	@echo ""
	@echo "✅✅✅ 完整部署完成 ✅✅✅"
	@echo "下一步: make start-service 启动联动服务; make attack 执行攻击演示"

# ============================================================================
# 11) 已有集群时只做镜像导入 + 组件安装(跳过建集群)
# ============================================================================
deploy-components: load-host-images load-images install-gatekeeper install-falco install-db load-policies
	@echo ""
	@echo "✅✅✅ 组件部署完成 ✅✅✅"
	@echo "下一步: make start-service 启动联动服务"

# ============================================================================
# 12) 清理
# ============================================================================
clean:
	-kind delete cluster --name $(CLUSTER_NAME)
	-docker rm -f falco-db
	@echo "✅ 已清理集群与 MySQL 容器"
