# 镜像管理 Makefile
SHELL := /bin/bash
include ../variables.mk

.PHONY: download push list mirror

download: ## 下载并推送镜像到 Harbor
	bash download-images.sh

push: ## 推送到 Harbor（别名）
	bash download-images.sh

list: ## 显示镜像清单
	cat images/tier*.txt | grep -v '^#' | grep -v '^$'

mirror: ## 生成 containerd mirror 配置
	@echo "containerd mirror 配置见: kubernetes/configs/containerd-config.toml"
