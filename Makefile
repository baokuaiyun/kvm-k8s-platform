# =============================================================================
# 顶层 Makefile — KVM 生产集群一键构建/重建
# 用法: make help
# =============================================================================
SHELL := /bin/bash
include variables.mk

.PHONY: help init phase1 phase2 phase3 phase4 verify clean docs docs-build docs-down \
	network-refresh dns-check vm-create vm-add-cp vm-add-worker \
	k8s-common kube-vip k8s-init k8s-join k8s-install join-cp join-worker scale-out kubeconfig \
	acr-prepare image-load image-preflight helm-images charts-pull charts-push-yunxiao charts-push-git yunxiao-repos idp \
	kvm-init dirs network-create image-download \
	cni storage storage-class cert security monitoring agents platform harbor gitlab platform-data gitops flux-operator tenants operators images \
	resolve-artifacts sync-artifacts publish-artifacts verify-bootstrap mgmt-bootstrap member-bootstrap \
	backup-upgrade velero verify-cluster verify-monitoring verify-apps verify-storage app-backup app-restore

DOCS_PORT ?= 8000
DOCS_IMAGE ?= squidfunk/mkdocs-material:latest

help: ## 显示所有可用目标
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "};{printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'

## ============ 阶段编排 ============
init: kvm-init network-create dirs image-download ## 初始化 KVM 环境
phase1: init vm-create acr-prepare charts-pull k8s-common image-load image-preflight k8s-init k8s-join kube-vip cni storage storage-class cert ## 阶段1: 基础集群创建（镜像/chart 先就绪）
phase2: security idp monitoring agents          ## 阶段2: 安全/身份及运营监控
phase3: operators platform-data platform gitops tenants images ## 阶段3: Operator→共享数据→应用+GitOps
phase4: backup-upgrade                          ## 阶段4: 持续升级维护
verify: verify-cluster verify-monitoring verify-apps verify-storage ## 全量验收

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

harbor-init: ## Harbor 建项目(私有)/robot/改 admin 密码
	bash registry/harbor-init.sh

push-to-harbor: ## 本源已预载镜像推送入 Harbor（scheme C）
	bash registry/push-tars-to-harbor.sh

push-charts: ## 本地 chart 推送到 Harbor OCI
	bash registry/push-charts-to-harbor.sh

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

kube-vip: ## 部署 kube-vip VIP（init 之后；读取本节点 kubeconfig）
	bash kubernetes/scripts/setup-kube-vip.sh

k8s-init: ## 初始化控制面 (cp-1，endpoint=VIP)
	bash kubernetes/scripts/init-control-plane.sh

kubeconfig: ## 导出/合并本集群 kubeconfig: make kubeconfig [K8S_CONTEXT=...]
	bash kubernetes/scripts/export-kubeconfig.sh

k8s-join: ## 加入起步 Worker
	bash kubernetes/scripts/join-worker.sh all

k8s-install: ## kubeadm 安装集群 (preflight→common→init→join→kube-vip)
	@echo "[+] 0/5 镜像预检（缺失即中断）..."
	bash kubernetes/scripts/preflight-images.sh
	@echo "[+] 1/5 安装 kubelet/kubeadm/containerd..."
	bash kubernetes/scripts/install-common.sh
	@echo "[+] 2/5 初始化控制面（自动绑静态 VIP）..."
	bash kubernetes/scripts/init-control-plane.sh
	@echo "[+] 3/5 加入 Worker 节点..."
	bash kubernetes/scripts/join-worker.sh all
	@echo "[+] 4/5 部署 kube-vip（接管 VIP）..."
	bash kubernetes/scripts/setup-kube-vip.sh
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

storage: ## 安装 Longhorn 存储（含生产化 overlay：副本/备份目标/控制面调度）
	@echo "[+] 安装 Longhorn（replicas=$(LONGHORN_REPLICAS), backupTarget=$(BACKUP_TARGET)）..."
	helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
	helm repo update
	sed 's|__IMAGE_REPOSITORY__|$(IMAGE_REPOSITORY)|g' kubernetes/configs/longhorn-values.yaml > /tmp/longhorn-values.yaml
	sed -e 's|__LONGHORN_REPLICAS__|$(LONGHORN_REPLICAS)|g' \
	    -e 's|__BACKUP_TARGET__|$(BACKUP_TARGET)|g' \
	    -e 's|__BACKUP_CRED_SECRET__|$(LONGHORN_BACKUP_CRED_SECRET)|g' \
	    -e 's|__LONGHORN_ALLOW_CONTROL_PLANE__|$(LONGHORN_ALLOW_CONTROL_PLANE)|g' \
	    storage/longhorn/values-overlay.yaml > /tmp/longhorn-overlay.yaml
	helm upgrade --install longhorn $(HELM_LONGHORN) \
		-n longhorn-system --create-namespace \
		-f /tmp/longhorn-values.yaml \
		-f /tmp/longhorn-overlay.yaml \
		--set defaultSettings.defaultReplicaCount=$(LONGHORN_REPLICAS)

storage-class: ## 应用规范 StorageClass（app-storage）与备份凭据
	@echo "[+] 应用 StorageClass 契约（backend=$(STORAGE_BACKEND)）..."
	bash storage/apply.sh

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
platform-data: ## 部署共享 PG/Redis（CNPG + redis-operator；需先 make operators）
	@echo "[+] 部署共享数据层 platform-data..."
	bash platform/platform-data/deploy.sh

harbor: ## 安装 Harbor（外部 PG/Redis 指向 platform-data）
	@echo "[+] 安装 Harbor（外部依赖 platform-data）..."
	helm repo add harbor https://helm.goharbor.io 2>/dev/null || true
	helm repo update >/dev/null 2>&1 || true
	sed -e 's|__IMAGE_REPOSITORY__|$(IMAGE_REPOSITORY)|g' \
	    -e 's|__HARBOR_HOST__|$(HARBOR_HOST)|g' \
	    -e 's|__HARBOR_PASS__|$(HARBOR_PASS)|g' \
	    -e 's|__PG_HOST__|platform-pg-rw.$(PLATFORM_DATA_NS).svc.cluster.local|g' \
	    -e 's|__REDIS_HOST__|platform-redis.$(PLATFORM_DATA_NS).svc.cluster.local|g' \
	    -e 's|__PG_HARBOR_PASS__|$(PG_HARBOR_PASS)|g' \
	    -e 's|__REDIS_PASS__|$(REDIS_PASS)|g' \
	    -e 's|__STORAGE_CLASS__|$(STORAGE_CLASS)|g' \
	    -e 's|__HARBOR_REGISTRY_SIZE__|$(HARBOR_REGISTRY_SIZE)|g' \
	    -e 's|__HARBOR_JOBSERVICE_SIZE__|$(HARBOR_JOBSERVICE_SIZE)|g' \
	    -e 's|__HARBOR_TRIVY_SIZE__|$(HARBOR_TRIVY_SIZE)|g' \
	    kubernetes/configs/harbor-values.yaml > /tmp/harbor-values.yaml
	helm upgrade --install harbor $(HELM_HARBOR) -n harbor --create-namespace -f /tmp/harbor-values.yaml

gitlab: ## 安装 GitLab（外部 PG/Redis/对象存储；对象存储见 GITLAB_OBJECT_STORE）
	@echo "[+] 安装 GitLab（外部依赖 platform-data，对象存储=$(GITLAB_OBJECT_STORE)）..."
	helm repo add gitlab https://charts.gitlab.io 2>/dev/null || true
	helm repo update >/dev/null 2>&1 || true
	sed -e 's|__DOMAIN__|$(DOMAIN)|g' \
	    -e 's|__PG_HOST__|platform-pg-rw.$(PLATFORM_DATA_NS).svc.cluster.local|g' \
	    -e 's|__REDIS_HOST__|platform-redis.$(PLATFORM_DATA_NS).svc.cluster.local|g' \
	    -e 's|__STORAGE_CLASS__|$(STORAGE_CLASS)|g' \
	    -e 's|__GITALY_SIZE__|$(GITALY_SIZE)|g' \
	    -e 's|__GITLAB_OBJECT_SIZE__|$(GITLAB_OBJECT_SIZE)|g' \
	    kubernetes/configs/gitlab-values.yaml > /tmp/gitlab-values.yaml
	@if [ "$(GITLAB_OBJECT_STORE)" = "oss" ]; then \
		echo "[+] 配置 OSS 对象存储 Secret..."; \
		bash platform/gitlab/objectstore-secret.sh; \
		cp kubernetes/configs/gitlab-objectstore-oss.yaml /tmp/gitlab-objectstore.yaml; \
	else \
		cp kubernetes/configs/gitlab-objectstore-minio.yaml /tmp/gitlab-objectstore.yaml; \
	fi
	helm upgrade --install gitlab $(HELM_GITLAB) -n gitlab --create-namespace --timeout 900s \
		-f /tmp/gitlab-values.yaml \
		-f /tmp/gitlab-objectstore.yaml

platform: harbor gitlab ## 安装 Harbor + GitLab（外部 PG/Redis 指向 platform-data）

flux-operator: ## 安装/升级 Flux Operator（Helm；chart+镜像走 Harbor，--take-ownership）
	@echo "[+] 安装/升级 Flux Operator（Helm，对齐 D2）..."
	HARBOR_HOST=$(HARBOR_HOST) HARBOR_PROJECT=$(HARBOR_PROJECT) \
	HARBOR_ROBOT_PASS='$(HARBOR_ROBOT_PASS)' \
	HELM_CHARTS_DIR=$(HELM_CHARTS_DIR) FLUX_OPERATOR_VERSION=$(FLUX_OPERATOR_VERSION) \
	GHCR_MIRROR=$(GHCR_MIRROR) \
	bash platform/flux/install.sh

gitops: flux-operator ## 安装 Flux Operator 并接入集群模式 fleet（all-in-one）
	@echo "[+] 应用 fleet/${FLEET_MODE} FluxInstance ..."
	kubectl apply -f fleet/$(FLEET_MODE)/flux-instance.yaml
	@echo "[+] 应用租户 ResourceSet 样板 ..."
	kubectl apply -f tenants/infra.yaml

FLEET_ENV ?= drill
SIGN ?= --sign

resolve-artifacts: ## 解析某模式制品: make resolve-artifacts MODE=all-in-one FLEET_ENV=drill
	@echo "[+] resolve artifacts (mode=$(FLEET_MODE) env=$(FLEET_ENV) type=$(CLUSTER_TYPE))..."
	HARBOR_HOST=$(HARBOR_HOST) HARBOR_PROJECT=$(HARBOR_PROJECT) HELM_CHARTS_DIR=$(HELM_CHARTS_DIR) CLUSTER_TYPE=$(CLUSTER_TYPE) \
	bash bootstrap/resolve-artifacts.sh $(FLEET_MODE) $(FLEET_ENV)

sync-artifacts: ## 检测式按需导入 Harbor（默认签名）: make sync-artifacts
	@echo "[+] sync artifacts (mode=$(FLEET_MODE) env=$(FLEET_ENV))..."
	HARBOR_HOST=$(HARBOR_HOST) HARBOR_PROJECT=$(HARBOR_PROJECT) \
	HARBOR_ROBOT_PASS='$(HARBOR_ROBOT_PASS)' CLUSTER_TYPE=$(CLUSTER_TYPE) \
	MIRROR_DOCKER=$(MIRROR_DOCKER) MIRROR_QUAY=$(MIRROR_QUAY) MIRROR_GHCR=$(MIRROR_GHCR) MIRROR_K8S=$(MIRROR_K8S) \
	bash bootstrap/sync-artifacts.sh $(FLEET_MODE) $(FLEET_ENV) $(SIGN)

publish-artifacts: resolve-artifacts sync-artifacts ## 解析+检测式导入+签名（按 fleet 模式，按需增量）
	@echo "[+] publish-artifacts 完成 (mode=$(FLEET_MODE) env=$(FLEET_ENV))"

mgmt-bootstrap: ## 本集群引导: Day-0→核心→数据平面→Harbor→制品→Flux: make mgmt-bootstrap FLEET_MODE=mgmt
	HARBOR_HOST=$(HARBOR_HOST) HARBOR_PROJECT=$(HARBOR_PROJECT) HARBOR_ROBOT_PASS='$(HARBOR_ROBOT_PASS)' \
	HELM_CHARTS_DIR=$(HELM_CHARTS_DIR) IMAGE_CACHE_DIR=$(IMAGE_CACHE_DIR) \
	FLEET_MODE=$(FLEET_MODE) FLEET_ENV=$(FLEET_ENV) \
	bash bootstrap/mgmt/bootstrap.sh

member-bootstrap: ## 成员集群引导: 指向本Harbor→Flux→按需制品: make member-bootstrap FLEET_MODE=biz
	HARBOR_HOST=$(HARBOR_HOST) HARBOR_PROJECT=$(HARBOR_PROJECT) HARBOR_ROBOT_PASS='$(HARBOR_ROBOT_PASS)' \
	FLEET_MODE=$(FLEET_MODE) FLEET_ENV=$(FLEET_ENV) ENABLE_FLUX=$(ENABLE_FLUX) DATA_SOURCE=$(DATA_SOURCE) \
	bash bootstrap/member/bootstrap.sh

verify-bootstrap: ## 引导面验收（Harbor/Flux/模式制品）
	@echo "[+] 验证引导面..."
	@helm -n flux-system list | grep -q flux-operator && echo "  flux-operator: OK" || echo "  flux-operator: 缺失"
	@kubectl -n flux-system get fluxinstance flux >/dev/null 2>&1 && echo "  FluxInstance: OK" || echo "  FluxInstance: 缺失"
	@curl -sk --noproxy '*' -o /dev/null -w "  harbor: %{http_code}\n" https://$(HARBOR_HOST)/api/v2.0/ping || true
	@if [ -f locks/$(FLEET_MODE)-$(FLEET_ENV)-$(CLUSTER_TYPE).lock ]; then echo "  lock: locks/$(FLEET_MODE)-$(FLEET_ENV)-$(CLUSTER_TYPE).lock ($$(grep -vc '^#' locks/$(FLEET_MODE)-$(FLEET_ENV)-$(CLUSTER_TYPE).lock) 条)"; else echo "  lock: 缺失（make resolve-artifacts）"; fi

tenants: ## 配置三模式租户
	@echo "[+] 应用租户配置..."
	kubectl apply -k infrastructure/tenants/
	kubectl apply -k infrastructure/crossplane/

operators: ## 安装共享 Operator（本域镜像 + 本地 chart）
	@echo "[+] 安装 redis-operator..."
	helm repo add ot-helm https://ot-container-kit.github.io/helm-charts 2>/dev/null || true
	helm repo add cnpg https://cloudnative-pg.github.io/charts 2>/dev/null || true
	helm repo update
	sed 's|__IMAGE_REPOSITORY__|$(IMAGE_REPOSITORY)|g' kubernetes/configs/redis-operator-values.yaml > /tmp/redis-operator-values.yaml
	helm upgrade --install redis-operator $(HELM_REDIS_OP) \
		-n redis-operator --create-namespace -f /tmp/redis-operator-values.yaml
	@echo "[+] 安装 CloudNative PG..."
	sed 's|__IMAGE_REPOSITORY__|$(IMAGE_REPOSITORY)|g' kubernetes/configs/cloudnative-pg-values.yaml > /tmp/cloudnative-pg-values.yaml
	helm upgrade --install cnpg $(HELM_CNPG) \
		-n cnpg-system --create-namespace -f /tmp/cloudnative-pg-values.yaml
	@echo "[+] 等待 Operator 就绪..."
	kubectl -n redis-operator rollout status deploy/redis-operator --timeout=180s
	kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg --timeout=180s

images: ## 推送镜像到 Harbor
	@echo "[+] 下载并推送镜像到 Harbor..."
	bash registry/download-images.sh

## ============ 阶段 4: 升级维护 ============
backup-upgrade: ## etcd 异地备份 + Velero 定时备份（升级 SOP 见 docs）
	@echo "[+] etcd 备份（本地 + 异地）..."
	bash scripts/backup-etcd.sh
	@echo "[+] 应用 Velero 定时备份（未安装 velero 时先执行 make velero）..."
	kubectl apply -f scripts/velero-schedule.yaml 2>/dev/null || \
		echo "[!] Velero 未安装，跳过 schedule（make velero）"

velero: ## 安装 Velero（OSS/MinIO 对象存储）+ 定时备份
	@echo "[+] 安装 Velero..."
	bash scripts/velero-install.sh

## ============ 验收 ============
verify-cluster: ## 验证集群
	kubectl get nodes
	kubectl get pods -A

verify-monitoring: ## 验证监控
	kubectl get pods -n monitoring

verify-apps: ## 验证应用
	kubectl get pods -n harbor
	kubectl get pods -n gitlab

verify-storage: ## 验证存储契约/副本/备份目标/备份时效
	@echo "[+] 存储与备份验收..."
	bash scripts/verify-storage.sh

app-backup: ## 应用级一致性备份（Harbor/GitLab/PG）
	@echo "[+] 应用数据一致性备份..."
	bash platform/backup/backup.sh

app-restore: ## 应用恢复演练（APP=harbor|gitlab|casdoor|pg）
	@echo "[+] 应用恢复演练 APP=$(APP)..."
	bash platform/backup/restore.sh $(APP)

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
