# 四平面完成定义（Definition of Done）

> 目的：杜绝"装完即完成"。每个平面只有在**功能 + 可靠性 + 安全 + 可观测 + 文档 + 验收命令**六项都满足，才算 DoD 达成。
> 关联：[`implementation-matrix.md`](implementation-matrix.md)、[`data-plane-management.md`](data-plane-management.md)。

## 通用 DoD（所有平面）
- [ ] 全部资源**声明式**（Git 为源），无手工 `kubectl edit` 残留。
- [ ] 有**入口条件**与**验收命令**，且验证通过。
- [ ] 有**告警**与**runbook**。
- [ ] 有**回滚/恢复**方案并演练过。
- [ ] 文档更新（本册/命令详解/状态总览）。
- [ ] **不引入不可逆违约**（命名/SC/网段/身份映射不改已发布契约）。

---

## 数据平面
- [ ] 承载形态明确（A/B/C/D），生产用 **B 独立数据集群（云无关）**。
- [ ] 引擎 Operator 常驻（CNPG + Redis 方案 + 对象存储）。
- [ ] 供给抽象可用（`DatabaseClaim/RedisClaim` 或等价），金标 profile S/M/L 定义。
- [ ] 备份三层齐备：数据盘 + 本地快照 + **异地 S3 出口**；**PITR 可用**。
- [ ] **恢复演练**通过（独立 ns/临时集群还原并校验）。
- [ ] 数据面专属可观测（exporter + 备份时效/failover/复制延迟告警）。
- [ ] 安全：in-transit TLS、静态加密、最小权限角色、pgAudit、密钥经 ESO/KMS。
- [ ] 跨集群消费方案就绪（ClusterMesh / LB+DNS）+ 源 CIDR 白名单。
- 验收：`make verify-data`：端点可达 + 备份时效 + （配 S3 时）PITR 恢复演练。

## 工具链·管理平面
- [ ] Harbor 单项目 + robot + scheme C；节点 containerd 指向 Harbor（insecure/CA 正确）。
- [ ] 镜像管道（prepare/push）与 **Chart OCI** 推送/拉取可用。
- [ ] GitLab（route C）可用；Runner 注册并可跑流水线（CI）。
- [ ] 身份：Casdoor 部署 + **OIDC 接入 Harbor/GitLab** + 组→RBAC 映射表。
- [ ] 可观测：Prometheus/Grafana/Loki/告警，Grafana 可登录且有数据。
- [ ] 策略/密钥：Kyverno（准入）+ External-Secrets/Sealed（密钥零明文）。
- [ ] **可外置**：另一集群能"零改造"消费本平面（镜像/身份/CI）。
- 验收：`crictl pull` 走 Harbor；`helm show chart oci://...`；Grafana 登录；新集群接 Harbor+GitLab。

## 集群平面
- [ ] 单节点与多节点**同契约**（同 SC/入口/DNS/命名），scale-out 不改契约。
- [ ] CNI/CSI/Gateway/节点池就绪；Gateway 监听名固定（如 `https`）。
- [ ] 存储契约就绪（`app-storage`、Retain、扩容、快照类）。
- [ ] 节点标准化（镜像/内核/依赖如 open-iscsi），可重建。
- [ ] 内网 DNS 与 VIP 稳定。
- 验收：`kubectl get nodes`；`kubectl get sc`；单节点→多节点演练平滑。

## 租户平面
- [ ] 租户开通**自助**（脚本或 Backstage），带配额/PSA/NetworkPolicy/RBAC。
- [ ] 隔离验收：跨 ns 访问被拒；PSA 拒绝 privileged；配额生效。
- [ ] 身份→RBAC 映射生效（组授权，不按人）。
- [ ] 模式可组合（A/B/C），按客户规模选档。
- [ ] GitOps 交付通道可用（Flux/ArgoCD）。
- 验收：`make verify-tenant`：隔离用例 + 配额/PSA/RBAC/NetworkPolicy。

---

## 每层"完成即可交付"的判定
| 平面 | 可对外承诺的信号 |
|---|---|
| 数据 | 新应用"只填端点+secret"即可用；PITR 恢复演练成功 |
| 工具链 | 新集群零改造接入镜像/身份/CI |
| 集群 | 单节点可平滑扩到多节点且契约不变 |
| 租户 | 租户自助开通且隔离验收通过 |
