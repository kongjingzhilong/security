#!/bin/bash
# ============================================================================
#  离线资源下载脚本 —— 在「具备外网」的机器上执行
#  产物:charts/*.tgz  images/*.tar  wheels/*.whl
#  执行后,把整个 security/ 目录拷到内网部署机即可 make deploy 全程不联网
#  注意:版本号必须与 Makefile 顶部 CONFIG 区块保持一致,如源不可用请同步修改
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."   # 切到项目根目录 security/

mkdir -p charts images wheels

echo "========== 1. 拉取 Helm Chart(本地 tgz) =========="
# 仅本脚本(外网机)允许 helm repo add;部署机 Makefile 绝不联网
helm repo add gatekeeper   https://open-policy-agent.github.io/gatekeeper/charts
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update

helm pull gatekeeper/gatekeeper     --version 3.23.1  -d charts
helm pull falcosecurity/falco        --version 4.10.0  -d charts
helm pull falcosecurity/falcosidekick --version 0.7.16 -d charts

echo "========== 2. 拉取并导出容器镜像(tar) =========="
# --- 宿主机 Docker 镜像 ---
docker pull kindest/node:v1.31.2
docker pull mysql:8.0
docker save kindest/node:v1.31.2 -o images/kindest-node.tar
docker save mysql:8.0            -o images/mysql.tar

# --- 集群节点镜像(Gatekeeper) ---
docker pull openpolicyagent/gatekeeper:v3.23.1
docker save openpolicyagent/gatekeeper:v3.23.1 -o images/gatekeeper.tar

# --- 集群节点镜像(Falco 组件, 同组件多镜像合并打包) ---
docker pull falcosecurity/falco:0.40.0
docker pull falcosecurity/falcosidekick:2.27.0
docker save falcosecurity/falco:0.40.0 falcosecurity/falcosidekick:2.27.0 -o images/falco.tar

echo "========== 3. 下载 Python 依赖(离线 wheel, 可选) =========="
# ⚠️ 注意:requirements.txt 列了 psycopg2-binary(PostgreSQL 驱动),但本项目用 MySQL,
#          业务代码 src/db.py 实际依赖 pymysql。下面同时下载两者以保运行:
pip download -r requirements.txt -d wheels
pip download pymysql -d wheels

echo "========== 完成 =========="
echo "charts/ : $(ls charts | wc -l) 个 Chart"
echo "images/ : $(ls images | wc -l) 个镜像包"
echo "wheels/ : $(ls wheels | wc -l) 个 wheel"
echo "请将整个项目目录拷贝到内网部署机,执行: make deploy"
