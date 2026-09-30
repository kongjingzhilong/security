#!/bin/bash
# ============================================================
#  离线资源下载脚本 —— 在「具备外网」的机器上执行
#  产物: charts/*.tgz  images/*.tar  wheels/*.whl
#  注意: 版本号必须与 Makefile 顶部 CONFIG 区块保持一致
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

# 统一下载参数：超时 + 重试 + 断点续传
CURL_OPTS="--connect-timeout 15 --max-time 600 --retry 3 --retry-delay 5 -C - -L"
HELM_OPTS="--timeout 10m --insecure-skip-tls-verify"   # 后者按需保留

# 镜像前缀：默认官方 Docker Hub。国内直连 Docker Hub 不稳时可指向镜像代理/内网 registry，
# 例如: IMAGE_PREFIX=0wqcfr78pnd1zo9kvk.xuanyuan.run ./scripts/download-offline-resources.sh
IMAGE_PREFIX="${IMAGE_PREFIX:-}"

mkdir -p charts images wheels

echo "========== 1. 拉取 Helm Chart(本地 tgz) ==========="
# ------------------------------------------------------------
# 「预置即离线」：charts/ 下若已存在同名 tgz(如手工预置的 falco-9.2.0.tgz)，
# 则跳过 helm repo add/update 与 helm pull，完全不触网。
# 判定方式:
#   1) 存在 charts/<name>-*.tgz → 该 chart 已就绪
#   2) charts/falco-9.2.0.tgz 为官方自包含包(内嵌 falcosidekick 0.14.* /
#      k8s-metacollector 0.3.* / falco-talon 0.4.*，helm dependency list 显示 unpacked)
#      → 连 falcosidekick 也不必单独下载
# ------------------------------------------------------------
have_chart() { compgen -G "charts/$1-*.tgz" >/dev/null 2>&1; }

NEED_GK=1;       if have_chart gatekeeper;       then NEED_GK=0;       fi
NEED_FALCO=1;    if have_chart falco;            then NEED_FALCO=0;    fi
# falco 自包含包在手时，内嵌的 falcosidekick / k8s-metacollector / falco-talon 均已就绪
NEED_SIDEKICK=1; if have_chart falcosidekick || have_chart falco; then NEED_SIDEKICK=0; fi
NEED_META=1;     if have_chart k8s-metacollector || have_chart falco; then NEED_META=0; fi
NEED_TALON=1;    if have_chart falco-talon || have_chart falco; then NEED_TALON=0; fi

if [ "$NEED_GK" = 1 ] || [ "$NEED_FALCO" = 1 ] || [ "$NEED_SIDEKICK" = 1 ] \
   || [ "$NEED_META" = 1 ] || [ "$NEED_TALON" = 1 ]; then
  echo "--> 存在缺失 chart，添加/更新 helm 仓库(同时修正原 falosecurity 拼写为 falcosecurity)"
  helm repo add gatekeeper    https://open-policy-agent.github.io/gatekeeper/charts --force-update
  helm repo add falcosecurity https://falcosecurity.github.io/charts             --force-update
  helm repo update --timeout 10m
else
  echo "--> 本地 charts/ 已包含全部所需 chart，跳过 helm repo add/update 与 pull(零外网)"
fi

# 版本取自 charts/falco-9.2.0.tgz 内 Chart.lock 的精确锁定值
if [ "$NEED_GK" = 1 ];       then helm pull gatekeeper/gatekeeper           --version 3.23.1 -d charts ${HELM_OPTS}; fi
if [ "$NEED_FALCO" = 1 ];    then helm pull falcosecurity/falco             --version 9.2.0  -d charts ${HELM_OPTS}; fi
if [ "$NEED_SIDEKICK" = 1 ]; then helm pull falcosecurity/falcosidekick     --version 0.14.0 -d charts ${HELM_OPTS}; fi
if [ "$NEED_META" = 1 ];     then helm pull falcosecurity/k8s-metacollector --version 0.3.2  -d charts ${HELM_OPTS}; fi
if [ "$NEED_TALON" = 1 ];    then helm pull falcosecurity/falco-talon       --version 0.4.2  -d charts ${HELM_OPTS}; fi
ls -la charts/

echo "========== 2. 拉取并导出容器镜像(tar) ==========="
# --- 宿主机 Docker 镜像 ---
# 节点镜像版本必须与 Makefile 的 KIND_NODE_IMAGE 一致(当前 kindest/node:v1.37.0)
docker pull kindest/node:v1.37.0
docker pull mysql:8.0
docker save kindest/node:v1.37.0 -o images/kindest-node.tar
docker save mysql:8.0            -o images/mysql.tar

# --- 集群节点镜像(Gatekeeper) ---
if [ -n "$IMAGE_PREFIX" ]; then
  docker pull ${IMAGE_PREFIX}/openpolicyagent/gatekeeper:v3.23.1
  docker tag  ${IMAGE_PREFIX}/openpolicyagent/gatekeeper:v3.23.1 openpolicyagent/gatekeeper:v3.23.1
else
  docker pull openpolicyagent/gatekeeper:v3.23.1
fi
# 关键: 必须导出「规范名」，因为 Makefile 的 image.repository 只认这个镜像名
docker save openpolicyagent/gatekeeper:v3.23.1 -o images/gatekeeper.tar

# --- 集群节点镜像(Falco 组件，同组多镜像合并打包) ---
# 镜像清单由 `helm template charts/falco-9.2.0.tgz` 实测得出(勿凭记忆增删):
#   falco:0.45.0              主容器 (chart appVersion)
#   falcoctl:0.14.2           initContainer + 常驻 sidecar (chart values 固定 tag)
#   falco-driver-loader:0.45.0 initContainer，driver.kind=module 时必需
#   falcosidekick:2.32.0      内嵌子 chart 默认镜像(install-falco 默认关闭，一并打包备用)
# 注: collectors.kubernetes.enabled 默认 false → k8s-metacollector 镜像本次不需要
FALCO_IMAGES=(
  "falcosecurity/falco:0.45.0"
  "falcosecurity/falcoctl:0.14.2"
  "falcosecurity/falco-driver-loader:0.45.0"
  "falcosecurity/falcosidekick:2.32.0"
)
for img in "${FALCO_IMAGES[@]}"; do
  if [ -n "$IMAGE_PREFIX" ]; then
    docker pull ${IMAGE_PREFIX}/${img}
    docker tag  ${IMAGE_PREFIX}/${img} "${img}"   # retag 回规范名，保证节点上名字与 Helm values 一致
  else
    docker pull "${img}"
  fi
done
# 一次 save 出单个 tar，与 Makefile 的 load-images 期望的 images/falco.tar 对齐
docker save "${FALCO_IMAGES[@]}" -o images/falco.tar

echo "========== 3. 下载 Python 依赖(离线 wheel，可选) ==========="
# 注意: requirements.txt 列了 psycopg2-binary(PostgreSQL 驱动)，但本项目用 MySQL，
#       业务代码 src/db.py 实际依赖 pymysql。下面同时下载两者以保运行:
pip download -r requirements.txt -d wheels --retries 3 --timeout 60
pip download pymysql -d wheels --retries 3 --timeout 60

echo "========== 完成 ==========="
echo "charts/  : $(ls charts  2>/dev/null | wc -l) 个 Chart"
echo "images/  : $(ls images  2>/dev/null | wc -l) 个镜像包"
echo "wheels/  : $(ls wheels  2>/dev/null | wc -l) 个 wheel"
echo "请将整个项目目录拷贝到内网部署机，执行: make deploy"
