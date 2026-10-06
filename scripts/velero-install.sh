#!/usr/bin/env bash
# 安装 Velero（AWS S3 兼容插件，指向 OSS/MinIO）+ 定时备份
# drill: 需一个 S3 兼容端点（建议在 NFS 上跑 MinIO），用 file-level(Kopia) 备份 PV
# prod : 指向阿里云 OSS
# 用法: bash scripts/velero-install.sh
set -euo pipefail

VELERO_BUCKET="${VELERO_BUCKET:?VELERO_BUCKET 未设置}"
VELERO_S3_URL="${VELERO_S3_URL:?VELERO_S3_URL 未设置（prod: oss-<region>.aliyuncs.com；drill: minio 地址）}"
OSS_REGION="${OSS_REGION:-cn-hangzhou}"
ACCESS_KEY="${S3_ACCESS_KEY:-${ALIYUN_ACCESS_KEY:-}}"
SECRET_KEY="${S3_SECRET_KEY:-${ALIYUN_SECRET_KEY:-}}"
PLUGIN="velero/velero-plugin-for-aws:v1.9.0"
VELERO_NS="velero"

command -v kubectl >/dev/null 2>&1 || { echo "[!] 需要 kubectl"; exit 1; }

if ! command -v velero >/dev/null 2>&1; then
  echo "[+] 未找到 velero CLI，尝试下载 linux-amd64..."
  ver="v1.14.1"
  tmp="$(mktemp -d)"
  curl -fsSL "https://github.com/vmware-tanzu/velero/releases/download/${ver}/velero-${ver}-linux-amd64.tar.gz" \
    | tar -xz -C "$tmp"
  install -m 0755 "$tmp"/velero-${ver}-linux-amd64/velero /usr/local/bin/velero
  rm -rf "$tmp"
  echo "[+] velero CLI 安装完成"
fi

if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ]; then
  echo "[!] 缺 S3_ACCESS_KEY / S3_SECRET_KEY（放 acr.env，勿提交）"; exit 1
fi

CRED="$(mktemp)"
trap 'rm -f "$CRED"' EXIT
cat > "$CRED" <<EOF
[default]
aws_access_key_id=${ACCESS_KEY}
aws_secret_access_key=${SECRET_KEY}
EOF

echo "[+] 安装 Velero（bucket=${VELERO_BUCKET} s3Url=${VELERO_S3_URL}）..."
# --use-volume-snapshots=false + node-agent(Kopia)：跨环境通用，PV 数据文件级入对象存储
velero install \
  --provider aws \
  --plugins "$PLUGIN" \
  --bucket "$VELERO_BUCKET" \
  --secret-file "$CRED" \
  --use-volume-snapshots=false \
  --use-node-agent \
  --backup-location-config "region=${OSS_REGION},s3Url=https://${VELERO_S3_URL},s3ForcePathStyle=true" \
  --namespace "$VELERO_NS" \
  --wait

echo "[+] 应用定时备份 Schedule..."
kubectl apply -f "$(cd "$(dirname "$0")" && pwd)/velero-schedule.yaml"

echo "[+] 完成。校验:"
echo "    velero backup-location get"
echo "    velero get schedules"
echo "    velero backup get"
