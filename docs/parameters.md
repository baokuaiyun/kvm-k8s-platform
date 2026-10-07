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
| `CP_INIT_COUNT` / `WK_INIT_COUNT` | 起步节点数（单节点起步）| `1` / `0` | G |
| `CP_VCPU/RAM/DISK`、`WK_VCPU/RAM/DISK` | 多节点机型规格 | 2C/4G/30G、4C/4G/50G | G |
| `NODE_VCPU/RAM/DISK` | 单节点起步机型（cp-1）| 8C/16G/120G | G |
| `CP_VIP` / `CP_ENDPOINT` | 集群 VIP / API 端点 | `192.168.124.30` / `k8s-api.$(DOMAIN)` | G |
| `VIP_IFACE` | VIP 网卡 | `enp1s0` | G |

## 节点 / LB IP（服务负载均衡地址）
> 三环境（KVM/阿里云 ECS/裸机）差异只改这几个开关；应用侧契约（`Service type=LoadBalancer`、Gateway listener `https`）不变。
> 分层优先级：G 默认（`variables.mk`）<- P 覆盖（`gitops/profiles/<env>.env`，`make ... ENV=<env>`）<- S 密钥（`acr.env`）。

| 变量 | 含义 | drill 默认 | prod(阿里云) | 作用域 |
|---|---|---|---|---|
| `NODE_IP_MODE` | 节点 IP 来源 `static`\|`dhcp`\|`cloud` | `static` | `cloud` | G/P |
| `LB_IP_MODE` | LB 实现 `cilium-l2`\|`kubevip`\|`metallb`\|`slb`\|`none` | `cilium-l2` | `slb` | G/P |
| `LB_POOL_START` / `LB_POOL_END` | Cilium LB IPAM 地址池（避开网关/节点/VIP/DHCP） | `.40` / `.79` | 空 | G/P |
| `GATEWAY_VIP` | 入口主 IP（Gateway/Ingress）；prod 由 SLB 回写 | `192.168.124.31` | 空 | G/P |
| `LB_ANNOUNCE` | 地址宣告 `l2`\|`bgp`\|`cloud` | `l2` | `cloud` | G/P |
| `LB_CLASS` | `loadBalancerClass`（多后端共存/切换） | 空 | `alibabacloud` | G/P |

**地址分区（drill `192.168.124.0/24`）**：`.1` 网关 · `.10-.29` 节点静态 · `.30` CP_VIP(kube-vip 独占) · `.31` GATEWAY_VIP · `.40-.79` LB 池 · `.100-.200` DHCP · `.201-.254` 预留。

> 分层模型、数据路径、三环境差异与双网段规划详见 [`network-architecture.md`](network-architecture.md)；
> 服务/业务 IP（平台入口固定 + 业务按需）详见 [`service-ip-design.md`](service-ip-design.md)。

## 业务网 / 服务 IP（双网卡 / D 方案）
> 功能① 平台入口固定 IP；功能② 业务按需池。`NET_BIZ_ENABLED=1` 时启用业务网；生效值 `EFF_*` 自动选择。

| 变量 | 含义 | 默认(drill) | 作用域 |
|---|---|---|---|
| `NET_BIZ_ENABLED` | 启用业务网（0=沿用管理网） | `0` | G/P |
| `NET_BIZ_NAME` / `NET_BIZ_CIDR` / `NET_BIZ_GATEWAY` | 业务网名/网段/网关 | `br-lan` / `192.168.1.0/24` / `.1` | G/P |
| `MGMT_IFACE` / `BIZ_IFACE` | 节点双网卡 | `enp1s0` / `enp2s0` | G/P |
| `BIZ_HOST_IFACE` | 宿主业务网桥 | `br-lan` | G |
| `LAN_NODE_IPS` | 节点业务网副 IP | `192.168.1.230-234` | G/P |
| `BIZ_GATEWAY_VIP` / `BIZ_LB_POOL_START/END` | 业务网上的①固定入口/②池 | `.235` / `.240-.249` | G/P |
| `EFF_GATEWAY_VIP` / `EFF_LB_POOL_*` / `EFF_BIZ_IFACE` | 生效值（按开关选择） | — | G |

## 版本
| 变量 | 含义 | 默认 |
|---|---|---|
| `K8S_VERSION` | Kubernetes 版本 | `1.31.0` |
| `CILIUM_VERSION` / `LONGHORN_VERSION` / `KUBE_VIP_VERSION` | 组件版本 | `1.16.0` / `1.7.0` / `1.2.4` |
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
| `STORAGE_BACKEND` | `host-zfs-iscsi` \| `longhorn` \| `alicloud` | `host-zfs-iscsi` |
| `STORAGE_CLASS` / `SNAPSHOT_CLASS` | 规范 SC / 快照类 | `app-storage` / `host-zfs-iscsi` |
| `ZFS_POOL` / `HOST_DATA_DISK` / `HOST_ZFS_VDEV` | 宿主 ZFS 池/盘 | `tank` / `/dev/sdb` / 同上 |
| `HOST_ZFS_USE_FILE` / `HOST_ZFS_FILE*` | drill 文件 vdev | `1` / `/data/zfs-pool.img` / `50G` |
| `ZFS_COMPRESSION` / `ZFS_ENCRYPTION` | 压缩 / 加密 | `zstd` / `off` |
| `ISCSI_TARGET_IQN` / `ISCSI_IQN_PREFIX` | iSCSI target | `iqn.2026-01.com.baokuaiyun:k8s` |
| `DEMOCRATIC_CSI_VERSION` / `CSI_NAMESPACE` | 云盘 CSI | `0.15.0` / `democratic-csi` |
| `HOST_MINIO_ENDPOINT` / `HOST_MINIO_PORT` / `HOST_MINIO_DATA` | 宿主 MinIO | `http://192.168.124.1:9000` / `9000` / `/data/minio` |
| `LONGHORN_REPLICAS` / `LONGHORN_ALLOW_CONTROL_PLANE` | [可选后端] 副本/控制面调度 | `2` / `true` |
| `BACKUP_TARGET` | [可选] Longhorn 异地目标 | `nfs://192.168.124.1:/data/backups/longhorn` |
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

## 告警通知与 PV 自动扩容
> 多渠道配置与导入方法详见 [`alert-notification.md`](alert-notification.md)。

| 变量 | 含义 | 默认 | 作用域 |
|---|---|---|---|
| `ALERT_NAMESPACE` | Alertmanager 所在 ns | `monitoring` | G |
| `ALERT_WEBHOOK_ENABLED` / `ALERT_WEBHOOK_URL` / `ALERT_WEBHOOK_TYPE` | Webhook 通知开关/地址/类型（generic\|slack\|dingtalk\|wecom）| `0` / 空 / `generic` | G / S |
| `ALERT_WARNING_CHANNELS` | warning 渠道 `all`(同 critical) \| `email` | `all` | G |
| `ALERT_EMAIL_ENABLED` / `ALERT_EMAIL_TO` / `ALERT_EMAIL_FROM` | 邮件通知开关/收件人/发件人 | `0` / 空 | G |
| `SMTP_SMARTHOST` / `SMTP_AUTH_USERNAME` / `SMTP_AUTH_PASSWORD` | SMTP 服务器/账号/密码 | 空 | G / S |
| `ALERT_DINGTALK_WEBHOOK` / `ALERT_DINGTALK_SECRET` | 钉钉适配器群机器人地址/加签 | 空 | G / S |
| `ALERT_ADAPTER_IMAGE` | 钉钉适配器镜像 | `.../prometheus-webhook-dingtalk` | G |
| `ALERT_ENV_FILE` | 运维参数文件（默认自动读 `ops.env`）| 空 | G |
| `ALERT_GROUP_WAIT` / `ALERT_GROUP_INTERVAL` / `ALERT_REPEAT_INTERVAL` | 分组等待/间隔/重复 | `30s`/`5m`/`4h` | G |
| `PV_AUTOSCALER_ENABLED` | 是否部署自动扩容控制器 | `1` | G |
| `PV_AUTOSCALER_DRY_RUN` | `1`=只报告（写推荐注解），`0`=实际扩容 | `1` | G |
| `PV_AUTOSCALER_SCHEDULE` | 扫描周期（CronJob） | `*/5 * * * *` | G |
| `PV_AUTOSCALER_THRESHOLD` | 用量比触发阈值 | `0.80` | G |
| `PV_AUTOSCALER_FACTOR` / `PV_AUTOSCALER_MIN_STEP` | 扩容倍数 / 单次最小增量 | `1.5` / `5Gi` | G |
| `PV_AUTOSCALER_MAX_SIZE` | 全局容量上限（PVC 注解 `auto-expand/max-size` 可覆盖）| `100Gi` | G |
| `PV_AUTOSCALER_COOLDOWN_MIN` | 同卷扩容冷却（分钟）| `60` | G |
| `PV_AUTOSCALER_NAMESPACES` / `PV_AUTOSCALER_EXCLUDE` | 白名单 / 排除（ns 或 ns/name，逗号分隔）| 空 | G |
| `PV_AUTOSCALER_NS` / `PV_AUTOSCALER_IMAGE` | 控制器 ns / 镜像 | `kube-system` / `alpine-k8s` | G |
| `PROM_URL` | 控制器查询用 Prometheus 地址 | 集群内 svc | G |

> 逐卷排除：给 PVC 打 `auto-expand/disabled=true`；单卷上限：`auto-expand/max-size=30Gi`。
> 通知参数建议提前在 `acr.env`（密钥）与 profile 中设置，再由 `make alerts` 渲染。

## Flux / GitOps（详见 gitops/settings.md）
| 变量 | 含义 | 默认 | 作用域 |
|---|---|---|---|
| `CLUSTER_TYPE` | A 管理/开发者 · B 生产/业务 · all 合一 | `all` | G/P |
| `FLEET_MODE` | 单个 fleet 模式/layer（单独） | `all-in-one` | 命令/P |
| `FLEET_MODES` | 多单元叠加（逗号列表，如 `core,data,platform`） | 空 | 命令/P |
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
> 用法：`make <target> ENV=<drill|prod|enterprise>`；顶层 Makefile 以 `-include gitops/profiles/$(ENV).env` 在 `variables.mk` **之后**加载，故 P 覆盖 G。密钥仍走 `acr.env`（S）。
- `drill.env`：`CLUSTER_TYPE=all`、`DATA_SOURCE=local`、`STORAGE_BACKEND=host-zfs-iscsi`、`GITLAB_OBJECT_STORE=host-minio`、`WK_INIT_COUNT=0`；`LB_IP_MODE=cilium-l2`、池 `.40-.79`、`GATEWAY_VIP=.31`。
- `prod.env`：`CLUSTER_TYPE=A`(mgmt)、`DATA_SOURCE=shared`、云盘 + OSS；`LB_IP_MODE=slb`、`NODE_IP_MODE=cloud`。
- `enterprise.env`：`CLUSTER_TYPE=B`、`TOOLCHAIN_MODE=consume`、强隔离；LB 同上云上档。
