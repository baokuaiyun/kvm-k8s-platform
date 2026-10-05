# 可观测性 Makefile（监控/日志/告警）
SHELL := /bin/bash
include ../variables.mk

.PHONY: monitoring agents alerts

monitoring: ## 安装 Prometheus + Grafana + Alertmanager
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
	helm repo update
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
		-n monitoring --create-namespace \
		--set alertmanager.enabled=true \
		--set grafana.enabled=true \
		--set grafana.ingress.enabled=true \
		--set grafana.ingress.hosts[0]=$(GRAFANA_HOST)

agents: ## 安装 OTel / Blackbox / Loki / Promtail
	helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
	helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
	helm repo update
	helm upgrade --install otel open-telemetry/opentelemetry-collector -n monitoring
	helm upgrade --install blackbox prometheus-community/prometheus-blackbox-exporter -n monitoring
	helm upgrade --install loki grafana/loki -n monitoring
	helm upgrade --install promtail grafana/promtail -n monitoring

alerts: ## 应用告警规则
	kubectl apply -f alerts.yaml
