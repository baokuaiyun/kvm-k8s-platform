# 参数设置说明（Settings Reference）

> 单一真源：默认值在 [`variables.mk`](../variables.mk)；环境覆盖在 `gitops/profiles/*.env`；
> 密钥在 `acr.env`（gitignored）。本页集中说明"变量 / 含义 / 默认 / 作用域 / 消费处"。
> 关联 [`implementation-matrix.md`](implementation-matrix.md)、[`bootstrap-order.md`](bootstrap-order.md)、[`repo-topology.md`](repo-topology.md)。

作用域：**G**=全局(variables.mk) · **P**=profile · **S**=密钥(acr.env)

## 集群 / 网络
| 变量 | 含义 | 默认 | 作用域 |
|---|---|---|---|
| `NET_NAME` / `NET_CIDR` / `NET_GATEWAY` | libvirt 网络名/网段/网关 | `br-prod` / `192.168.124.0/24` / `.1` | G |
| `CP_NAMES` / `CP_IPS` / `CP_MACS` | 控制面节点名/IP/MAC | `k8s-cp-1..3` | G |
| `WK_NAMES` / `WK_IPS` / `WK_MACS` | Worker 节点名/IP/MAC | `k8s-worker-1..2` | G |
| `CP_INIT_COUNT` / `WK_INIT_COUNT` | 起步节点数 | `1` / `1` | G |
| `CP_VCPU/RAM/DISK`、`WK_VCPU/RAM/DISK` | 机型规格 | 2C/4G/30G、4C/4G/50G | G |
| `CP_VIP` / `CP_ENDPOINT` | 集群 VIP / API 端点 | `192.168.124.30` / `k8s-api.$(DOMAIN)` | G |
| `VIP_IFACE` | VIP 网卡 | `enp1s0` | G |

## 版本
| 变量 | 含义 | 默认 |
|---|---|---|
| `K8S_VERSION` | Kubernetes 版本 | `1.31.0` |
| `CILIUM_VERSION` / `LONGHORN_VERSION` / `KUBE_VIP_VERSION` | 组件版本 | `1.16.0` / `1.7.0` / `0.8.7` |
| `CNPG_VERSION` / `REDIS_OP_VERSION` | 数据 Operator | `1.25.1` / `0.17.0` |
| `FLUX_OPERATOR_VERSION` | Flux Operator chart/镜像 | `0.61.0` |

## 域名 / 入口
| 变量 | 默认 |
|---|---|
| `DOMAIN` / `WILDCARD` | `test.baokuaiyun.com` / `*.test.baokuaiyun.com` |
| `HARBOR_HOST` / `GITLAB_HOST` / `GRAFANA_HOST` / `CASDOOR_HOST` / `ARGOCD_HOST` | `<服务>.test.baokuaiyun.com` |

## 镜像 / Harbor
| 变量 | 含义 | 默认 |
|---|---|---|
| `HARBOR_PROJECT` | Harbor 单项目 | `baokuaiyun` |
| `HARBOR_HOST` | 本域 registry | `harbor.test.baokuaiyun.com` |
| `HARBOR_USER` / `HARBOR_PASS` | admin（应急） | S |
| `HARBOR_ADMIN_PASS` / `HARBOR_ROBOT_PASS` | admin/robot 密码 | S |
| `HARBOR_ROBOT_USER` | robot 用户名（脚本内用 `robot$<project>+pushpull` 拼） | `robot$baokuaiyun+pushpull` |
| `MIRROR_DOCKER/QUAY/GHCR/K8S` | 海外源镜像 | `*.m.daocloud.io` / `ghcr.dockerproxy.net` / `k8s-gcr.m.daocloud.io` |
| `BYPASS_PROXY` | 海外拉取绕过本机代理 | `1` |
| `HELM_CHARTS_DIR` | 本地 chart 目录 | `/data/kvm/charts` |

## 存储
| 变量 | 含义 | 默认 |
|---|---|---|
| `STORAGE_BACKEND` | `longhorn` \| `alicloud` | `longhorn` |
| `STORAGE_CLASS` / `SNAPSHOT_CLASS` | 规范 SC / 快照类 | `app-storage` / `longhorn` |
| `LONGHORN_REPLICAS` / `LONGHORN_ALLOW_CONTROL_PLANE` | 副本数 / 允许控制面调度 | `2` / `true` |
| `BACKUP_TARGET` | Longhorn 异地目标 | `nfs://192.168.124.1:/data/backups/longhorn` |
| `HARBOR_REGISTRY_SIZE` / `HARBOR_JOBSERVICE_SIZE` / `HARBOR_TRIVY_SIZE` | Harbor PVC | `50Gi`/`5Gi`/`10Gi` |

## 数据平面
| 变量 | 含义 | 默认 |
|---|---|---|
| `PLATFORM_DATA_NS` | 数据命名空间 | `platform-data` |
| `PG_INSTANCES` / `PG_SYNC_REPLICAS` | PG 实例/同步副本 | `1` / `0` |
| `REDIS_CLUSTER_SIZE` | Redis 规模 | `1` |
| `PG_STORAGE_SIZE` / `REDIS_STORAGE_SIZE` | PVC | `20Gi` / `5Gi` |
| `PG_HARBOR_PASS`/`PG_GITLAB_PASS`/`PG_CASDOOR_PASS`/`REDIS_PASS` | 角色/Redis 密码 | S |
| `PG_BACKUP_BUCKET` / `S3_ENDPOINT` | barman 对象存储 | 空（drill）|
| `VELERO_BUCKET` / `OSS_REGION` | Velero 桶/区域 | `velero-backup` |
| `BACKUP_RETENTION_DAYS` / `OFFSITE_RETENTION_DAYS` | 保留 | `7` / `30` |

## Flux / GitOps（详见 gitops/settings.md）
| 变量 | 含义 | 默认 | 作用域 |
|---|---|---|---|
| `CLUSTER_TYPE` | A 管理/开发者 · B 生产/业务 · all 合一 | `all` | G/P |
| `FLEET_MODE` | fleet 模式（all-in-one/mgmt/biz/data） | `all-in-one` | 命令/P |
| `FLEET_ENV` | 环境（drill/prod/enterprise） | `drill` | 命令/P |
| `TOOLCHAIN_MODE` | selfhost \| consume | `selfhost` | P |
| `ENABLE_FLUX` | 是否安装 Flux | `true` | P |
| `DATA_SOURCE` | 应用数据来源 local \| shared | `local` | P |
| `GIT_MODE` | Git 接入时机 later/now | `later` | P |
| `FLUX_NS` / `GHCR_MIRROR` | Flux ns / GHCR 源 | `flux-system` / `ghcr.dockerproxy.net` | G |

## 其他
| 变量 | 含义 | 默认 |
|---|---|---|
| `CASDOOR_VERSION` / `CASDOOR_DB_*` | Casdoor 版本/库 | `latest` / `casdoor` |
| `GITLAB_OBJECT_STORE` / `GITLAB_OSS_BUCKET` | GitLab 对象存储 | `minio` / `gitlab-object` |
| `PROMETHEUS_SIZE` / `PROMETHEUS_RETENTION` / `GRAFANA_SIZE` / `LOKI_SIZE` | 可观测 PVC/保留 | `20Gi`/`15d`/`5Gi`/`20Gi` |

## profile 覆盖（gitops/profiles/*.env）
- `drill.env`：`CLUSTER_TYPE=all`、`DATA_SOURCE=local`、内嵌 Longhorn/MinIO。
- `prod.env`：`CLUSTER_TYPE=A`(mgmt)、`DATA_SOURCE=shared`、云盘 + OSS。
- `enterprise.env`：`CLUSTER_TYPE=B`、`TOOLCHAIN_MODE=consume`、强隔离。
