# 平台服务 Makefile (Harbor/GitLab/Backstage)
SHELL := /bin/bash
include ../variables.mk

.PHONY: harbor gitlab backstage cert issuer

harbor: ## 安装 Harbor
	helm repo add harbor https://helm.goharbor.io 2>/dev/null || true
	helm repo update
	helm upgrade --install harbor harbor/harbor -n harbor --create-namespace \
		--set externalURL=https://$(HARBOR_HOST) \
		--set harborAdminPassword=$(HARBOR_PASS) \
		--set persistence.enabled=true \
		--set persistence.persistentVolumeClaim.registry.storageClass=longhorn \
		--set metrics.enabled=true

gitlab: ## 安装 GitLab
	helm repo add gitlab https://charts.gitlab.io 2>/dev/null || true
	helm repo update
	helm upgrade --install gitlab gitlab/gitlab -n gitlab --create-namespace --timeout 600s \
		--set global.hosts.domain=$(DOMAIN) \
		--set global.hosts.https=true \
		--set certmanager.install=false \
		--set nginx-ingress.enabled=false \
		--set gitlab.webservice.minReplicas=1 \
		--set registry.enabled=false

cert: ## 安装 cert-manager
	helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
	helm repo update
	helm upgrade --install cert-manager jetstack/cert-manager \
		-n cert-manager --create-namespace --set installCRDs=true

issuer: ## 创建 Let's Encrypt ClusterIssuer（需先配置 alidns-secret）
	kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@$(DOMAIN)
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - dns01:
        alidns:
          accessKeySecretRef: {name: alidns-secret, key: access-key}
          secretKeySecretRef: {name: alidns-secret, key: secret-key}
          regionId: $(ALIYUN_REGION)
EOF
