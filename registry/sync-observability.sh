#!/usr/bin/env bash
# 同步可观测性镜像到本域 Harbor（scheme C 短名）
# 源经国内镜像：docker.io->docker.m.daocloud.io，quay.io->quay.m.daocloud.io，
#             registry.k8s.io->k8s-gcr.m.daocloud.io
set -euo pipefail
HARBOR_HOST="${HARBOR_HOST:-harbor.test.baokuaiyun.com}"
HARBOR_PROJECT="${HARBOR_PROJECT:-baokuaiyun}"
: "${HARBOR_ROBOT_USER:?}"; : "${HARBOR_ROBOT_PASS:?}"
CREDS="${HARBOR_ROBOT_USER}:${HARBOR_ROBOT_PASS}"
export no_proxy='*' NO_PROXY='*'; unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY || true

# 源(不含registry)  镜像域    Harbor 短名
map=(
  "bats/bats:v1.4.1|docker.m.daocloud.io|bats-bats"
  "grafana/grafana:11.2.2-security-01|docker.m.daocloud.io|grafana-grafana"
  "kiwigrid/k8s-sidecar:1.28.0|quay.m.daocloud.io|kiwigrid-k8s-sidecar"
  "prometheus-operator/prometheus-config-reloader:v0.77.2|quay.m.daocloud.io|prometheus-operator-prometheus-config-reloader"
  "prometheus-operator/prometheus-operator:v0.77.2|quay.m.daocloud.io|prometheus-operator-prometheus-operator"
  "prometheus/alertmanager:v0.27.0|quay.m.daocloud.io|prometheus-alertmanager"
  "prometheus/node-exporter:v1.8.2|quay.m.daocloud.io|prometheus-node-exporter"
  "prometheus/prometheus:v2.55.0|quay.m.daocloud.io|prometheus-prometheus"
  "kube-state-metrics/kube-state-metrics:v2.13.0|k8s-gcr.m.daocloud.io|kube-state-metrics-kube-state-metrics"
  "ingress-nginx/kube-webhook-certgen:v20221220-controller-v1.5.1-58-g787ea74b6|k8s-gcr.m.daocloud.io|ingress-nginx-kube-webhook-certgen"
)

for e in "${map[@]}"; do
  IFS='|' read -r src mirror dst <<<"$e"
  tag="${src##*:}"
  target="docker://${HARBOR_HOST}/${HARBOR_PROJECT}/${dst}:${tag}"
  if skopeo inspect --tls-verify=false --creds "$CREDS" "$target" >/dev/null 2>&1; then
    echo "skip ${dst}:${tag}"; continue
  fi
  echo "== ${mirror}/${src} -> ${dst}:${tag}"
  if timeout -s KILL 900 skopeo copy --dest-tls-verify=false --dest-creds "$CREDS" \
       "docker://${mirror}/${src}" "$target" >/tmp/obs-err 2>&1; then
    echo "   ok"
  else
    echo "   FAIL"; tail -3 /tmp/obs-err
  fi
done
echo DONE_OBS
