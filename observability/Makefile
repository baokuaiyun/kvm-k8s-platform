# 可观测性 Makefile（监控/日志/告警）
SHELL := /bin/bash
include ../variables.mk

.PHONY: monitoring agents alerts alerts-print

monitoring: ## 安装 Prometheus + Grafana + Alertmanager（持久化到规范 SC）
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
	helm repo update
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
		-n monitoring --create-namespace \
		--set alertmanager.enabled=true \
		--set alertmanager.alertmanagerSpec.alertmanagerConfigSelector={} \
		--set alertmanager.alertmanagerSpec.alertmanagerConfigNamespaceSelector={} \
		--set alertmanager.alertmanagerSpec.alertmanagerConfigMatcherStrategy.type=None \
		--set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.storageClassName=$(STORAGE_CLASS) \
		--set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.resources.requests.storage=2Gi \
		--set prometheus.prometheusSpec.retention=$(PROMETHEUS_RETENTION) \
		--set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=$(STORAGE_CLASS) \
		--set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=$(PROMETHEUS_SIZE) \
		--set grafana.enabled=true \
		--set grafana.persistence.enabled=true \
		--set grafana.persistence.storageClassName=$(STORAGE_CLASS) \
		--set grafana.persistence.size=$(GRAFANA_SIZE) \
		--set grafana.ingress.enabled=true \
		--set grafana.ingress.hosts[0]=$(GRAFANA_HOST)

agents: ## 安装 OTel / Blackbox / Loki / Promtail
	helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
	helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
	helm repo update
	helm upgrade --install otel open-telemetry/opentelemetry-collector -n monitoring
	helm upgrade --install blackbox prometheus-community/prometheus-blackbox-exporter -n monitoring
	helm upgrade --install loki grafana/loki -n monitoring \
		--set singleBinary.persistence.enabled=true \
		--set singleBinary.persistence.storageClass=$(STORAGE_CLASS) \
		--set singleBinary.persistence.size=$(LOKI_SIZE)
	helm upgrade --install promtail grafana/promtail -n monitoring

alerts: ## 应用告警规则 + 渲染 AlertmanagerConfig（系统参数化）
	bash apply-alerts.sh

alerts-print: ## 只打印将要应用的 AlertmanagerConfig
	bash apply-alerts.sh --print
