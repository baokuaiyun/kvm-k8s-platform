# KVM 模块 Makefile
SHELL := /bin/bash
include ../variables.mk

# 单节点起步：cp-1 使用放大的 NODE_* 规格
ifeq ($(SINGLE_NODE_SPEC),1)
CP1_VCPU := $(NODE_VCPU)
CP1_RAM  := $(NODE_RAM)
CP1_DISK := $(NODE_DISK)
else
CP1_VCPU := $(CP_VCPU)
CP1_RAM  := $(CP_RAM)
CP1_DISK := $(CP_DISK)
endif

.PHONY: init network network-refresh dns-check dirs image vm-create vm-add-cp vm-add-worker destroy list

init: ## 安装 KVM 工具链
	apt-get install -y -qq qemu-kvm libvirt-daemon-system libvirt-clients \
		virtinst bridge-utils cloud-image-utils cpu-checker libguestfs-tools
	systemctl enable --now libvirtd

network: ## 创建 NAT 网络（幂等）
	@if virsh net-info $(NET_NAME) >/dev/null 2>&1; then \
		echo "[=] 网络 $(NET_NAME) 已存在"; \
	else \
		virsh net-define br-prod.xml; \
	fi
	virsh net-start $(NET_NAME) || true
	virsh net-autostart $(NET_NAME)

network-refresh: ## 应用网络 XML 变更（含内网 DNS，短暂断网）
	virsh net-destroy $(NET_NAME) || true
	virsh net-undefine $(NET_NAME) || true
	virsh net-define br-prod.xml
	virsh net-start $(NET_NAME)
	virsh net-autostart $(NET_NAME)

dns-check: ## 验证内网 DNS（endpoint/VIP）
	@echo "[+] 解析 $(CP_ENDPOINT):"
	dig @$(NET_GATEWAY) $(CP_ENDPOINT) +short

dirs: ## 创建存储目录
	mkdir -p $(IMAGE_DIR) $(DISK_DIR) $(SEED_DIR)

image: ## 下载 Debian 13 镜像
	[ -f "$(IMAGE_DIR)/$(BASE_IMAGE)" ] || \
		wget -q "$(BASE_IMAGE_URL)" -O "$(IMAGE_DIR)/$(BASE_IMAGE)"

vm-create: ## 创建起步节点（单节点 1CP，NODE_* 规格）
	@echo "[+] 创建起步控制面 (前 $(CP_INIT_COUNT) 台；single_node_spec=$(SINGLE_NODE_SPEC))..."
	@i=1; for ip in $(wordlist 1,$(CP_INIT_COUNT),$(CP_IPS)); do \
		name=$$(echo $(CP_NAMES) | cut -d' ' -f$$i); \
		mac=$$(echo $(CP_MACS) | cut -d' ' -f$$i); \
		bash scripts/create-vm.sh $$name $$ip $$mac $(CP1_VCPU) $(CP1_RAM) $(CP1_DISK); \
		i=$$((i+1)); \
	done
	@if [ "$(WK_INIT_COUNT)" -gt 0 ]; then \
		echo "[+] 创建起步 Worker (前 $(WK_INIT_COUNT) 台)..."; \
		i=1; for ip in $(wordlist 1,$(WK_INIT_COUNT),$(WK_IPS)); do \
			name=$$(echo $(WK_NAMES) | cut -d' ' -f$$i); \
			mac=$$(echo $(WK_MACS) | cut -d' ' -f$$i); \
			bash scripts/create-vm.sh $$name $$ip $$mac $(WK_VCPU) $(WK_RAM) $(WK_DISK); \
			i=$$((i+1)); \
		done; \
	else \
		echo "[=] WK_INIT_COUNT=0：单节点起步，不创建 worker"; \
	fi

vm-add-cp: ## 新增控制面节点: make vm-add-cp IDX=2
	@[ -n "$(IDX)" ] || { echo "用法: make vm-add-cp IDX=<序号 2..3>"; exit 1; }
	@bash scripts/create-vm.sh \
		"$$(echo $(CP_NAMES) | cut -d' ' -f$(IDX))" \
		"$$(echo $(CP_IPS)   | cut -d' ' -f$(IDX))" \
		"$$(echo $(CP_MACS)  | cut -d' ' -f$(IDX))" \
		$(CP_VCPU) $(CP_RAM) $(CP_DISK)

vm-add-worker: ## 新增 Worker 节点: make vm-add-worker IDX=2
	@[ -n "$(IDX)" ] || { echo "用法: make vm-add-worker IDX=<序号 2>"; exit 1; }
	@bash scripts/create-vm.sh \
		"$$(echo $(WK_NAMES) | cut -d' ' -f$(IDX))" \
		"$$(echo $(WK_IPS)   | cut -d' ' -f$(IDX))" \
		"$$(echo $(WK_MACS)  | cut -d' ' -f$(IDX))" \
		$(WK_VCPU) $(WK_RAM) $(WK_DISK)

destroy: ## 销毁全部 VM
	bash scripts/destroy-all.sh

list: ## 列出 VM
	virsh list --all
