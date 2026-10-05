# Makefile 设计：一键重建集群

> 目标：所有操作 Makefile 化，任何环境可重复重建。
> 目录：`/root/k8s/`

## 一、目录与 Makefile 布局

```
/root/k8s/
├── Makefile                    # 顶层入口（阶段编排）
├── variables.mk                # 全局变量（IP/规格/域名/版本）
├── kvm/
│   ├── Makefile                # KVM 虚拟机管理
│   ├── cloud-init/             # cloud-init 模板
│   └── scripts/                # create-vm.sh 等
├── kubernetes/
│   ├── Makefile                # kubeadm 集群安装
│   └── configs/                # containerd/kubeadm 配置
├── infrastructure/
│   ├── Makefile                # Cilium/Longhorn/cert-manager
│   ├── tenants/                # 租户模板（Mode A）
│   └── crossplane/             # XRD/Composition（Mode B）
├── platform/
│   └── Makefile                # Harbor/GitLab/Backstage
├── registry/
│   ├── Makefile                # 镜像下载/推 Harbor
│   └── images-list.txt         # 镜像清单
├── observability/
│   └── Makefile                # 监控/日志/告警
└── scripts/
    ├── backup-etcd.sh
    └── restore-etcd.sh
```

## 二、顶层 Makefile

```makefile
include variables.mk

.PHONY: help init phase1 phase2 phase3 phase4 verify clean

help:  ## 显示帮助
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "};{printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

## ========== 阶段编排 ==========
init: kvm-init network-create image-download        ## 初始化 KVM 环境
phase1: init vm-create k8s-install cni storage cert ## 阶段1: 基础集群
phase2: security monitoring agents                  ## 阶段2: 安全监控
phase3: platform gitops tenants operators images    ## 阶段3: 应用+GitOps
phase4: backup upgrade                              ## 阶段4: 升级维护
verify: verify-cluster verify-monitoring verify-apps ## 全量验收

## ========== 阶段 1 ==========
kvm-init:  ## 安装 KVM 工具链
	apt install -y qemu-kvm libvirt-daemon-system libvirt-clients \
	  virtinst bridge-utils cloud-image-utils cpu-checker
	systemctl enable --now libvirtd

network-create:  ## 创建 NAT 网络
	virsh net-define kvm/br-prod.xml
	virsh net-start br-prod && virsh net-autostart br-prod

image-download:  ## 下载 Debian 13 镜像
	wget -O /data/kvm/images/debian-13.qcow2 $(BASE_IMAGE_URL)

vm-create:  ## 创建起步节点 (1CP+1W)
	# 按 CP_INIT_COUNT/WK_INIT_COUNT 创建
	# 扩容: make vm-add-cp IDX=2 / make vm-add-worker IDX=2

k8s-install:  ## kubeadm 安装集群 (1CP+1W, endpoint=VIP)
	bash kubernetes/scripts/install-common.sh   # kubelet/kubeadm/containerd
	bash kubernetes/scripts/setup-kube-vip.sh   # VIP 静态 Pod（init 前）
	bash kubernetes/scripts/init-control-plane.sh  # endpoint=k8s-api.test.baokuaiyun.com:6443
	bash kubernetes/scripts/join-worker.sh all  # 加入起步 worker

scale-out:  ## 扩容到 3CP+2W
	# vm-add-cp IDX=2/3 + vm-add-worker IDX=2 + join

cni:  ## 安装 Cilium
	helm upgrade --install cilium cilium/cilium -n kube-system -f kubernetes/configs/cilium-values.yaml

storage:  ## 安装 Longhorn
	helm upgrade --install longhorn longhorn/longhorn -n longhorn-system --create-namespace

cert:  ## 安装 cert-manager
	helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set installCRDs=true

## ========== 阶段 2 ==========
security:  ## 安全基线（RBAC/NetworkPolicy/Quota）
	kubectl apply -k infrastructure/security/

monitoring:  ## 监控栈
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack -n monitoring --create-namespace

agents:  ## 可观测性 agent
	helm upgrade --install otel open-telemetry/opentelemetry-collector -n monitoring
	helm upgrade --install blackbox prometheus-community/prometheus-blackbox-exporter -n monitoring

## ========== 阶段 3 ==========
platform:  ## Harbor + GitLab
	helm upgrade --install harbor harbor/harbor -n harbor --create-namespace
	helm upgrade --install gitlab gitlab/gitlab -n gitlab --create-namespace --timeout 600s

gitops:  ## Flux CD
	flux bootstrap github --owner=$(GIT_OWNER) --repository=$(GIT_REPO) --path=./clusters/kvm

tenants:  ## 三模式租户
	kubectl apply -k infrastructure/tenants/
	kubectl apply -k infrastructure/crossplane/
	vcluster create vc-tenant1 -n vc-tenant1

operators:  ## 共享 Operator
	helm upgrade --install redis-operator ot-helm/redis-operator -n redis-operator --create-namespace
	helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace

images:  ## 镜像推送到 Harbor
	bash registry/download-images.sh

## ========== 阶段 4 ==========
backup:  ## etcd + Velero 备份
	bash scripts/backup-etcd.sh
	velero backup create daily-$$(date +%Y%m%d)

upgrade:  ## 集群升级（按 SOP）
	bash kubernetes/scripts/upgrade.sh $(K8S_NEW_VERSION)

## ========== 清理 ==========
clean:  ## 销毁全部 VM 和资源
	bash kvm/scripts/destroy-all.sh
```

## 三、variables.mk（环境差异集中管理）

```makefile
# ============ 网络 ============
NET_NAME := br-prod
NET_CIDR := 192.168.124.0/24

# ============ 节点 ============
CP1_IP := 192.168.124.10
CP2_IP := 192.168.124.11
CP3_IP := 192.168.124.12
WK1_IP := 192.168.124.20
WK2_IP := 192.168.124.21

CP1_MAC := 52:54:00:01:01:01
CP2_MAC := 52:54:00:01:01:02
CP3_MAC := 52:54:00:01:01:03
WK1_MAC := 52:54:00:01:02:01
WK2_MAC := 52:54:00:01:02:02

# ============ 版本 ============
K8S_VERSION := 1.31.0
K8S_NEW_VERSION := 1.32.0   # 升级目标
CILIUM_VERSION := 1.16.0
LONGHORN_VERSION := 1.7.0

# ============ 域名 ============
# 本机演练: test.baokuaiyun.com
# 阿里云生产: baokuaiyun.com
DOMAIN := test.baokuaiyun.com
WILDCARD := *.test.baokuaiyun.com
HARBOR_HOST := harbor.test.baokuaiyun.com
GITLAB_HOST := gitlab.test.baokuaiyun.com

# ============ Harbor ============
HARBOR_USER := admin
HARBOR_PASS := <强密码>
HARBOR_PROJECT := k8s-library

# ============ 镜像源 ============
BASE_IMAGE_URL := https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2

# ============ Git ============
GIT_OWNER := baokuaiyun
GIT_REPO := k8s-gitops
```

## 四、环境切换（本机 ↔ 阿里云）

```bash
# 演练环境
make -f Makefile phase1 DOMAIN=test.baokuaiyun.com

# 阿里云生产（改 variables.mk 的 DOMAIN 为 baokuaiyun.com）
# 或用环境变量覆盖:
make phase1 DOMAIN=baokuaiyun.com STORAGE_CLASS=alicloud-disk
```

## 五、常用操作速查

```bash
make help                  # 查看所有目标
make init                  # 初始化 KVM
make phase1                # 一键跑完阶段 1
make vm-create             # 只建 VM
make k8s-install           # 只装集群
make verify                # 全量验收
make clean                 # 全部销毁重建
```

## 六、设计原则

| 原则 | 说明 |
|------|------|
| **幂等** | 所有 `helm upgrade --install` 可重复执行 |
| **变量集中** | IP/域名/版本全在 variables.mk，改一处生效 |
| **环境隔离** | 域名/存储差异通过变量或 Kustomize overlay 切换 |
| **阶段编排** | phase1-4 顶层目标，内部组合子目标 |
| **可重建** | `make clean && make phase1` 可从头重建 |
