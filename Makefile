# =============================================================================
# 顶层 Makefile — KVM 生产集群一键构建/重建
# 用法: make help
# =============================================================================
SHELL := /bin/bash
include variables.mk

.PHONY: help init phase1 phase2 phase3 phase4 verify clean docs docs-build docs-down

DOCS_PORT ?= 8000
DOCS_IMAGE ?= squidfunk/mkdocs-material:latest

help: ## 显示所有可用目标
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "};{printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'

## ============ 阶段编排 ============
init: kvm-init network-create dirs image-download ## 初始化 KVM 环境
phase1: init vm-create k8s-install cni storage cert ## 阶段1: 基础集群创建
phase2: security monitoring agents              ## 阶段2: 安全及运营监控
phase3: platform gitops tenants operators images ## 阶段3: 应用部署+GitOps
phase4: backup-upgrade                          ## 阶段4: 持续升级维护
verify: verify-cluster verify-monitoring verify-apps ## 全量验收

## ============ 阶段 1: 基础集群 ============
kvm-init: ## 安装 KVM 工具链
	@echo "[+] 安装 KVM 工具链..."
	apt-get update -qq
	apt-get install -y -qq qemu-kvm libvirt-daemon-system libvirt-clients \
		virtinst bridge-utils cloud-image-utils cpu-checker libguestfs-tools
	systemctl enable --now libvirtd
	kvm-ok

dirs: ## 创建存储目录
	mkdir -p $(IMAGE_DIR) $(DISK_DIR) $(SEED_DIR) $(BACKUP_DIR)

network-create: ## 创建 libvirt NAT 网络
	@echo "[+] 创建 NAT 网络 $(NET_NAME)..."
	virsh net-define kvm/br-prod.xml
	virsh net-start $(NET_NAME) || true
	virsh net-autostart $(NET_NAME)

image-download: ## 下载 Debian 13 云镜像
	@echo "[+] 下载 Debian 13 云镜像..."
	[ -f "$(IMAGE_DIR)/$(BASE_IMAGE)" ] || \
		wget -q "$(BASE_IMAGE_URL)" -O "$(IMAGE_DIR)/$(BASE_IMAGE)"
	qemu-img info "$(IMAGE_DIR)/$(BASE_IMAGE)"

vm-create: ## 创建 5 台 VM
	@echo "[+] 创建控制面节点..."
	bash kvm/scripts/create-vm.sh k8s-cp-1 $(word 1,$(CP_IPS)) $(word 1,$(CP_MACS)) $(CP_VCPU) $(CP_RAM) $(CP_DISK)
	bash kvm/scripts/create-vm.sh k8s-cp-2 $(word 2,$(CP_IPS)) $(word 2,$(CP_MACS)) $(CP_VCPU) $(CP_RAM) $(CP_DISK)
	bash kvm/scripts/create-vm.sh k8s-cp-3 $(word 3,$(CP_IPS)) $(word 3,$(CP_MACS)) $(CP_VCPU) $(CP_RAM) $(CP_DISK)
	@echo "[+] 创建 Worker 节点..."
	bash kvm/scripts/create-vm.sh k8s-worker-1 $(word 1,$(WK_IPS)) $(word 1,$(WK_MACS)) $(WK_VCPU) $(WK_RAM) $(WK_DISK)
	bash kvm/scripts/create-vm.sh k8s-worker-2 $(word 2,$(WK_IPS)) $(word 2,$(WK_MACS)) $(WK_VCPU) $(WK_RAM) $(WK_DISK)
	virsh list --all

k8s-install: ## kubeadm 安装集群
	@echo "[+] 在所有节点安装 kubelet/kubeadm..."
	bash kubernetes/scripts/install-common.sh
	@echo "[+] 初始化控制面..."
	bash kubernetes/scripts/init-control-plane.sh

cni: ## 安装 Cilium CNI
	@echo "[+] 安装 Cilium..."
	helm repo add cilium https://helm.cilium.io 2>/dev/null || true
	helm repo update
	helm upgrade --install cilium cilium/cilium -n kube-system \
		-f kubernetes/configs/cilium-values.yaml

storage: ## 安装 Longhorn 存储
	@echo "[+] 安装 Longhorn..."
	helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
	helm repo update
	helm upgrade --install longhorn longhorn/longhorn \
		-n longhorn-system --create-namespace

cert: ## 安装 cert-manager
	@echo "[+] 安装 cert-manager..."
	helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
	helm repo update
	helm upgrade --install cert-manager jetstack/cert-manager \
		-n cert-manager --create-namespace --set installCRDs=true

## ============ 阶段 2: 安全监控 ============
security: ## 安全基线（RBAC/NetworkPolicy/Quota）
	@echo "[+] 应用安全基线..."
	kubectl apply -k infrastructure/security/ 2>/dev/null || true

monitoring: ## 安装监控栈
	@echo "[+] 安装 kube-prometheus-stack..."
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
	helm repo update
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
		-n monitoring --create-namespace

agents: ## 安装可观测性 agent
	@echo "[+] 安装 OTel / Blackbox / Loki..."
	helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
	helm repo update
	helm upgrade --install otel open-telemetry/opentelemetry-collector -n monitoring
	helm upgrade --install blackbox prometheus-community/prometheus-blackbox-exporter -n monitoring
	helm upgrade --install loki grafana/loki -n monitoring
	helm upgrade --install promtail grafana/promtail -n monitoring

## ============ 阶段 3: 应用 + GitOps ============
platform: ## 安装 Harbor + GitLab
	@echo "[+] 安装 Harbor..."
	helm repo add harbor https://helm.goharbor.io 2>/dev/null || true
	helm repo update
	helm upgrade --install harbor harbor/harbor -n harbor --create-namespace \
		--set externalURL=https://$(HARBOR_HOST) \
		--set harborAdminPassword=$(HARBOR_PASS)
	@echo "[+] 安装 GitLab..."
	helm repo add gitlab https://charts.gitlab.io 2>/dev/null || true
	helm repo update
	helm upgrade --install gitlab gitlab/gitlab -n gitlab --create-namespace --timeout 600s

gitops: ## 安装 Flux CD
	@echo "[+] 安装 Flux CD..."
	flux bootstrap github --owner=$(GIT_OWNER) --repository=$(GIT_REPO) \
		--branch=main --path=./clusters/kvm --personal

tenants: ## 配置三模式租户
	@echo "[+] 应用租户配置..."
	kubectl apply -k infrastructure/tenants/
	kubectl apply -k infrastructure/crossplane/

operators: ## 安装共享 Operator
	@echo "[+] 安装 redis-operator..."
	helm repo add ot-helm https://ot-container-kit.github.io/helm-charts 2>/dev/null || true
	helm repo update
	helm upgrade --install redis-operator ot-helm/redis-operator \
		-n redis-operator --create-namespace
	@echo "[+] 安装 CloudNative PG..."
	helm repo add cnpg https://cloudnative-pg.github.io/charts 2>/dev/null || true
	helm repo update
	helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace

images: ## 推送镜像到 Harbor
	@echo "[+] 下载并推送镜像到 Harbor..."
	bash registry/download-images.sh

## ============ 阶段 4: 升级维护 ============
backup-upgrade: ## etcd 备份 + Velero（升级 SOP 见 docs）
	@echo "[+] 配置备份..."
	bash scripts/backup-etcd.sh

## ============ 验收 ============
verify-cluster: ## 验证集群
	kubectl get nodes
	kubectl get pods -A

verify-monitoring: ## 验证监控
	kubectl get pods -n monitoring

verify-apps: ## 验证应用
	kubectl get pods -n harbor
	kubectl get pods -n gitlab

## ============ 文档预览 ============
docs: ## 启动文档远程预览服务 (http://<本机IP>:$(DOCS_PORT))
	@echo "[+] 文档预览: http://<本机IP>:$(DOCS_PORT)"
	docker run --rm -p $(DOCS_PORT):8000 -v $(CURDIR):/docs \
		$(DOCS_IMAGE) serve -a 0.0.0.0:8000

docs-build: ## 构建静态文档到 site/
	@echo "[+] 构建静态文档..."
	docker run --rm -v $(CURDIR):/docs $(DOCS_IMAGE) build

docs-down: ## 停止文档预览容器
	@docker ps -q --filter "ancestor=$(DOCS_IMAGE)" | xargs -r docker stop

## ============ 清理 ============
clean: ## 销毁全部 VM 和资源
	@echo "[!] 销毁所有 VM..."
	bash kvm/scripts/destroy-all.sh
