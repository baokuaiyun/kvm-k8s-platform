# gitops/ 参数设置（精简）

> 完整参数说明见 [`../docs/parameters.md`](../docs/parameters.md)；此处仅列 GitOps 直接相关项。

| 变量 | 含义 | 默认 | 作用域 |
|---|---|---|---|
| `CLUSTER_TYPE` | 集群类型 A 管理/开发者 · B 生产/业务 · all 合一 | `all` | variables.mk/profile |
| `FLEET_MODE` | fleet 模式（all-in-one/mgmt/biz/data） | `all-in-one` | 命令/profile |
| `FLEET_ENV` | 环境（drill/prod/enterprise） | `drill` | 命令/profile |
| `TOOLCHAIN_MODE` | selfhost 自托管 Harbor/Git · consume 消费外部 | `selfhost` | profile |
| `ENABLE_FLUX` | 是否安装 Flux | `true` | profile |
| `DATA_SOURCE` | 应用数据来源 local · shared | `local` | profile（可按应用覆盖） |
| `GIT_MODE` | Git 接入时机（later/now） | `later` | profile |
| `FLUX_OPERATOR_VERSION` | Flux Operator chart/镜像版本 | `0.61.0` | variables.mk |
| `FLUX_NS` | Flux 命名空间 | `flux-system` | variables.mk |
| `GHCR_MIRROR` | GHCR 拉取镜像源 | `ghcr.dockerproxy.net` | variables.mk |

> 解析键：`(FLEET_MODE, FLEET_ENV, CLUSTER_TYPE)` → `gitops/locks/<mode>-<env>-<type>.lock`。
