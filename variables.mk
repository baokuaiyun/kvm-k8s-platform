# =============================================================================
# 全局变量配置 — 修改此文件即可适配不同环境
# 本机演练: DOMAIN=test.baokuaiyun.com
# 阿里云生产: DOMAIN=baokuaiyun.com
# =============================================================================

# 本机凭据（不提交）: cp acr.env.example acr.env 并填真实值
-include $(dir $(lastword $(MAKEFILE_LIST)))acr.env
# 运维客户端参数（不提交，可选）: cp ops.env.example ops.env
# 由 apply-alerts.sh / alert-adapter 以 shell source 方式导入（避免 make 对 $ 的二次解析）

# ============ 网络 ============
NET_NAME   := br-prod
NET_CIDR   := 192.168.124.0/24
NET_GATEWAY := 192.168.124.1

# ============ 节点定义（全量清单；起步规模见下方 INIT_COUNT） ============
CP_NAMES := k8s-cp-1 k8s-cp-2 k8s-cp-3
CP_IPS   := 192.168.124.10 192.168.124.11 192.168.124.12
CP_MACS  := 52:54:00:01:01:01 52:54:00:01:01:02 52:54:00:01:01:03

WK_NAMES := k8s-worker-1 k8s-worker-2
WK_IPS   := 192.168.124.20 192.168.124.21
WK_MACS  := 52:54:00:01:02:01 52:54:00:01:02:02

# ============ 起步规模（单节点起步，后续 make scale-out 扩展） ============
# 单节点 = 1CP + 0W，cp-1 自动去污点承载业务；扩容用 make scale-out 补齐 3CP+2W
CP_INIT_COUNT := 1
WK_INIT_COUNT := 0

# ============ VM 规格 ============
# 起步单节点：唯一节点要同时承载控制面 + 存储 + 平台组件，规格单独放大。
NODE_VCPU := 8
NODE_RAM  := 16384
NODE_DISK := 120G
# 扩容/多节点时 CP/WK 使用下列规格（起步单节点用 NODE_* 覆盖 cp-1）
CP_VCPU := 2
CP_RAM  := 4096
CP_DISK := 30G
WK_VCPU := 4
WK_RAM  := 4096
WK_DISK := 50G
# 单节点起始时是否让 cp-1 使用 NODE_*（=1）还是 CP_*（=0）
# 由 WK_INIT_COUNT==0 自动判定；此变量仅供显式覆盖，一般不用改
SINGLE_NODE_SPEC ?= $(if $(filter 0,$(WK_INIT_COUNT)),1,0)

# ============ 存储路径 ============
DATA_DIR      := /data/kvm
IMAGE_DIR     := $(DATA_DIR)/images
DISK_DIR      := $(DATA_DIR)/disks
SEED_DIR      := $(DATA_DIR)/seeds
BACKUP_DIR    := /data/backups

# ============ 镜像 ============
BASE_IMAGE     := debian-13-generic-amd64.qcow2
BASE_IMAGE_URL := https://cloud.debian.org/images/cloud/trixie/latest/$(BASE_IMAGE)

# ============ 版本 ============
K8S_VERSION     := 1.31.0
K8S_NEW_VERSION := 1.32.0
K8S_MINOR       := $(basename $(K8S_VERSION))
CILIUM_VERSION  := 1.16.0
LONGHORN_VERSION := 1.7.0
KUBE_VIP_VERSION := 1.2.4
CNPG_VERSION    := 1.25.1
REDIS_OP_VERSION := 0.17.0

# Kubernetes apt 源（国内默认阿里云镜像；官方 = https://pkgs.k8s.io/core:/stable:/v$(K8S_MINOR)/deb/）
# 末尾必须是 /deb/，脚本会拼接 Release.key
K8S_APT_REPO_URL ?= https://mirrors.aliyun.com/kubernetes-new/core/stable/v$(K8S_MINOR)/deb/

# ============ 存储契约（StorageClass / 快照 / 备份目标） ============
# 统一 SC 名称 app-storage：drill 由「宿主 ZFS + iSCSI + democratic-csi」提供（云盘/计算分离），
# prod 由阿里云盘 CSI 提供；Longhorn 保留为可选后端。
# 切换后端: make storage-class STORAGE_BACKEND=<host-zfs-iscsi|longhorn|alicloud>
# 详见 docs/cloud-disk-data-solution.md
STORAGE_BACKEND   ?= host-zfs-iscsi
# 所有 PVC 引用的规范 SC 名称
STORAGE_CLASS     ?= app-storage
# VolumeSnapshotClass（CNPG/VolumeSnapshot 用）
SNAPSHOT_CLASS    ?= host-zfs-iscsi

# ---- 宿主 ZFS + iSCSI（云盘模拟，见 docs/cloud-disk-data-solution.md）----
# 宿主存储池名与后端盘；多盘可改 HOST_ZFS_VDEV（如 mirror /dev/sdb /dev/sdc）
ZFS_POOL          ?= tank
HOST_DATA_DISK    ?= /dev/sdb
# drill 默认用文件 vdev（不碰 /data 文件系统，安全幂等）；prod=0 用裸盘
HOST_ZFS_USE_FILE ?= 1
HOST_ZFS_FILE     ?= /data/zfs-pool.img
HOST_ZFS_FILE_SIZE ?= 50G
HOST_ZFS_VDEV     ?= $(HOST_DATA_DISK)
ZFS_COMPRESSION   ?= zstd
ZFS_ENCRYPTION    ?= off          # drill=off；prod=on（需 KMS/密钥）
# iSCSI target 基名（IQN 前缀）与 CHAP 用户前缀
ISCSI_IQN_PREFIX  ?= iqn.2026-01.com.baokuaiyun
ISCSI_TARGET_IQN  ?= $(ISCSI_IQN_PREFIX):k8s
# democratic-csi：chart 版本与“应用镜像” tag 是两条版本流（chart 0.15.x / 镜像 v1.9.x）
DEMOCRATIC_CSI_VERSION   ?= 0.15.1
DEMOCRATIC_CSI_IMAGE_TAG ?= v1.9.5
CSI_NAMESPACE     ?= democratic-csi
# CSI controller 经 SSH 管理宿主 target 用的密钥（dev+on-host 共用）
HOST_CSI_SSH_KEY  ?= /etc/k8s-host-csi/id_ed25519
# 宿主 MinIO（模拟 OSS）：S3 端点与端口
HOST_MINIO_PORT   ?= 9000
HOST_MINIO_CONSOLE_PORT ?= 9001
HOST_MINIO_DATA   ?= /data/minio
HOST_MINIO_ENDPOINT ?= http://$(NET_GATEWAY):$(HOST_MINIO_PORT)
# MinIO 镜像（宿主 docker 常受代理限制；可换国内镜像或预加载）
MINIO_IMAGE       ?= quay.io/minio/minio:latest
MINIO_MC_IMAGE    ?= quay.io/minio/mc:latest

# ---- Longhorn（可选后端，drill 默认不再使用）----
# 副本数：节点数 < 3 时必须 <= 可用节点数
LONGHORN_REPLICAS := 2
# drill 仅 2 节点，必须允许 Longhorn 调度到控制面才能达到 2 副本
LONGHORN_ALLOW_CONTROL_PLANE := true

# 异地备份目标（Longhorn 可选后端用；云盘方案见 BACKUP_TARGET_ZFS）：
#   drill: 宿主机 NFS 目录（如 nfs://192.168.124.1:/data/backups/longhorn）
#   prod : 阿里云 OSS（如 s3://bucket@oss-cn-hangzhou.aliyuncs.com/）
BACKUP_TARGET     ?= nfs://192.168.124.1:/data/backups/longhorn
# Longhorn 备份凭据 Secret（NFS 可留空；S3/OSS 填 longhorn-backup-cred）
LONGHORN_BACKUP_CRED_SECRET ?= longhorn-backup-cred
# S3/OSS 凭据（生产在 acr.env 覆盖；drill NFS 留空）
LONGHORN_ACCESS_KEY ?=
LONGHORN_SECRET_KEY ?=
# 云盘方案异地备份：宿主 ZFS send/recv 目标池（drill=宿主另一个池/目录）
HOST_ZFS_SEND_TARGET ?= /data/backups/zfs
# Velero 对象存储位置（drill=宿主 MinIO；prod=OSS）
VELERO_BUCKET     ?= velero-backup
VELERO_S3_URL     ?= $(HOST_MINIO_ENDPOINT)
OSS_REGION        ?= $(ALIYUN_REGION)

# 应用/DB 异地对象存储（OSS，S3 兼容）：留空 = 不做异地（drill）
PG_BACKUP_BUCKET  ?=
S3_ENDPOINT       ?=
S3_ACCESS_KEY     ?= $(ALIYUN_ACCESS_KEY)
S3_SECRET_KEY     ?= $(ALIYUN_SECRET_KEY)

# ============ 共享平台数据（CNPG + redis-operator） ============
# 全平台共享一套 PG 实例 + 一套 Redis，各应用库/角色独立
# drill 起步(1CP+1W): PG_INSTANCES=1 / PG_SYNC_REPLICAS=0 / REDIS_REPLICAS=1
# prod (>=3 存储节点): 3 / 1 / 3（且 LONGHORN_REPLICAS=3）
PLATFORM_DATA_NS  := platform-data
PG_INSTANCES      ?= 1
PG_SYNC_REPLICAS  ?= 0
REDIS_CLUSTER_SIZE ?= 1
PG_STORAGE_SIZE   ?= 20Gi
REDIS_STORAGE_SIZE ?= 5Gi
# 共享数据凭据（生产请放 acr.env 覆盖，勿提交）
PG_HARBOR_PASS    ?= changeme-harbor
PG_GITLAB_PASS    ?= changeme-gitlab
PG_CASDOOR_PASS   ?= changeme-casdoor
REDIS_PASS        ?= changeme-redis

# ============ 应用数据容量与保留（见 docs/application-data.md） ============
# Harbor
HARBOR_REGISTRY_SIZE   ?= 50Gi
HARBOR_JOBSERVICE_SIZE ?= 5Gi
HARBOR_TRIVY_SIZE      ?= 10Gi
# GitLab（Gitaly 仓库 + 对象存储）
GITALY_SIZE            ?= 50Gi
GITLAB_OBJECT_SIZE     ?= 50Gi
# GitLab 对象存储：oss（生产，指向阿里云 OSS）| minio（drill，集群内独立 MinIO）
GITLAB_OBJECT_STORE    ?= minio
GITLAB_OSS_BUCKET      ?= gitlab-object
# 可观测性持久化
PROMETHEUS_SIZE        ?= 20Gi
PROMETHEUS_RETENTION   ?= 15d
GRAFANA_SIZE           ?= 5Gi
LOKI_SIZE              ?= 20Gi
# 备份保留：本地/近端 与 异地对象存储
BACKUP_RETENTION_DAYS  ?= 7
OFFSITE_RETENTION_DAYS ?= 30

# ============ 告警通知（Alertmanager，系统参数化，提前设置） ============
# 由 observability/apply-alerts.sh 渲染 AlertmanagerConfig；密钥放 acr.env / ops.env（勿提交）
# 渠道类型: generic|slack|dingtalk|wecom（钉钉/企微需中转适配，见 docs/alert-notification.md）
# 说明：以下变量不使用行尾注释（GNU make 会把 # 前的空格并进变量值）
ALERT_NAMESPACE        ?= monitoring
ALERT_WEBHOOK_ENABLED  ?= 0
# S：通用 webhook / Slack incoming / 钉钉企微中转地址
ALERT_WEBHOOK_URL      ?=
ALERT_WEBHOOK_TYPE     ?= generic
ALERT_EMAIL_ENABLED    ?= 0
ALERT_EMAIL_TO         ?=
ALERT_EMAIL_FROM       ?= alertmanager@$(DOMAIN)
# 如 smtp.example.com:587
SMTP_SMARTHOST         ?=
# S
SMTP_AUTH_USERNAME     ?=
# S
SMTP_AUTH_PASSWORD     ?=
# warning 走哪些渠道：all（默认，同 critical）| email（只发邮件）
ALERT_WARNING_CHANNELS ?= all
# 路由：critical 立即、warning 汇总
ALERT_GROUP_WAIT       ?= 30s
ALERT_GROUP_INTERVAL   ?= 5m
ALERT_REPEAT_INTERVAL  ?= 4h
# 钉钉集群内适配器（可选 make alert-adapter）：群机器人 webhook 与加签 secret
ALERT_DINGTALK_WEBHOOK ?=
ALERT_DINGTALK_SECRET  ?=
# 适配器镜像（经 Harbor；同步见 registry/images/tier3-observability.txt）
ALERT_ADAPTER_IMAGE    ?= $(IMAGE_REPOSITORY)/prometheus-webhook-dingtalk:v2.2.0

# ============ PV 云盘自动扩容（见 docs/cloud-disk-data-solution.md §5） ============
# 控制器按用量阈值自动 patch PVC requests -> CSI resizer 在线扩容；默认 dry-run 只报告
# 1=只写 recommendation 注解并日志，不 patch；0=实际扩容
PV_AUTOSCALER_NS       ?= pvc-autoscaler
PV_AUTOSCALER_ENABLED  ?= 1
PV_AUTOSCALER_DRY_RUN  ?= 1
PV_AUTOSCALER_SCHEDULE ?= */5 * * * *
# 用量比例触发阈值
PV_AUTOSCALER_THRESHOLD ?= 0.80
# 扩容倍数
PV_AUTOSCALER_FACTOR   ?= 1.5
# 单次最小增量
PV_AUTOSCALER_MIN_STEP ?= 5Gi
# 全局容量上限（可被 PVC 注解 auto-expand/max-size 覆盖）
PV_AUTOSCALER_MAX_SIZE ?= 100Gi
# 同一 PVC 扩容冷却（分钟）
PV_AUTOSCALER_COOLDOWN_MIN ?= 60
# 空=全部；否则逗号分隔白名单
PV_AUTOSCALER_NAMESPACES ?=
# 逗号分隔排除的 namespace 或 ns/name
PV_AUTOSCALER_EXCLUDE  ?=
# Prometheus 地址（控制器查 kubelet_volume_stats_* 用）
PROM_URL               ?= http://monitoring-kube-prometheus-prometheus.$(ALERT_NAMESPACE).svc:9090
# 镜像：自带 kubectl+jq+bash（经 Harbor；同步见 registry/images/tier2-platform.txt）
PV_AUTOSCALER_IMAGE    ?= $(IMAGE_REPOSITORY)/alpine-k8s:$(K8S_VERSION)

# ============ 域名 ============
# 本机演练: test.baokuaiyun.com | 阿里云生产: baokuaiyun.com
DOMAIN      := test.baokuaiyun.com
WILDCARD    := *.test.baokuaiyun.com
HARBOR_HOST := harbor.test.baokuaiyun.com
GITLAB_HOST := gitlab.test.baokuaiyun.com
GRAFANA_HOST := grafana.test.baokuaiyun.com
CASDOOR_HOST := casdoor.test.baokuaiyun.com
ARGOCD_HOST  := argocd.test.baokuaiyun.com

# ============ IdP: Casdoor（集群内，统一用户管理） ============
# CASDOOR_VERSION 生产请固定版本（勿用 latest）
CASDOOR_VERSION ?= latest
CASDOOR_DB_USER := casdoor
# 复用共享 PG 的 casdoor 角色密码
CASDOOR_DB_PASS := $(PG_CASDOOR_PASS)
CASDOOR_DB_NAME := casdoor

# ============ 控制面入口（内网 VIP / DNS） ============
# VIP 需避开 DHCP(.100-.200) 与静态段(.10-.21)
CP_VIP         := 192.168.124.30
CP_ENDPOINT    := k8s-api.$(DOMAIN)
CP_ENDPOINT_PORT := 6443
# kubeconfig 里本集群的 context/cluster 名（避免覆盖用户已有 kubeconfig）
# 生产可覆盖: make ... K8S_CONTEXT=kvm-baokuaiyun
K8S_CONTEXT    ?= kvm-$(firstword $(subst ., ,$(DOMAIN)))
# kube-vip 绑定的网卡名（虚机内执行 `ip -br link` 确认；留空则脚本自动探测）
VIP_IFACE      := enp1s0

# ============ 国内镜像加速 ============
# 宿主代理常导致国外站点 TLS 失败；默认直连（no_proxy=*）
BYPASS_PROXY  ?= 1
# 上游 -> 国内镜像重写
MIRROR_K8S    ?= registry.cn-hangzhou.aliyuncs.com/google_containers
MIRROR_GHCR   ?= ghcr.nju.edu.cn
MIRROR_DOCKER ?= docker.1ms.run
MIRROR_QUAY   ?= quay.m.daocloud.io

# ============ 镜像（ACR 源 + 本域目标） ============
# 源 ACR（可被 acr.env / 环境变量覆盖）
ACR_REGISTRY  ?= crpi-adznwq8xa40ei174.cn-hangzhou.personal.cr.aliyuncs.com
ACR_NAMESPACE ?= baokuaiyun
# password | ak | none
ACR_AUTH_MODE ?= password
ACR_USER      ?= <ACR_USER>
ACR_PASS      ?= <ACR_PASS>
# auto | acr | upstream
ACR_SOURCE    ?= auto

# 本域目标仓库前缀（镜像名 = $(IMAGE_REPOSITORY)/<name>:<tag>）
IMAGE_REPOSITORY ?= $(HARBOR_HOST)/$(HARBOR_PROJECT)
# 宿主机镜像缓存目录（prepare 导出的 tar）
IMAGE_CACHE_DIR  ?= /data/kvm/images/registry

# ============ 云效（Yunxiao） ============
# 个人访问令牌 + 组织 ID（放 acr.env）
YUNXIAO_ORG_ID ?= 
YUNXIAO_TOKEN  ?= 

# ============ Helm Chart 仓库 ============
# 注意：云效制品仓库不支持 Helm；引导期用 云效 Codeup Git 托管 chart
HELM_REPO_NAME  ?= baokuaiyun
HELM_REPO_URL   ?=
HELM_REPO_USER  ?= <YUNXIAO_USER>
HELM_REPO_PASS  ?= <YUNXIAO_PASS>
HELM_CHARTS_DIR ?= /data/kvm/charts

# 引导期 chart 源：云效 Codeup Git（clone 到本地目录）
HELM_GIT_URL    ?= https://codeup.aliyun.com/68b10df1e3894fcaacb7b8db/baokuaiyun/helm-charts.git
HELM_GIT_USER   ?= <YUNXIAO_USER>
HELM_GIT_TOKEN  ?= <YUNXIAO_TOKEN>
HELM_GIT_REF    ?= main
HELM_GIT_DIR    ?= /data/kvm/helm-charts

# chart 来源：优先本地 vendored tgz，否则上游仓库
HELM_CILIUM   = $(if $(wildcard $(HELM_CHARTS_DIR)/cilium-*.tgz),$(firstword $(wildcard $(HELM_CHARTS_DIR)/cilium-*.tgz)),cilium/cilium)
HELM_LONGHORN = $(if $(wildcard $(HELM_CHARTS_DIR)/longhorn-*.tgz),$(firstword $(wildcard $(HELM_CHARTS_DIR)/longhorn-*.tgz)),longhorn/longhorn)
HELM_CERTMGR  = $(if $(wildcard $(HELM_CHARTS_DIR)/cert-manager-*.tgz),$(firstword $(wildcard $(HELM_CHARTS_DIR)/cert-manager-*.tgz)),jetstack/cert-manager)
HELM_REDIS_OP = $(if $(wildcard $(HELM_CHARTS_DIR)/redis-operator-*.tgz),$(firstword $(wildcard $(HELM_CHARTS_DIR)/redis-operator-*.tgz)),ot-helm/redis-operator)
HELM_CNPG     = $(if $(wildcard $(HELM_CHARTS_DIR)/cloudnative-pg-*.tgz),$(firstword $(wildcard $(HELM_CHARTS_DIR)/cloudnative-pg-*.tgz)),cnpg/cloudnative-pg)
HELM_HARBOR   = $(if $(wildcard $(HELM_CHARTS_DIR)/harbor-*.tgz),$(firstword $(wildcard $(HELM_CHARTS_DIR)/harbor-*.tgz)),harbor/harbor)
HELM_GITLAB   = $(if $(wildcard $(HELM_CHARTS_DIR)/gitlab-*.tgz),$(firstword $(wildcard $(HELM_CHARTS_DIR)/gitlab-*.tgz)),gitlab/gitlab)
HELM_DEMOCRATIC_CSI = $(if $(wildcard $(HELM_CHARTS_DIR)/democratic-csi-*.tgz),$(firstword $(wildcard $(HELM_CHARTS_DIR)/democratic-csi-*.tgz)),democratic-csi/democratic-csi)

# ============ Flux Operator（Helm，chart+镜像走 Harbor）============
FLUX_OPERATOR_VERSION ?= 0.61.0
GHCR_MIRROR           ?= ghcr.dockerproxy.net
FLEET_MODE            ?= all-in-one
FLUX_NS               ?= flux-system
# 引导/GitOps 平面控制
TOOLCHAIN_MODE        ?= selfhost      # selfhost | consume
ENABLE_FLUX           ?= true
DATA_SOURCE           ?= local         # local | shared（按应用可覆盖）
GIT_MODE              ?= later
# 集群类型：A=管理/开发者平台  B=生产/业务  all=合一(drill)
CLUSTER_TYPE          ?= all

# ============ Harbor ============
# 单项目私有；凭据在 acr.env（可覆盖）
HARBOR_PROJECT     ?= baokuaiyun
HARBOR_USER        ?= admin
HARBOR_PASS        ?= admin123
HARBOR_ADMIN_PASS  ?= $(HARBOR_PASS)
HARBOR_ROBOT_USER  ?= robot$$$(HARBOR_PROJECT)+pushpull
HARBOR_ROBOT_PASS  ?= changeme-robot
# Harbor 作为 OCI Helm chart 源
HELM_OCI_REPO      ?= oci://$(HARBOR_HOST)/$(HARBOR_PROJECT)

# ============ Kubernetes 网络 ============
POD_CIDR     := 10.244.0.0/16
SERVICE_CIDR := 10.96.0.0/12

# ============ 节点 IP 模式与 LB IP（服务负载均衡地址） ============
# 分层：G 默认（此处）<- P 覆盖（gitops/profiles/<env>.env）<- S 密钥（acr.env）
# 三环境差异只改这几个开关，应用侧契约（Service type=LoadBalancer / Gateway listener）不变。
# 详见 docs/parameters.md「节点 / LB IP」与 docs/environment-differences.md。
# 节点 IP 来源: static(KVM 静态 DHCP) | dhcp | cloud(ECS/VPC 分配；prod)
NODE_IP_MODE   ?= static
# LB 实现机制: cilium-l2(Cilium LB IPAM+L2, drill/bare) | kubevip | metallb | slb(阿里云 CCM) | none
LB_IP_MODE     ?= cilium-l2
# Cilium LB IPAM 地址池（仅 cilium-l2/metallb；须避开网关/节点静态段/CP_VIP/DHCP）
LB_POOL_START  ?= 192.168.124.40
LB_POOL_END    ?= 192.168.124.79
# 入口主 IP（Gateway/Ingress）：drill 固定；prod 由 SLB 回写，故留空
GATEWAY_VIP    ?= 192.168.124.31
# 地址宣告方式: l2(ARP) | bgp | cloud(云 LB 代管)
LB_ANNOUNCE    ?= l2
# loadBalancerClass（多后端共存/切换；空=默认实现）
LB_CLASS       ?=

# ============ 业务网（双网卡 / D 方案：平台入口固定 IP + 业务按需 IP 池） ============
# 两个功能：
#   ① 平台入口 L7 共享固定 IP（Harbor/GitLab/... 共用一个，DNS 指向它）
#   ② 其它业务请求 IP 管理（LB 池，Service type=LoadBalancer 按需自动分配）
# 基础设施：业务网需对客户端可达 —— KVM=桥接 eno1 的 br-lan；云=业务 vSwitch/ENI；裸机=VLAN/桥接
# 开关 NET_BIZ_ENABLED: 0=沿用管理网地址（当前单网段，兼容现状）；1=切到业务网（需先建好 br-lan）
NET_BIZ_ENABLED   ?= 0
NET_BIZ_NAME      ?= br-lan
NET_BIZ_CIDR      ?= 192.168.1.0/24
NET_BIZ_GATEWAY   ?= 192.168.1.1
# 节点双网卡（VM 内网卡名）：管理网 / 业务网
MGMT_IFACE        ?= enp1s0
BIZ_IFACE         ?= enp2s0
# 宿主机侧业务网桥（KVM）
BIZ_HOST_IFACE    ?= br-lan
# 节点业务网副 IP（静态；Cilium L2 宣告用）
LAN_NODE_IPS      ?= 192.168.1.230 192.168.1.231 192.168.1.232 192.168.1.233 192.168.1.234
# 业务网上的“平台入口固定 IP”与“业务池”
BIZ_GATEWAY_VIP   ?= 192.168.1.235
BIZ_LB_POOL_START ?= 192.168.1.240
BIZ_LB_POOL_END   ?= 192.168.1.249
# -- 生效值（供渲染消费，避免各处重复判断）--
EFF_GATEWAY_VIP   ?= $(if $(filter 1,$(NET_BIZ_ENABLED)),$(BIZ_GATEWAY_VIP),$(GATEWAY_VIP))
EFF_LB_POOL_START ?= $(if $(filter 1,$(NET_BIZ_ENABLED)),$(BIZ_LB_POOL_START),$(LB_POOL_START))
EFF_LB_POOL_END   ?= $(if $(filter 1,$(NET_BIZ_ENABLED)),$(BIZ_LB_POOL_END),$(LB_POOL_END))
EFF_BIZ_IFACE     ?= $(if $(filter 1,$(NET_BIZ_ENABLED)),$(BIZ_IFACE),$(VIP_IFACE))

# ============ Git (GitOps) ============
GIT_OWNER := baokuaiyun
GIT_REPO  := k8s-gitops

# ============ 阿里云（生产用） ============
ALIYUN_REGION := cn-hangzhou
ALIYUN_ACCESS_KEY := <ALIBABA_ACCESS_KEY>
ALIYUN_SECRET_KEY := <ALIBABA_SECRET_KEY>

# ============ 导出给脚本（install/join/kube-vip 等 bash 用） ============
export NET_NAME NET_GATEWAY
export CP_NAMES CP_IPS CP_MACS CP_INIT_COUNT
export WK_NAMES WK_IPS WK_MACS WK_INIT_COUNT
export CP_VIP CP_ENDPOINT CP_ENDPOINT_PORT VIP_IFACE K8S_CONTEXT
export POD_CIDR SERVICE_CIDR
export NODE_IP_MODE LB_IP_MODE LB_POOL_START LB_POOL_END GATEWAY_VIP LB_ANNOUNCE LB_CLASS
export NET_BIZ_ENABLED NET_BIZ_NAME NET_BIZ_CIDR NET_BIZ_GATEWAY MGMT_IFACE BIZ_IFACE BIZ_HOST_IFACE LAN_NODE_IPS
export BIZ_GATEWAY_VIP BIZ_LB_POOL_START BIZ_LB_POOL_END
export EFF_GATEWAY_VIP EFF_LB_POOL_START EFF_LB_POOL_END EFF_BIZ_IFACE
export K8S_VERSION K8S_MINOR K8S_APT_REPO_URL KUBE_VIP_VERSION
export DOMAIN HARBOR_HOST HARBOR_PROJECT LONGHORN_REPLICAS
export HARBOR_USER HARBOR_PASS HARBOR_ADMIN_PASS HARBOR_ROBOT_USER HARBOR_ROBOT_PASS HELM_OCI_REPO
export STORAGE_BACKEND STORAGE_CLASS SNAPSHOT_CLASS LONGHORN_ALLOW_CONTROL_PLANE
export ZFS_POOL HOST_DATA_DISK HOST_ZFS_VDEV ZFS_COMPRESSION ZFS_ENCRYPTION
export HOST_ZFS_USE_FILE HOST_ZFS_FILE HOST_ZFS_FILE_SIZE
export ISCSI_IQN_PREFIX ISCSI_TARGET_IQN DEMOCRATIC_CSI_VERSION DEMOCRATIC_CSI_IMAGE_TAG CSI_NAMESPACE HOST_CSI_SSH_KEY HOST_ZFS_SEND_TARGET
export HOST_MINIO_PORT HOST_MINIO_CONSOLE_PORT HOST_MINIO_DATA HOST_MINIO_ENDPOINT MINIO_IMAGE MINIO_MC_IMAGE
export BACKUP_TARGET LONGHORN_BACKUP_CRED_SECRET LONGHORN_ACCESS_KEY LONGHORN_SECRET_KEY
export VELERO_BUCKET VELERO_S3_URL OSS_REGION
export PG_BACKUP_BUCKET S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY
export CNPG_VERSION REDIS_OP_VERSION PLATFORM_DATA_NS
export PG_INSTANCES PG_SYNC_REPLICAS REDIS_CLUSTER_SIZE PG_STORAGE_SIZE REDIS_STORAGE_SIZE
export PG_HARBOR_PASS PG_GITLAB_PASS PG_CASDOOR_PASS REDIS_PASS
export HARBOR_REGISTRY_SIZE HARBOR_JOBSERVICE_SIZE HARBOR_TRIVY_SIZE
export GITALY_SIZE GITLAB_OBJECT_SIZE GITLAB_OBJECT_STORE GITLAB_OSS_BUCKET
export PROMETHEUS_SIZE PROMETHEUS_RETENTION GRAFANA_SIZE LOKI_SIZE
export BACKUP_RETENTION_DAYS OFFSITE_RETENTION_DAYS
export ALERT_NAMESPACE ALERT_WEBHOOK_ENABLED ALERT_WEBHOOK_URL ALERT_WEBHOOK_TYPE ALERT_WARNING_CHANNELS
export ALERT_EMAIL_ENABLED ALERT_EMAIL_TO ALERT_EMAIL_FROM SMTP_SMARTHOST SMTP_AUTH_USERNAME SMTP_AUTH_PASSWORD
export ALERT_GROUP_WAIT ALERT_GROUP_INTERVAL ALERT_REPEAT_INTERVAL
export ALERT_ENV_FILE ALERT_DINGTALK_WEBHOOK ALERT_DINGTALK_SECRET ALERT_ADAPTER_IMAGE
export PV_AUTOSCALER_NS PV_AUTOSCALER_ENABLED PV_AUTOSCALER_DRY_RUN PV_AUTOSCALER_SCHEDULE
export PV_AUTOSCALER_THRESHOLD PV_AUTOSCALER_FACTOR PV_AUTOSCALER_MIN_STEP PV_AUTOSCALER_MAX_SIZE
export PV_AUTOSCALER_COOLDOWN_MIN PV_AUTOSCALER_NAMESPACES PV_AUTOSCALER_EXCLUDE PV_AUTOSCALER_IMAGE PROM_URL
export ACR_REGISTRY ACR_NAMESPACE ACR_AUTH_MODE ACR_USER ACR_PASS ACR_SOURCE
export BYPASS_PROXY MIRROR_K8S MIRROR_GHCR MIRROR_DOCKER MIRROR_QUAY
export IMAGE_REPOSITORY IMAGE_CACHE_DIR
export ALIYUN_ACCESS_KEY ALIYUN_SECRET_KEY
export HELM_REPO_NAME HELM_REPO_URL HELM_REPO_USER HELM_REPO_PASS HELM_CHARTS_DIR
export HELM_GIT_URL HELM_GIT_USER HELM_GIT_TOKEN HELM_GIT_REF HELM_GIT_DIR
export FLUX_OPERATOR_VERSION GHCR_MIRROR FLEET_MODE FLUX_NS
export TOOLCHAIN_MODE ENABLE_FLUX DATA_SOURCE GIT_MODE CLUSTER_TYPE
export YUNXIAO_ORG_ID YUNXIAO_TOKEN
export CASDOOR_HOST CASDOOR_VERSION CASDOOR_DB_USER CASDOOR_DB_PASS CASDOOR_DB_NAME ARGOCD_HOST
