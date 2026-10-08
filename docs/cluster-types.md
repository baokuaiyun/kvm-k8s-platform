# 集群类型与递进：管理/开发者平台 vs 生产/业务

> 结论：**按"两种集群类型"分离，各自递进**；**安全/可观测/GitOps 是两类共有的横切基线**。
> 不是"单集群把安全→监控→租户→CI→IDP 全叠"。关联 [`implementation-matrix.md`](implementation-matrix.md)、
> [`bootstrap-order.md`](bootstrap-order.md)、[`tenant-isolation-architecture.md`](tenant-isolation-architecture.md)。

## 一、两条正交的轴
- **能力成熟度（横）**：安全 → 可观测 → 身份 → 制品/CI → CD → 开发者平台/租户隔离（递增）。
- **集群类型（纵）**：A 管理/开发者平台 ｜ B 生产/业务。**同一成熟度在两类里内容不同**。

## 二、类型 A：管理/开发者平台集群（含"本"集群）
职责：中心化共享服务 + 自助开发者能力。自托管 Harbor/Git，供成员依赖。

| 步 | 递进内容 |
|---|---|
| A1 | **安全基线**：PSA/RBAC/NetworkPolicy/密钥(ESO/Sealed) |
| A2 | **可观测（中心）**：Prometheus/Grafana/Loki/告警/SLO |
| A3 | **身份**：Casdoor SSO → Harbor/GitLab/k8s |
| A4 | **制品与 CI**：Harbor + GitLab + Runner / Tekton |
| A5 | **CD（Flux Operator）**：OCI 制品 + cosign 验签 |
| A6 | **开发者平台(IDP)**：Backstage + 模板 + Crossplane 自助 |
| A7 | **数据平面**：共享 PG/Redis/对象存储（可独立数据集群 B） |

## 三、类型 B：生产/业务集群（成员）
职责：稳定承载生产负载 + 租户隔离。消费 A 的 Harbor/Git 与（可选）数据平面。

| 步 | 递进内容 |
|---|---|
| B1 | **安全基线**：PSA/RBAC/NetworkPolicy |
| B2 | **可观测（agent→中心）**：node-exporter/promtail/OTel |
| B3 | **命名空间租户**：Mode A（Quota+RBAC+NetPol） |
| B4 | **隔离租户**：Mode C（vCluster/独立控制面） |
| B5 | **规模化**：多集群、节点池、容量与成本（计算图层见 [`compute-architecture.md`](compute-architecture.md)） |

## 四、横切基线（两类都从第 1 步就打）
- **安全**：PSA/NetworkPolicy/RBAC/密钥供应链。
- **可观测**：指标/日志/告警（B 为 agent，A 为中心）。
- **GitOps**：Flux 交付（A 为源，B 为消费）。
- **镜像来源**：统一 Harbor + 签名。

## 五、CI/CD 位置（重要）
- **CI（GitLab/Tekton）属类型 A（开发者平台侧）**，**不放入生产集群**。
- **CD（Flux）两类都有**：A 管理自身与制品，B 消费制品部署业务。
- 生产集群只**拉取**已签名制品，不承担构建。

## 六、为什么分离（不是单集群全叠）
1. **爆炸半径**：CI/IDP 与生产同集群，构建风暴/权限事故会波及生产。
2. **资源/安全**：构建需特权与大资源；生产要稳定，混跑互害。
3. **规模化**：A 少而稳（1–2 个），B 多且按客户/规模扩。
4. **权限边界**：开发者平台的高权限不应进入生产命名空间。

## 七、例外：all-in-one
drill/小客户用 **all-in-one** 把两类合一，按需演进；生产/多客户下必须分离为 A/B。

## 八、与四平面/模式对应
| 集群类型 | 四平面侧重 | fleet 模式 |
|---|---|---|
| A 管理/开发者 | 工具链 + 数据 | `mgmt`（自托管）、`all-in-one` |
| B 生产/业务 | 集群 + 租户 | `biz`（成员）、`data`（数据） |
