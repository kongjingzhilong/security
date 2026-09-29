# ============ Falco-OPA 多步攻击检测与动态准入系统 · 部署脚本 ============
# 适配离线/内网环境：kind 多节点集群 + 镜像离线导入 + 动态准入联动
SHELL := /bin/bash
CLUSTER_NAME := falco-opa-demo
.PHONY: help cluster install-gatekeeper install-falco install-db \
        load-policies start-service attack deploy deploy-components clean load-images
help:
	@echo "可执行目标："
	@echo "  make cluster            创建 kind 集群"
	@echo "  make load-images        离线导入 gatekeeper/falco 镜像到所有节点"
	@echo "  make install-gatekeeper 安装 Gatekeeper(OPA准入)"
	@echo "  make install-falco      安装 Falco + FalcoSidekick(运行时检测)"
	@echo "  make install-db         启动本地 MySQL(告警存储)"
	@echo "  make load-policies      加载 OPA 约束策略"
	@echo "  make start-service      启动 Python 联动服务"
	@echo "  make attack             执行攻击 POC 测试"
	@echo "  make deploy             一键完整部署(建集群+全部组件)"
	@echo "  make deploy-components   在已有集群上只装组件(跳过建集群)"
	@echo "  make clean              清理集群和数据库容器"
# ---------- 1. 创建 kind 集群 ----------
cluster:
	kind create cluster --config deploy/kind/kind.yaml --name $(CLUSTER_NAME)
# ---------- 2. 离线导入镜像到集群全部节点 ----------
# 说明：kind load 对经代理中转的镜像会报 digest 校验失败，
#       改为 docker save + ctr import 底层导入，绕开校验。
#       多节点集群必须每个节点都导入，否则 Pod 调度过去会 ErrImagePull。
load-images: load-gatekeeper-images load-falco-images
load-gatekeeper-images:
	docker save openpolicyagent/gatekeeper:v3.23.1 -o /tmp/gatekeeper.tar
	docker save openpolicyagent/gatekeeper-crds:v3.23.1 -o /tmp/gatekeeper-crds.tar
	@for node in $(shell kubectl get nodes -o name | sed 's|node/||'); do \
		echo ">> 导入镜像到节点: $$node"; \
		docker cp /tmp/gatekeeper.tar $$node:/gatekeeper.tar; \
		docker cp /tmp/gatekeeper-crds.tar $$node:/gatekeeper-crds.tar; \
		docker exec $$node ctr -n k8s.io images import /gatekeeper.tar; \
		docker exec $$node ctr -n k8s.io images import /gatekeeper-crds.tar; \
		docker exec $$node ctr -n k8s.io images tag docker.io/openpolicyagent/gatekeeper:v3 \
			docker.io/openpolicyagent/gatekeeper:v3.23.1; \
	done
	rm -f /tmp/gatekeeper.tar /tmp/gatekeeper-crds.tar
load-falco-images:
	docker save falcosecurity/falco -o /tmp/falco.tar
	docker save falcosecurity/falcosidekick -o /tmp/falcosidekick.tar
	@for node in $(shell kubectl get nodes -o name | sed 's|node/||'); do \
		echo ">> 导入镜像到节点: $$node"; \
		docker cp /tmp/falco.tar $$node:/falco.tar; \
		docker cp /tmp/falcosidekick.tar $$node:/falcosidekick.tar; \
		docker exec $$node ctr -n k8s.io images import /falco.tar; \
		docker exec $$node ctr -n k8s.io images import /falcosidekick.tar; \
	done
	rm -f /tmp/falco.tar /tmp/falcosidekick.tar
# ---------- 3. 安装 Gatekeeper(静态准入) ----------
install-gatekeeper:
	helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
	helm repo update
	helm install gatekeeper gatekeeper/gatekeeper \
		--namespace gatekeeper-system --create-namespace \
		--set image.repository=openpolicyagent/gatekeeper \
		--set image.tag=v3.23.1 \
		--set crd.image.repository=openpolicyagent/gatekeeper-crds \
		--set crd.image.tag=v3.23.1 \
		--wait
# ---------- 4. 安装 Falco + FalcoSidekick(运行时检测) ----------
install-falco:
	@echo "=== 离线安装 Falco（本地chart包 /tmp/falco-9.2.0.tgz）==="
	helm install falco /tmp/falco-9.2.0.tgz \
	--namespace falco-system --create-namespace \
	--set falco.engine.kind=ebpf --wait
	@echo "Falco安装完成，falcosidekick待本地tgz包准备好再安装"

# ---------- 5. 本地 MySQL(告警与攻击链存储) ----------
install-db:
	docker run -d --name falco-db \
		-e MYSQL_ROOT_PASSWORD=0 \
		-e MYSQL_DATABASE=falco_alerts \
		-p 3306:3306 mysql:8.0
	sleep 15
	mysql -h 127.0.0.1 -u root -p0 falco_alerts < sql/init.sql
# ---------- 6. 加载 OPA 约束策略 ----------
load-policies:
	kubectl apply -f deploy/helm/helm.yaml
# ---------- 7. 启动 Python 联动服务 ----------
start-service:
	export KUBECONFIG=$$HOME/.kube/config && \
	python3 main.py
# ---------- 8. 攻击 POC 测试 ----------
attack:
	bash tests/pochack
# ---------- 9. 一键部署 ----------
deploy: cluster load-images install-gatekeeper install-falco install-db load-policies
	@echo "✅ 完整部署完成！执行 make start-service 启动联动服务"
# 已有集群时只装组件(跳过建集群和Gatekeeper)
deploy-components: load-falco-images install-falco install-db load-policies
	@echo "✅ 组件部署完成！执行 make start-service 启动联动服务"
# ---------- 10. 清理 ----------
clean:
	kind delete cluster --name $(CLUSTER_NAME)
	docker rm -f falco-db
