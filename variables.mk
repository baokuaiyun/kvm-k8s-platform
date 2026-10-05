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

# Kubernetes apt 源（国内默认阿里云镜像；官方 = https://pkgs.k8s.io/core:/stable:/v$(K8S_MINOR)/deb/）
# 末尾必须是 /deb/，脚本会拼接 Release.key
K8S_APT_REPO_URL ?= https://mirrors.aliyun.com/kubernetes-new/core/stable/v$(K8S_MINOR)/deb/

# Longhorn 副本数：节点数 < 3 时必须 <= 可用节点数
LONGHORN_REPLICAS := 1

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
CASDOOR_VERSION ?= latest          # 生产请固定版本
CASDOOR_DB_USER := casdoor
CASDOOR_DB_PASS := <强密码>
CASDOOR_DB_NAME := casdoor

# ============ 控制面入口（内网 VIP / DNS） ============
# VIP 需避开 DHCP(.100-.200) 与静态段(.10-.21)
CP_VIP         := 192.168.124.30
CP_ENDPOINT    := k8s-api.$(DOMAIN)
CP_ENDPOINT_PORT := 6443
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
ACR_AUTH_MODE ?= password          # password | ak | none
ACR_USER      ?= <ACR_USER>
ACR_PASS      ?= <ACR_PASS>
ACR_SOURCE    ?= auto              # auto | acr | upstream

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
HELM_REPO_URL   ?=                 # 旧：云效制品仓库 Helm（不支持，留空）
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

# ============ Harbor ============
HARBOR_USER    := admin
HARBOR_PASS    := admin123
HARBOR_PROJECT := k8s-library

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
export CP_VIP CP_ENDPOINT CP_ENDPOINT_PORT VIP_IFACE
export POD_CIDR SERVICE_CIDR
export K8S_VERSION K8S_MINOR K8S_APT_REPO_URL KUBE_VIP_VERSION
export DOMAIN HARBOR_HOST HARBOR_PROJECT LONGHORN_REPLICAS
export ACR_REGISTRY ACR_NAMESPACE ACR_AUTH_MODE ACR_USER ACR_PASS ACR_SOURCE
export BYPASS_PROXY MIRROR_K8S MIRROR_GHCR MIRROR_DOCKER MIRROR_QUAY
export IMAGE_REPOSITORY IMAGE_CACHE_DIR
export ALIYUN_ACCESS_KEY ALIYUN_SECRET_KEY
export HELM_REPO_NAME HELM_REPO_URL HELM_REPO_USER HELM_REPO_PASS HELM_CHARTS_DIR
export HELM_GIT_URL HELM_GIT_USER HELM_GIT_TOKEN HELM_GIT_REF HELM_GIT_DIR
export YUNXIAO_ORG_ID YUNXIAO_TOKEN
export CASDOOR_HOST CASDOOR_VERSION CASDOOR_DB_USER CASDOOR_DB_PASS CASDOOR_DB_NAME ARGOCD_HOST
