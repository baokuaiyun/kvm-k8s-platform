# KVM 模块 Makefile
SHELL := /bin/bash
include ../variables.mk

.PHONY: init network dirs image vm-create destroy list

init: ## 安装 KVM 工具链
	apt-get install -y -qq qemu-kvm libvirt-daemon-system libvirt-clients \
		virtinst bridge-utils cloud-image-utils cpu-checker libguestfs-tools
	systemctl enable --now libvirtd

network: ## 创建 NAT 网络
	virsh net-define br-prod.xml
	virsh net-start $(NET_NAME) || true
	virsh net-autostart $(NET_NAME)

dirs: ## 创建存储目录
	mkdir -p $(IMAGE_DIR) $(DISK_DIR) $(SEED_DIR)

image: ## 下载 Debian 13 镜像
	[ -f "$(IMAGE_DIR)/$(BASE_IMAGE)" ] || \
		wget -q "$(BASE_IMAGE_URL)" -O "$(IMAGE_DIR)/$(BASE_IMAGE)"

vm-create: ## 创建全部 VM
	bash scripts/create-vm.sh k8s-cp-1 $(word 1,$(CP_IPS)) $(word 1,$(CP_MACS)) $(CP_VCPU) $(CP_RAM) $(CP_DISK)
	bash scripts/create-vm.sh k8s-cp-2 $(word 2,$(CP_IPS)) $(word 2,$(CP_MACS)) $(CP_VCPU) $(CP_RAM) $(CP_DISK)
	bash scripts/create-vm.sh k8s-cp-3 $(word 3,$(CP_IPS)) $(word 3,$(CP_MACS)) $(CP_VCPU) $(CP_RAM) $(CP_DISK)
	bash scripts/create-vm.sh k8s-worker-1 $(word 1,$(WK_IPS)) $(word 1,$(WK_MACS)) $(WK_VCPU) $(WK_RAM) $(WK_DISK)
	bash scripts/create-vm.sh k8s-worker-2 $(word 2,$(WK_IPS)) $(word 2,$(WK_MACS)) $(WK_VCPU) $(WK_RAM) $(WK_DISK)

destroy: ## 销毁全部 VM
	bash scripts/destroy-all.sh

list: ## 列出 VM
	virsh list --all
