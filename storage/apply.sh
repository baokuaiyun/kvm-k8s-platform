#!/usr/bin/env bash
# 应用规范 StorageClass（app-storage）到集群
#   STORAGE_BACKEND=longhorn  -> storage/longhorn/storageclass.yaml（drill）
#   STORAGE_BACKEND=alicloud  -> storage/alicloud/storageclass.yaml（prod）
# 并创建 Longhorn 备份目标凭据 Secret（S3/OSS 需要；NFS 可留空）
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND="${STORAGE_BACKEND:-longhorn}"
SC="${STORAGE_CLASS:-app-storage}"
REPLICAS="${LONGHORN_REPLICAS:-2}"

case "$BACKEND" in
  longhorn|alicloud) ;;
  *) echo "[!] 未知 STORAGE_BACKEND=$BACKEND（longhorn|alicloud）"; exit 1 ;;
esac

SRC="$DIR/$BACKEND/storageclass.yaml"
[ -f "$SRC" ] || { echo "[!] 缺少 $SRC"; exit 1; }

command -v kubectl >/dev/null 2>&1 || { echo "[!] 需要 kubectl"; exit 1; }

echo "[+] 应用 StorageClass ${SC}（backend=${BACKEND}, longhorn_replicas=${REPLICAS}）"
sed -e "s|__STORAGE_CLASS__|${SC}|g" \
    -e "s|__LONGHORN_REPLICAS__|${REPLICAS}|g" \
    "$SRC" | kubectl apply -f -

if [ "$BACKEND" = "longhorn" ]; then
  # 备份目标凭据：NFS 环境可为空 Secret；S3/OSS 由环境变量注入
  NS=longhorn-system
  if [ -n "${LONGHORN_ACCESS_KEY:-}" ] && [ -n "${LONGHORN_SECRET_KEY:-}" ]; then
    echo "[+] 写入 S3/OSS 备份凭据 Secret（${NS}/${LONGHORN_BACKUP_CRED_SECRET:-longhorn-backup-cred}）"
    kubectl -n "$NS" create secret generic "${LONGHORN_BACKUP_CRED_SECRET:-longhorn-backup-cred}" \
      --from-literal=AWS_ACCESS_KEY_ID="${LONGHORN_ACCESS_KEY}" \
      --from-literal=AWS_SECRET_ACCESS_KEY="${LONGHORN_SECRET_KEY}" \
      --from-literal=AWS_ENDPOINTS="" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  else
    echo "[=] 未提供 S3/OSS 凭据，跳过（NFS 备份目标无需凭据）"
  fi
fi

echo "[+] 完成。kubectl get sc"
kubectl get sc || true
