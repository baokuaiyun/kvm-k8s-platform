# 集群定位（Role）骨架

> 说明：本目录为**骨架/模板**，尚未接入 Makefile。定位与安装选择最终见
> [`docs/implementation-matrix.md`](../docs/implementation-matrix.md)。
> 目标用法（规划）：`make install CLUSTER_ROLE=data`（或 `PLANES=data,toolchain`），
> 按 role 套用对应平面 bundle，可幂等追加。

## 定位定义
| Role | 平面 | 内容 |
|---|---|---|
| `data` | 数据平面 | CNPG / Redis / 对象存储 / 备份(PITR) / 供给抽象 |
| `toolchain` | 工具链·管理平面 | Harbor / GitLab / Runner / 镜像管道 / Casdoor / 可观测 / 策略·密钥 |
| `workload` | 集群平面 | CNI / CSI / Gateway / 节点池 |
| `tenant` | 租户平面 | Mode A/B/C / 配额 / RBAC / 自助 |
| `all-in-one` | 全部 | drill / 小客户（简化） |

组合示例：`mgmt = data+toolchain`；`biz = workload+tenant`。

## 与现有目录的映射（当前 all-in-one）
| 平面 | 现有目录 |
|---|---|
| 数据 | `platform/platform-data/`, `storage/` |
| 工具链 | `platform/{harbor,gitlab,casdoor}/`, `registry/`, `observability/` |
| 集群 | `kvm/`, `kubernetes/` |
| 租户 | `infrastructure/{security,tenants,crossplane}/` |

> 后续（非本轮）：新增 `planes/<plane>/` 收拢各平面清单，Makefile 增 `CLUSTER_ROLE`/`PLANES` 编排。
