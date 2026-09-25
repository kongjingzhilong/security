.PHONY: cluster install-db install-gatekeeper install-falco start-service attack clean
cluster:
	kind create cluster --config deploy/kind/kind.yaml --name falco-opa-demo
install-gatekeeper:
	helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
	helm install gatekeeper gatekeeper/gatekeeper \
		--namespace gatekeeper-system --create-namespace --wait
install-falco:
	helm repo add falcosecurity https://falcosecurity.github.io/charts
	helm install falco falcosecurity/falco \
		--namespace falco-system --create-namespace \
		--set falco.engine.kind=ebpf --wait
	helm install falcosidekick falcosecurity/falcosidekick \
		--namespace falco-system \
		--set config.webhook.address=http://webhook-service.default.svc:8080/webhook --wait
install-db:
	docker run -d --name falco-db \
		-e MYSQL_ROOT_PASSWORD=0 \
		-e MYSQL_DATABASE=falco_alerts \
		-p 3306:3306 mysql:8.0
	sleep 15
	mysql -h 127.0.0.1 -u root -p0 falco_alerts < sql/init.sql
load-policies:
	kubectl apply -f deploy/helm/helm.yaml
start-service:
	source venv/bin/activate && \
	export KUBECONFIG=~/.kube/config && \
	python3 main.py
attack:
	bash tests/pochack
deploy: cluster install-gatekeeper install-falco install-db load-policies
	@echo "✅ 部署完成！执行 make start-service 启动联动服务"

clean:
	kind delete cluster --name falco-opa-demo
	docker rm -f falco-db

