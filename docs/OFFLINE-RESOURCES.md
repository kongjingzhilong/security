# 离线资源获取指南（OFFLINE-RESOURCES）

> 目标：在一台**能上网**的机器上，一次性产出本项目部署所需的全部资源
> （Helm Chart / 容器镜像 / Python 依赖 wheel），拷贝到内网后**全程不联网**完成部署。
>
> 本文所有版本号与体积均为 2026-09-30 实测值，请与 `Makefile` 顶部 CONFIG 区块保持一致。

---

## 一、需要哪些资源（清单）

| 类别 | 产物 | 用途 | 实测体积 |
|---|---|---|---|
| Chart | `charts/falco-9.2.0.tgz` | Falco 运行时安全 | 182K |
| Chart | `charts/gatekeeper-3.23.1.tgz` | OPA 准入控制 | 35K |
| 镜像 | `images/falco.tar` | Falco 全部组件 | 460M |
| 镜像 | `images/gatekeeper.tar` | Gatekeeper 控制器 | 55M |
| 镜像 | `images/mysql.tar` | 告警数据库 | 238M |
| 镜像 | `images/kindest-node.tar` | Kind 集群节点 | 371M |
| Python | `wheels/*.whl` | 联动服务依赖（32 个） | 12M |

### 1.1 falco.tar 里必须包含的 4 个镜像

**这份清单由 `helm template` 实测得出，请勿凭记忆增删**：

| 镜像 | 大小 | 作用 |
|---|---|---|
| `falcosecurity/falco:0.45.0` | 164MB | 主容器（= chart appVersion） |
| `falcosecurity/falcoctl:0.14.2` | 151MB | initContainer + sidecar（chart 固定 tag） |
| `falcosecurity/falco-driver-loader:0.45.0` | 1.36GB | initContainer，**仅 kmod 驱动需要** |
| `falcosecurity/falcosidekick:2.32.0` | 199MB | 内嵌子 chart 默认镜像 |

> **重要**：如果按本项目默认使用 `driver.kind=modern_ebpf`（见第四节），
> `falco-driver-loader` **不会被使用**。它体积最大（1.36GB），
> 若确定不用 kmod 驱动，可以从打包清单中剔除，`falco.tar` 会从 460M 降到约 300M。

### 1.2 不需要的资源

以下镜像**不需要**下载，避免浪费空间：

- `k8s-metacollector`：`collectors.kubernetes.enabled` 默认 `false`
- `falco-talon`：`responseActions.enabled` 默认 `false`
- `openpolicyagent/gatekeeper-crds`：Gatekeeper CRD 由 Chart 模板直接安装

---

## 二、获取方式

### 方式 A：自动脚本（推荐）

在**能上网**的机器上执行：

```bash
cd security
bash scripts/download-offline-resources.sh
```

脚本行为：

1. **Chart 部分按「预置即离线」判定** —— `charts/` 下若已存在同名 `*.tgz`
   （例如手工预置的 `falco-9.2.0.tgz`），则**完全跳过** `helm repo add/update` 与
   `helm pull`，不触网。只有确有缺失时才联网。
2. 拉取镜像并 `docker save` 成 tar。
3. 用清华 PyPI 镜像下载 wheel。

### 方式 B：手动分步（网络不稳时更可控）

#### B1. 获取 Chart

```bash
# falco 9.2.0 是官方「自包含」包：falcosidekick / k8s-metacollector /
# falco-talon 已内嵌（helm dependency list 显示 unpacked），安装时无需再联网
helm pull falcosecurity/falco       --version 9.2.0  -d charts
helm pull gatekeeper/gatekeeper     --version 3.23.1 -d charts
```

若目标版本已存在本地副本（如项目里的 `falco-9.2.0.tgz`），直接放入即可：

```bash
cp -n falco-9.2.0.tgz charts/
sha256sum charts/falco-9.2.0.tgz
# 期望: 5e0699e68e5e4abd5eab1d501b3e0300a15888f3a5c2b0977bf3ca3229a8d04a
```

#### B2. 获取镜像并导出

```bash
for img in falcosecurity/falco:0.45.0 \
           falcosecurity/falcoctl:0.14.2 \
           falcosecurity/falco-driver-loader:0.45.0 \
           falcosecurity/falcosidekick:2.32.0; do
  docker pull "$img"
done
docker save falcosecurity/falco:0.45.0 \
            falcosecurity/falcoctl:0.14.2 \
            falcosecurity/falco-driver-loader:0.45.0 \
            falcosecurity/falcosidekick:2.32.0 -o images/falco.tar

docker pull openpolicyagent/gatekeeper:v3.23.1
docker save openpolicyagent/gatekeeper:v3.23.1 -o images/gatekeeper.tar

docker pull mysql:8.0
docker save mysql:8.0 -o images/mysql.tar

docker pull kindest/node:v1.37.0
docker save kindest/node:v1.37.0 -o images/kindest-node.tar
```

**关键：必须导出「规范镜像名」。** `Makefile` 的 `image.repository`
只认 `falcosecurity/falco` 这类规范名。若你用了镜像加速器前缀
（如 `0wqcfr78pnd1zo9kvk.xuanyuan.run/falcosecurity/falco`），
**务必先 retag 回规范名再 save**：

```bash
docker pull ${MIRROR}/falcosecurity/falco:0.45.0
docker tag  ${MIRROR}/falcosecurity/falco:0.45.0 falcosecurity/falco:0.45.0
```

脚本已内置该逻辑（`IMAGE_PREFIX` 变量）：

```bash
IMAGE_PREFIX=0wqcfr78pnd1zo9kvk.xuanyuan.run bash scripts/download-offline-resources.sh
```

或直接给 Docker daemon 配加速器（本项目所在机器就是这样，最省事）：

```json
// /etc/docker/daemon.json
{
  "registry-mirrors": ["https://0wqcfr78pnd1zo9kvk.xuanyuan.run"]
}
```

配好后普通 `docker pull` 自动走加速器，且**镜像名仍是规范名**。

#### B3. 获取 Python wheel

```bash
python3 -m pip download -r requirements.txt -d wheels \
  -i https://pypi.tuna.tsinghua.edu.cn/simple \
  --trusted-host pypi.tuna.tsinghua.edu.cn --retries 3 --timeout 60
python3 -m pip download pymysql -d wheels \
  -i https://pypi.tuna.tsinghua.edu.cn/simple \
  --trusted-host pypi.tuna.tsinghua.edu.cn
```

> `requirements.txt` 里列了 `psycopg2-binary`（PostgreSQL 驱动），但本项目实际用
> MySQL，业务代码 `src/db.py` 依赖的是 `pymysql`。两个都下载以保运行。

### 方式 C：POC 演示额外需要 alpine 镜像

`tests/pochack` 用 `alpine:latest` 构造攻击 Pod。该镜像**不在上述清单里**，
需要额外导入（见 3.3）：

```bash
docker pull alpine:latest
docker save alpine:latest -o /tmp/alpine.tar
```

---

## 三、在内网部署机使用

### 3.1 拷贝与前置检查

把整个项目目录拷贝到内网机（含 `charts/`、`images/`、`wheels/`），然后：

```bash
cd security
df -h /            # 镜像导入会在每个节点内解压展开，务必留足空间
                   # 实测：3 节点集群 + 上述全部镜像约需 8~10GB
docker --version && kind --version && kubectl version --client && helm version --short
```

组件版本要求：Docker、Kind、kubectl、Helm 均已安装（本身不需要联网）。

### 3.2 一键部署

```bash
export KUBECONFIG=$HOME/.kube/config
make deploy-components      # 已有集群时使用：导镜像 → Gatekeeper → Falco → MySQL → 策略
```

若还没有集群，用 `make deploy`（会先建集群）。

> **注意**：`install-falco` 使用 `helm install`。若 `falco-system` 下已存在同名
> release，会报 `cannot re-use a name that is still in use`，需先
> `helm uninstall falco -n falco-system`，或把 Makefile 改为 `helm upgrade --install`。

### 3.3 导入 alpine 镜像（演示需要）

Kind 节点**无法自行拉取镜像**（`registry-1.docker.io` 在该网络不可达，
实测被解析到 `31.13.82.33`/`174.37.54.20` 等地址导致 `connection refused`）。
必须手工导入到**每一个**节点：

```bash
for node in $(kubectl get nodes -o name | sed 's|node/||'); do
  docker cp /tmp/alpine.tar "$node:/root/alpine.tar"
  docker exec "$node" ctr -n k8s.io images import /root/alpine.tar
  docker exec "$node" rm -f /root/alpine.tar
done
```

> 用了 `ctr import` 而非 `kind load`：多架构镜像经镜像代理中转后，
> `kind load` 会因摘要不一致报 `content digest not found`。

### 3.4 Python 依赖离线安装

```bash
python3 -m venv venv
./venv/bin/pip install --no-index --find-links=wheels -r requirements.txt
./venv/bin/python -c "import flask, pymysql, kubernetes; print('依赖 OK')"
```

---

## 四、驱动类型选择（关键决策）

本项目使用 **`driver.kind=modern_ebpf`**（CO-RE），不是 `module`/`kmod`。原因：

| 驱动 | 是否需要内核头文件 | 是否需要联网 | 结论 |
|---|---|---|---|
| `module`（kmod） | **需要**，DKMS 编译 | 需要下载预编译驱动或源码 | 离线环境必然失败 |
| `modern_ebpf` | 不需要 | 不需要 | **本项目采用** |

实测失败现场（`driver.kind=module`）：

```
Trying to download a driver. url: https://download.falco.org/driver/...
WARN  Non-200 response from url. code: 404      ← 无预编译驱动
Error! Your kernel headers for kernel 5.14.0-... cannot be found
       at /lib/modules/.../build or .../source
ERROR failed: failed to build requested driver
```

**前提条件**：内核需支持 BTF。部署前检查：

```bash
ls /sys/kernel/btf/vmlinux && echo "BTF 存在，可用 modern_ebpf"
```

---

## 五、常见问题

### 5.1 节点报 ImagePullBackOff，但镜像明明导入过

- 确认导入到了**所有**节点（Kind 每个节点有独立 containerd，Pod 随机调度）。
  用 `docker exec <node> ctr -n k8s.io images ls | grep <name>` 逐个核对。
- 若 Pod 用 `:latest` 标签，注意 `kubectl run` 默认 `imagePullPolicy=Always`，
  **会强制联网校验**。离线环境请显式写 `imagePullPolicy: Never` 或 `IfNotPresent`。

### 5.2 `ctr import` 报 `no such file or directory`

Kind 节点内 `/tmp` 是 **tmpfs**，会遮挡 `docker cp` 写入 overlay 层的文件
（`docker cp` 自身返回 0，极具迷惑性）。**请用 `/root/` 或 `/` 等 overlay 路径**，
本项目 `Makefile` 的 `load-images` 已改为 `/root/`。

### 5.3 Falco 报 `Couldn't resolve host name`

集群 DNS 故障。检查 CoreDNS：

```bash
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=20
# 若见 "waiting for Kubernetes API" / "Plugins not ready: kubernetes"：
kubectl rollout restart deployment coredns -n kube-system
```

### 5.4 `helm repo add` / `helm pull` 超时或被重置

本项目**不依赖 Helm 仓库**（Chart 已本地化）。确认 `charts/` 下文件存在即可，
脚本会自动跳过仓库操作。若需联网拉取而链路受限，可配代理：

```bash
export https_proxy=http://<proxy>:<port>
```

### 5.5 空间不足

镜像导入会在**每个节点内**解压展开，占用远超 tar 体积。实测经验：

- 仅拉取 + 导出：约需 5.4GB
- 导入到 3 节点集群：额外约 6GB

排查与清理：

```bash
docker system df                      # 查看可回收空间
docker volume ls                      # 注意孤儿卷
docker image prune -f                 # 清悬空层
```

---

## 六、资源是否需要入库（Git LFS 说明）

本仓库 `.gitattributes` 将 `charts/*.tgz` 与 `images/*.tar` 标记为 **Git LFS** 对象。
但请注意：

- GitHub 免费账户 LFS 配额为 **1GB 存储 + 1GB/月带宽**，
  而全部镜像 tar 合计 **1.12GB**，**超出配额**。
- 因此**建议不将 `images/*.tar` 提交入库**，改为：
  1. 本仓库只保留 `charts/*.tgz`（合计 220K，LFS 无压力）；
  2. 镜像由使用者在能上网的机器上执行
     `scripts/download-offline-resources.sh` 现场生成。

这样仓库保持轻量（clone 快），且 `.gitignore` 注释中
"离线资源脚本产物，按需提交" 的设计意图得以保持。

若确实要入库，需要：
- 先安装 `git-lfs`（本项目所在环境用 `dnf install -y git-lfs`）；
- 确保 LFS 配额充足，否则 push 会被拒绝。

---

## 七、资源清单校验

部署前可用以下命令校验资源完整性：

```bash
# Chart 校验
sha256sum charts/falco-9.2.0.tgz
# 期望: 5e0699e68e5e4abd5eab1d501b3e0300a15888f3a5c2b0977bf3ca3229a8d04a
helm dependency list charts/falco-9.2.0.tgz
# 期望: falcosidekick / k8s-metacollector / falco-talon 均为 unpacked

# 镜像 tar 校验（列出内含镜像名）
for t in images/*.tar; do
  echo "--- $t"
  tar -xf "$t" -C /tmp manifest.json 2>/dev/null && \
    python3 -c "import json;print(*[r.get('RepoTags') for r in json.load(open('/tmp/manifest.json'))],sep='\n')"
  rm -f /tmp/manifest.json
done

# wheel 数量
ls wheels/*.whl | wc -l     # 期望: 32
```
