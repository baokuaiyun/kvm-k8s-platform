# Kubernetes 安装模块 Makefile
SHELL := /bin/bash
include ../variables.mk

.PHONY: install-common init-cp join-cp join-worker cni upgrade

install-common: ## 所有节点安装 kubelet/kubeadm
	bash scripts/install-common.sh

init-cp: ## 初始化控制面 (cp-1)
	bash scripts/init-control-plane.sh

cni: ## 安装 Cilium
	helm repo add cilium https://helm.cilium.io 2>/dev/null || true
	helm repo update
	helm upgrade --install cilium cilium/cilium -n kube-system \
		-f configs/cilium-values.yaml

upgrade: ## 升级集群
	bash scripts/upgrade.sh $(K8S_NEW_VERSION)
