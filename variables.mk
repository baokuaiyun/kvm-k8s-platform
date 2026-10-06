# =============================================================================
# 全局变量配置 — 修改此文件即可适配不同环境
# 本机演练: DOMAIN=test.baokuaiyun.com
# 阿里云生产: DOMAIN=baokuaiyun.com
# =============================================================================

# 本机凭据（不提交）: cp acr.env.example acr.env 并填真实值
-include $(dir $(lastword $(MAKEFILE_LIST)))acr.env

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

# ============ 起步规模（1CP+1W，后续 make scale-out 扩展） ============
CP_INIT_COUNT := 1
WK_INIT_COUNT := 1

# ============ VM 规格 ============
CP_VCPU := 2
CP_RAM  := 4096
CP_DISK := 30G
WK_VCPU := 4
WK_RAM  := 4096
WK_DISK := 50G

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
KUBE_VIP_VERSION := 0.8.7
CNPG_VERSION    := 1.25.1
REDIS_OP_VERSION := 0.17.0

# Kubernetes apt 源（国内默认阿里云镜像；官方 = https://pkgs.k8s.io/core:/stable:/v$(K8S_MINOR)/deb/）
# 末尾必须是 /deb/，脚本会拼接 Release.key
K8S_APT_REPO_URL ?= https://mirrors.aliyun.com/kubernetes-new/core/stable/v$(K8S_MINOR)/deb/

# ============ 存储契约（StorageClass / 快照 / 备份目标） ============
# 统一 SC 名称 app-storage：drill 由 Longhorn 提供，prod 由阿里云盘 CSI 提供。
# 切换后端: make storage-class STORAGE_BACKEND=alicloud
# 后端: longhorn | alicloud
STORAGE_BACKEND   ?= longhorn
# 所有 PVC 引用的规范 SC 名称
STORAGE_CLASS     ?= app-storage
# VolumeSnapshotClass（CNPG/VolumeSnapshot 用；alicloud 环境为 alicloud-disk）
SNAPSHOT_CLASS    ?= longhorn

# Longhorn 副本数：节点数 < 3 时必须 <= 可用节点数
# drill(1CP+1W) 起步 2 副本；prod(>=3 存储节点) 用 3（见 docs/storage-plan.md）
LONGHORN_REPLICAS := 2
# drill 仅 2 节点，必须允许 Longhorn 调度到控制面才能达到 2 副本
LONGHORN_ALLOW_CONTROL_PLANE := true

# 异地备份目标：
#   drill: 宿主机 NFS 目录（如 nfs://192.168.124.1:/data/backups/longhorn）
#   prod : 阿里云 OSS（如 s3://bucket@oss-cn-hangzhou.aliyuncs.com/）
BACKUP_TARGET     ?= nfs://192.168.124.1:/data/backups/longhorn
# Longhorn 备份凭据 Secret（NFS 可留空；S3/OSS 填 longhorn-backup-cred）
LONGHORN_BACKUP_CRED_SECRET ?= longhorn-backup-cred
# S3/OSS 凭据（生产在 acr.env 覆盖；drill NFS 留空）
LONGHORN_ACCESS_KEY ?=
LONGHORN_SECRET_KEY ?=
# Velero 对象存储位置（OSS，先用占位；生产在 acr.env 覆盖）
VELERO_BUCKET     ?= velero-backup
VELERO_S3_URL     ?= oss-cn-hangzhou.aliyuncs.com
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
export K8S_VERSION K8S_MINOR K8S_APT_REPO_URL KUBE_VIP_VERSION
export DOMAIN HARBOR_HOST HARBOR_PROJECT LONGHORN_REPLICAS
export HARBOR_USER HARBOR_PASS HARBOR_ADMIN_PASS HARBOR_ROBOT_USER HARBOR_ROBOT_PASS HELM_OCI_REPO
export STORAGE_BACKEND STORAGE_CLASS SNAPSHOT_CLASS LONGHORN_ALLOW_CONTROL_PLANE
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
