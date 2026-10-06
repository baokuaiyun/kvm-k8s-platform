#!/usr/bin/env bash
# 生成 GitLab 对象存储连接 Secret（阿里云 OSS / S3 兼容）
# 用法: S3_ENDPOINT=oss-cn-hangzhou.aliyuncs.com ... bash platform/gitlab/objectstore-secret.sh
set -euo pipefail

NS="${GITLAB_NS:-gitlab}"
: "${S3_ENDPOINT:?S3_ENDPOINT 未设置（如 oss-cn-hangzhou.aliyuncs.com）}"
: "${OSS_REGION:?OSS_REGION 未设置}"
: "${S3_ACCESS_KEY:?S3_ACCESS_KEY 未设置（acr.env）}"
: "${S3_SECRET_KEY:?S3_SECRET_KEY 未设置（acr.env）}"

command -v kubectl >/dev/null 2>&1 || { echo "[!] 需要 kubectl"; exit 1; }

CONN="$(cat <<EOF
provider: AWS
region: ${OSS_REGION}
aws_access_key_id: ${S3_ACCESS_KEY}
aws_secret_access_key: ${S3_SECRET_KEY}
endpoint: https://${S3_ENDPOINT}
path_style: true
EOF
)"

echo "[+] 写入 Secret ${NS}/gitlab-object-storage"
kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create secret generic gitlab-object-storage \
  --from-literal=connection="$CONN" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "[+] 完成。请确认 OSS bucket 已创建: ${GITLAB_OSS_BUCKET:-<未指定>}"
