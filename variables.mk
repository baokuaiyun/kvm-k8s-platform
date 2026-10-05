# =============================================================================
# 全局变量配置 — 修改此文件即可适配不同环境
# 本机演练: DOMAIN=test.baokuaiyun.com
# 阿里云生产: DOMAIN=baokuaiyun.com
# =============================================================================

# ============ 网络 ============
NET_NAME   := br-prod
NET_CIDR   := 192.168.124.0/24
NET_GATEWAY := 192.168.124.1

# ============ 节点定义 ============
CP_NAMES := k8s-cp-1 k8s-cp-2 k8s-cp-3
CP_IPS   := 192.168.124.10 192.168.124.11 192.168.124.12
CP_MACS  := 52:54:00:01:01:01 52:54:00:01:01:02 52:54:00:01:01:03

WK_NAMES := k8s-worker-1 k8s-worker-2
WK_IPS   := 192.168.124.20 192.168.124.21
WK_MACS  := 52:54:00:01:02:01 52:54:00:01:02:02

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
CILIUM_VERSION  := 1.16.0
LONGHORN_VERSION := 1.7.0

# ============ 域名 ============
# 本机演练: test.baokuaiyun.com | 阿里云生产: baokuaiyun.com
DOMAIN      := test.baokuaiyun.com
WILDCARD    := *.test.baokuaiyun.com
HARBOR_HOST := harbor.test.baokuaiyun.com
GITLAB_HOST := gitlab.test.baokuaiyun.com
GRAFANA_HOST := grafana.test.baokuaiyun.com

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
