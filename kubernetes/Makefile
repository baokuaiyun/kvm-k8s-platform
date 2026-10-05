# Kubernetes 安装模块 Makefile
SHELL := /bin/bash
include ../variables.mk

.PHONY: install-common kube-vip init-cp join-cp join-worker cni upgrade

install-common: ## 安装 kubelet/kubeadm/containerd (起步节点)
	bash scripts/install-common.sh

kube-vip: ## 部署 kube-vip VIP（init 前）
	bash scripts/setup-kube-vip.sh

init-cp: ## 初始化控制面 (cp-1，endpoint=VIP)
	bash scripts/init-control-plane.sh

join-cp: ## 控制面扩容: make -f kubernetes/Makefile join-cp IDX=2
	@[ -n "$(IDX)" ] || { echo "用法: make join-cp IDX=<序号 2..3>"; exit 1; }
	bash scripts/join-control-plane.sh "$$(echo $(CP_NAMES) | cut -d' ' -f$(IDX))"

join-worker: ## Worker 扩容: make -f kubernetes/Makefile join-worker IDX=2
	@[ -n "$(IDX)" ] || { echo "用法: make join-worker IDX=<序号 2>"; exit 1; }
	bash scripts/join-worker.sh "$$(echo $(WK_NAMES) | cut -d' ' -f$(IDX))"

cni: ## 安装 Cilium
	helm repo add cilium https://helm.cilium.io 2>/dev/null || true
	helm repo update
	sed 's|__IMAGE_REPOSITORY__|$(IMAGE_REPOSITORY)|g' configs/cilium-values.yaml > /tmp/cilium-values.yaml
	helm upgrade --install cilium cilium/cilium -n kube-system \
		-f /tmp/cilium-values.yaml

upgrade: ## 升级集群
	bash scripts/upgrade.sh $(K8S_NEW_VERSION)
