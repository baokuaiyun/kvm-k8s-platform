#!/usr/bin/env bash
# GitLab route C 部署：Operator(已装) + GitLab CR + 外部依赖凭据
# 前置: Harbor 已同步 CNG 镜像；platform-data PG/Redis 就绪；MinIO 就绪；kgateway Gateway 就绪
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NS="${GITLAB_NS:-gitlab}"
DATA_NS="${PLATFORM_DATA_NS:-platform-data}"
GATEWAY_NS="${GATEWAY_NS:-gateway}"
GATEWAY_NAME="${GATEWAY_NAME:-gateway}"
DOMAIN="${DOMAIN:-test.baokuaiyun.com}"

kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "[+] 同步外部依赖凭据 -> ${NS}"
PGPW="$(kubectl -n "$DATA_NS" get secret gitlab-pg-cred -o jsonpath='{.data.password}' | base64 -d)"
kubectl -n "$NS" create secret generic gitlab-pg-cred \
  --from-literal=password="$PGPW" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

RPW="$(kubectl -n "$DATA_NS" get secret platform-redis-cred -o jsonpath='{.data.password}' | base64 -d)"
kubectl -n "$NS" create secret generic gitlab-redis-cred \
  --from-literal=password="$RPW" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

: "${MINIO_ROOT_USER:?MINIO_ROOT_USER 未设置}"; : "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD 未设置}"
OBJECT_STORE="${GITLAB_OBJECT_STORE:-minio}"
case "$OBJECT_STORE" in
  host-minio|minio-host)
    MINIO_ENDPOINT="${HOST_MINIO_ENDPOINT:-http://192.168.124.1:9000}";;
  minio|*)
    MINIO_ENDPOINT="http://minio.minio.svc.cluster.local:9000";;
esac
echo "[+] GitLab 对象存储: ${OBJECT_STORE} -> ${MINIO_ENDPOINT}"
CONN="$(cat <<EOF
provider: AWS
region: us-east-1
aws_access_key_id: ${MINIO_ROOT_USER}
aws_secret_access_key: ${MINIO_ROOT_PASSWORD}
endpoint: ${MINIO_ENDPOINT}
path_style: true
EOF
)"
kubectl -n "$NS" create secret generic gitlab-object-storage \
  --from-literal=connection="$CONN" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "[+] 应用 GitLab CR"
kubectl apply -f "$ROOT/platform/gitlab/gitlab-cr.yaml"

echo "[+] 完成。观察: kubectl -n ${NS} get pods; kubectl -n ${NS} get gitlab"
