# =============================================================================
# 顶层 Makefile — KVM 生产集群一键构建/重建
# 用法: make help
# =============================================================================
SHELL := /bin/bash
include variables.mk

.PHONY: help init phase1 phase2 phase3 phase4 verify clean docs docs-build docs-down \
	network-refresh dns-check vm-create vm-add-cp vm-add-worker \
	k8s-common kube-vip k8s-init k8s-join k8s-install join-cp join-worker scale-out \
	acr-prepare image-load image-preflight helm-images charts-pull charts-push-yunxiao charts-push-git yunxiao-repos idp \
	kvm-init dirs network-create image-download \
	cni storage cert security monitoring agents platform gitops tenants operators images \
	backup-upgrade verify-cluster verify-monitoring verify-apps

DOCS_PORT ?= 8000
DOCS_IMAGE ?= squidfunk/mkdocs-material:latest

help: ## 显示所有可用目标
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "};{printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'

## ============ 阶段编排 ============
init: kvm-init network-create dirs image-download ## 初始化 KVM 环境
phase1: init vm-create acr-prepare charts-pull k8s-common image-load image-preflight kube-vip k8s-init k8s-join cni storage cert ## 阶段1: 基础集群创建（镜像/chart 先就绪）
phase2: security idp monitoring agents          ## 阶段2: 安全/身份及运营监控
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

network-create: ## 创建 libvirt NAT 网络（含内网 DNS，幂等）
	@if virsh net-info $(NET_NAME) >/dev/null 2>&1; then \
		echo "[=] 网络 $(NET_NAME) 已存在（如需套用 XML 变更用 make network-refresh）"; \
	else \
		echo "[+] 创建 NAT 网络 $(NET_NAME)..."; \
		virsh net-define kvm/br-prod.xml; \
	fi
	@virsh net-info $(NET_NAME) 2>/dev/null | grep -q 'Active:.*yes' || virsh net-start $(NET_NAME)
	virsh net-autostart $(NET_NAME)

network-refresh: ## 应用网络 XML 变更（含内网 DNS，短暂断网）
	@echo "[+] 刷新网络 $(NET_NAME)..."
	virsh net-destroy $(NET_NAME) || true
	virsh net-undefine $(NET_NAME) || true
	virsh net-define kvm/br-prod.xml
	virsh net-start $(NET_NAME)
	virsh net-autostart $(NET_NAME)

dns-check: ## 验证内网 DNS（control-plane-endpoint）
	@echo "[+] 解析 $(CP_ENDPOINT):"
	dig @$(NET_GATEWAY) $(CP_ENDPOINT) +short

image-download: ## 下载 Debian 13 云镜像
	@if [ -s "$(IMAGE_DIR)/$(BASE_IMAGE)" ]; then \
		echo "[=] 云镜像已存在: $(BASE_IMAGE)"; \
	else \
		echo "[+] 下载 Debian 13 云镜像..."; \
		rm -f "$(IMAGE_DIR)/$(BASE_IMAGE).tmp"; \
		wget -q --tries=3 --timeout=60 -O "$(IMAGE_DIR)/$(BASE_IMAGE).tmp" "$(BASE_IMAGE_URL)" \
			&& mv "$(IMAGE_DIR)/$(BASE_IMAGE).tmp" "$(IMAGE_DIR)/$(BASE_IMAGE)"; \
	fi
	qemu-img info "$(IMAGE_DIR)/$(BASE_IMAGE)"

vm-create: ## 创建起步节点 (1CP+1W)
	@echo "[+] 创建起步控制面 (前 $(CP_INIT_COUNT) 台)..."
	@i=1; for ip in $(wordlist 1,$(CP_INIT_COUNT),$(CP_IPS)); do \
		name=$$(echo $(CP_NAMES) | cut -d' ' -f$$i); \
		mac=$$(echo $(CP_MACS) | cut -d' ' -f$$i); \
		bash kvm/scripts/create-vm.sh $$name $$ip $$mac $(CP_VCPU) $(CP_RAM) $(CP_DISK); \
		i=$$((i+1)); \
	done
	@echo "[+] 创建起步 Worker (前 $(WK_INIT_COUNT) 台)..."
	@i=1; for ip in $(wordlist 1,$(WK_INIT_COUNT),$(WK_IPS)); do \
		name=$$(echo $(WK_NAMES) | cut -d' ' -f$$i); \
		mac=$$(echo $(WK_MACS) | cut -d' ' -f$$i); \
		bash kvm/scripts/create-vm.sh $$name $$ip $$mac $(WK_VCPU) $(WK_RAM) $(WK_DISK); \
		i=$$((i+1)); \
	done
	virsh list --all

vm-add-cp: ## 新增控制面节点: make vm-add-cp IDX=2
	@[ -n "$(IDX)" ] || { echo "用法: make vm-add-cp IDX=<序号 2..3>"; exit 1; }
	@bash kvm/scripts/create-vm.sh \
		"$$(echo $(CP_NAMES) | cut -d' ' -f$(IDX))" \
		"$$(echo $(CP_IPS)   | cut -d' ' -f$(IDX))" \
		"$$(echo $(CP_MACS)  | cut -d' ' -f$(IDX))" \
		$(CP_VCPU) $(CP_RAM) $(CP_DISK)

vm-add-worker: ## 新增 Worker 节点: make vm-add-worker IDX=2
	@[ -n "$(IDX)" ] || { echo "用法: make vm-add-worker IDX=<序号 2>"; exit 1; }
	@bash kvm/scripts/create-vm.sh \
		"$$(echo $(WK_NAMES) | cut -d' ' -f$(IDX))" \
		"$$(echo $(WK_IPS)   | cut -d' ' -f$(IDX))" \
		"$$(echo $(WK_MACS)  | cut -d' ' -f$(IDX))" \
		$(WK_VCPU) $(WK_RAM) $(WK_DISK)

## ============ 镜像准备（init 前必须完成） ============
acr-prepare: ## 宿主机从 ACR 准备本域镜像 tar（TIERS=Tier0,Tier1）
	bash registry/prepare-acr-images.sh $(TIERS)

image-load: ## 分发本域镜像 tar 到节点并导入 containerd
	bash kubernetes/scripts/load-images.sh

image-preflight: ## 预检镜像是否齐全（缺失即失败，阻止 init）
	bash kubernetes/scripts/preflight-images.sh

helm-images: ## 从 chart 提取镜像清单: make helm-images RELEASE=x CHART=y [ARGS="-f ..."]
	@[ -n "$(RELEASE)" ] && [ -n "$(CHART)" ] || { echo "用法: make helm-images RELEASE=<name> CHART=<chart> [ARGS=]"; exit 1; }
	bash registry/helm-images.sh $(RELEASE) $(CHART) $(ARGS)

charts-pull: ## 拉取 Helm chart 到本地（云效或上游）
	bash registry/pull-charts.sh

charts-push-yunxiao: ## [旧] 推送本地 chart 到云效制品仓库（不支持 Helm，改用 charts-push-git）
	bash registry/push-charts-yunxiao.sh

charts-push-git: ## 推送本地 chart 到云效 Codeup Git 仓库
	bash registry/push-charts-git.sh

yunxiao-repos: ## 查询云效仓库: make yunxiao-repos [TYPE=HELM|codeup]
	bash registry/yunxiao-repos.sh $(TYPE)

idp: ## 部署 Casdoor（集群内统一用户管理 IdP）
	bash platform/casdoor/deploy.sh

k8s-common: ## 所有节点安装 kubelet/kubeadm/containerd
	bash kubernetes/scripts/install-common.sh

kube-vip: ## 部署 kube-vip VIP（init 前）
	bash kubernetes/scripts/setup-kube-vip.sh

k8s-init: ## 初始化控制面 (cp-1，endpoint=VIP)
	bash kubernetes/scripts/init-control-plane.sh

k8s-join: ## 加入起步 Worker
	bash kubernetes/scripts/join-worker.sh all

k8s-install: ## kubeadm 安装集群 (preflight→common→kube-vip→init→join)
	@echo "[+] 0/5 镜像预检（缺失即中断）..."
	bash kubernetes/scripts/preflight-images.sh
	@echo "[+] 1/5 安装 kubelet/kubeadm/containerd..."
	bash kubernetes/scripts/install-common.sh
	@echo "[+] 2/5 部署 kube-vip VIP..."
	bash kubernetes/scripts/setup-kube-vip.sh
	@echo "[+] 3/5 初始化控制面..."
	bash kubernetes/scripts/init-control-plane.sh
	@echo "[+] 4/5 加入 Worker 节点..."
	bash kubernetes/scripts/join-worker.sh all
	@echo "[+] 5/5 完成"

join-cp: ## 控制面扩容: make join-cp IDX=2
	@[ -n "$(IDX)" ] || { echo "用法: make join-cp IDX=<序号 2..3>"; exit 1; }
	bash kubernetes/scripts/join-control-plane.sh "$$(echo $(CP_NAMES) | cut -d' ' -f$(IDX))"

join-worker: ## Worker 扩容: make join-worker IDX=2
	@[ -n "$(IDX)" ] || { echo "用法: make join-worker IDX=<序号 2>"; exit 1; }
	bash kubernetes/scripts/join-worker.sh "$$(echo $(WK_NAMES) | cut -d' ' -f$(IDX))"

scale-out: ## 扩容到 3CP+2W (需先跑过 k8s-install)
	@echo "[+] 新增 cp-2/cp-3/worker-2..."
	$(MAKE) vm-add-cp IDX=2
	$(MAKE) vm-add-cp IDX=3
	$(MAKE) vm-add-worker IDX=2
	@echo "[+] 加入控制面 cp-2 / cp-3..."
	bash kubernetes/scripts/join-control-plane.sh $(word 2,$(CP_NAMES))
	bash kubernetes/scripts/join-control-plane.sh $(word 3,$(CP_NAMES))
	@echo "[+] 加入 Worker..."
	bash kubernetes/scripts/join-worker.sh $(word 2,$(WK_NAMES))

cni: ## 安装 Cilium CNI
	@echo "[+] 安装 Cilium..."
	helm repo add cilium https://helm.cilium.io 2>/dev/null || true
	helm repo update
	sed 's|__IMAGE_REPOSITORY__|$(IMAGE_REPOSITORY)|g' kubernetes/configs/cilium-values.yaml > /tmp/cilium-values.yaml
	helm upgrade --install cilium $(HELM_CILIUM) -n kube-system \
		-f /tmp/cilium-values.yaml

storage: ## 安装 Longhorn 存储
	@echo "[+] 安装 Longhorn..."
	helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
	helm repo update
	sed 's|__IMAGE_REPOSITORY__|$(IMAGE_REPOSITORY)|g' kubernetes/configs/longhorn-values.yaml > /tmp/longhorn-values.yaml
	helm upgrade --install longhorn $(HELM_LONGHORN) \
		-n longhorn-system --create-namespace \
		-f /tmp/longhorn-values.yaml \
		--set defaultSettings.defaultReplicaCount=$(LONGHORN_REPLICAS)

cert: ## 安装 cert-manager
	@echo "[+] 安装 cert-manager..."
	helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
	helm repo update
	sed 's|__IMAGE_REPOSITORY__|$(IMAGE_REPOSITORY)|g' kubernetes/configs/cert-manager-values.yaml > /tmp/cert-manager-values.yaml
	helm upgrade --install cert-manager $(HELM_CERTMGR) \
		-n cert-manager --create-namespace -f /tmp/cert-manager-values.yaml

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
