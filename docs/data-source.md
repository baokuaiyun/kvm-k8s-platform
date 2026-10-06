# 数据来源（按应用决定：local | shared）

> 成员/业务集群的数据来源**不是全局规则**，而是**由各自应用决定**。
> 关联 [`data-plane-management.md`](data-plane-management.md)、[`bootstrap-order.md`](bootstrap-order.md)。

## 一、两种来源
| 值 | 含义 | 适用 |
|---|---|---|
| `DATA_SOURCE=local` | 应用在本集群内自起数据（CNPG/Redis/…） | 隔离强、低延迟、离线；每集群一套 |
| `DATA_SOURCE=shared` | 应用消费"本"数据平面（外部端点） | 多集群共享、集中治理、省资源 |

## 二、判定建议（按应用特性）
| 应用特性 | 建议 |
|---|---|
| 强隔离/合规、低延迟、离线 | `local` |
| 多集群共享、需集中备份/PITR、S 档小体量 | `shared` |
| 引导关键（Harbor 的 PG/Redis） | **必须引导面**（见下） |

## 三、引导面例外（不可选）
- **Harbor 及其依赖的 PG/Redis 永远在引导面**（`platform-pg`/`platform-redis`），与成员的 `DATA_SOURCE` 无关。
- Flux 面的应用（GitLab/Casdoor 等）可配置为消费引导面数据（`shared`），但**引导面先于它们**。

## 四、落法
- 声明：应用的 `component.yaml` 或 GitLab CR/Casdoor 配置中带 `dataSource: local|shared`（默认取 profile 的 `DATA_SOURCE`）。
- `shared`：端点取本数据平面（`platform-pg-rw.<ns>.svc` / 外部 LB+DNS），凭据经 ESO/Sealed。
- `local`：在本集群用 `components/data/*` 起 CNPG/Redis。

## 五、与拓扑的关系
- 引导面数据（Harbor 用）= 本集群自启（方案 A：共享实例入引导面）。
- 成员应用数据 `shared` = 依赖本数据平面（可独立数据集群 B）。
- 成员应用数据 `local` = 各自本地数据平面。

> 结论：**数据来源是"应用级选择"，但 Harbor 的数据是"引导面固定项"。**
