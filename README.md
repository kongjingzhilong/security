# 基于 Falco 与 OPA 的云原生容器多步攻击检测与动态准入控制系统
> 本科生科创项目 · 云原生安全 | 学习优先、竞赛为辅
> 面向 Kubernetes 的运行时安全闭环防护：检测 → 风险评估 → 差异化处置 → 动态准入
## 项目简介
Kubernetes 容器环境中，攻击面持续扩大，现有安全组件存在明显割裂：
- **Falco**（运行时检测）能基于系统调用捕获容器恶意行为，但只输出告警，缺少风险评估与自动处置能力；
- **OPA Gatekeeper**（准入控制器）只能做静态策略校验，无法响应运行时动态攻击；
- 传统方案直接拉黑公共基础镜像，极易造成大规模业务误杀。
本系统打通检测与处置闭环，构建一套**运行时检测 + 风险量化 + 动态准入 + 应急驱逐**的完整防护体系。
## 核心创新点
1. **时间窗口告警聚合**：对同一 Pod/ServiceAccount/Namespace 维护 5 分钟滑动时间窗口，将多条低危告警聚合为链式组合攻击并自动升级风险等级，识别"侦察→入侵→凭证窃取"多步攻击。
2. **公共基础镜像降级机制**：命中公共镜像前缀（ubuntu、nginx、alpine 等）时，高危事件仅驱逐恶意 Pod，**不自动拉黑镜像**，避免业务大面积中断；私有业务镜像高危事件执行 Pod 驱逐。
3. **DREAD 五维风险评估模型**：对容器内攻击行为量化风险分级（Info / Low / High / Critical），差异化处置。
4. **策略模板引擎 + Dry-run 预校验**：运行时告警事件自动生成候选准入策略，经结构级冲突检测 + Dry-run 影响范围评估后，避免自动策略误杀正常业务。
5. **HMAC 签名校验**：Webhook 接口校验告警真实性，抵御伪造告警投毒攻击。
## 系统架构
```
[靶场 Kind 集群]
    ├─ Falco (eBPF)           容器系统调用采集 → Webhook 推送告警
    ├─ OPA Gatekeeper         准入控制器，执行动态准入策略
    └─ 业务/攻击 Pod          受监测的容器负载
[后端服务 FastAPI]
    ├─ Webhook 接口（HMAC 签名校验 + 来源 IP 白名单）
    ├─ 告警事件标准化解析（提取镜像/SA/Namespace 实体）
    ├─ 时间窗口告警聚合（链式攻击风险重评估）
    ├─ DREAD 风险评估模块
    ├─ 公共镜像前缀匹配 + 降级处置逻辑
    ├─ Rego 策略模板引擎 + 结构级冲突检测 + Dry-run 预校验
    ├─ K8s Python Client（Pod 驱逐 + 策略版本管理 + 回滚）
    └─ PostgreSQL（告警/策略版本/审计日志）+ Redis（实时缓存）
```
## 威胁建模与对标
- **STRIDE 威胁建模**：识别伪造告警投毒、告警篡改、SA Token 横向移动、告警风暴 DoS 等攻击面并设计缓解措施。
- **MITRE ATT&CK v16.1 (Containers platform)**：系统能力覆盖 8 项容器攻击技术，包括 Unix Shell（T1059.004）、容器逃逸（T1610）、Secrets/SA Token 窃取（T1552.007）、C2 通信（T1071.004）等。
## 端到端演示场景
1. **私有业务镜像反弹 Shell** → DREAD 判定 Critical → 驱逐 Pod + 自动下发镜像黑名单准入策略
2. **公共 nginx 镜像反弹 Shell** → 触发降级机制 → 仅驱逐 Pod，不拉黑镜像，候选策略进入人工预审
3. **容器读取 /etc/shadow 敏感文件** → 高危 → 驱逐 Pod
4. **链式组合攻击**（端口扫描 → 交互式 Shell → 窃取 SA Token）→ 时间窗口聚合识别为高危链式攻击，升级处置
## 环境依赖（版本锁定，禁止 latest）
推荐：Rocky Linux 9（物理机/虚拟机），内核 ≥5.14
Kind 0.20.0 · Kubernetes 1.28.x · Falco 0.37.x (modern-bpf) · OPA Gatekeeper 3.14.x
· Python 3.11 · python-kubernetes（与K8s版本匹配）· PostgreSQL 15 · Redis 7 · FastAPI
## 快速部署
```bash
# 1. 克隆仓库
git clone [https://github.com/kongjingzhilong/security.git](https://github.com/kongjingzhilong/security.git)
cd security
# 2. 安装 Python 依赖
pip install -r requirements.txt
# 3. 部署 Falco、OPA Gatekeeper 到 Kind 集群（参考 deploy/helm/）
# 4. 配置 Falco Webhook 指向本系统接口，配置 HMAC 密钥
# 5. 初始化数据库（执行 sql/init.sql 建表）
# 6. 启动后端
uvicorn main:app --reload
```
## 实验设计与指标
- **5 组对照实验**：无防护基线 → 仅 Falco → 单告警 DREAD → 链式聚合（无降级）→ 完整系统
- **12 个标准化攻击场景**，每个场景重复 10 次，统计均值与标准差
- **评价指标**：攻击检出率、阻断率、误报率、策略误阻断率、策略生效延迟、系统资源开销
- 原始实验数据归档于 `dataset/` 目录（CSV 格式）
## 实现进度
> 本仓库按 MVP 逐步推进，与完整设计方案一致，未实现模块如实列为 Future Work。
- [x] 靶场环境搭建、Falco 规则调优
- [x] Webhook 接收 + HMAC 签名校验
- [x] 告警事件标准化解析
- [x] DREAD 风险评估
- [x] Pod 应急驱逐
- [x] 公共基础镜像降级处置逻辑
- [ ] 时间窗口告警聚合（链式攻击识别）
- [ ] Rego 策略模板引擎 + 自动下发
- [ ] Dry-run 预校验、策略版本回滚
- [ ] Web 可视化审计面板
- [ ] 告警风暴限流、告警去重
## 局限性
1. 告警聚合仅支持同一 Pod/SA/Namespace 内事件，跨 Pod/跨命名空间攻击图推理未实现；
2. 镜像识别仅匹配仓库前缀，无法识别二次封装镜像的底层基础镜像；
3. 系统效果依赖 Falco 规则质量，原生规则存在噪音，需针对靶场调优；
4. Dry-run 模拟结果与真实准入存在微小差异，仅作为影响评估参考。
## 许可
Apache-2.0
## 说明
本项目为本科生科创学习项目，用于云原生安全工程实践与竞赛备赛。完整设计方案详见项目计划书，所有实验仅在本地自建隔离集群内完成，不针对任何第三方线上系统进行测试。
```
### 几点提醒
2. 你现在在 `main` 分支新建文件，直接点「提交更改」即可；后续如果创建了 `deploy/`、`sql/`、`dataset/`、`tests/` 目录，再回来补充对应链接。
