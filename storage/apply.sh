#!/usr/bin/env bash
# 应用规范 StorageClass（app-storage）到集群——Kustomize：base 契约 + 每驱动 patch
#   STORAGE_BACKEND=host-zfs-iscsi -> storage/host-zfs-iscsi（drill 云盘模拟，默认；含 VolumeSnapshotClass）
#   STORAGE_BACKEND=longhorn       -> storage/longhorn（可选后端）
#   STORAGE_BACKEND=alicloud       -> storage/alicloud（prod）
# 换驱动只改 STORAGE_BACKEND；契约字段（名/Retain/扩容/默认类）在 storage/base。
# 详见 docs/storage-plan.md、docs/cloud-disk-data-solution.md
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND="${STORAGE_BACKEND:-host-zfs-iscsi}"
SC="${STORAGE_CLASS:-app-storage}"
REPLICAS="${LONGHORN_REPLICAS:-2}"

case "$BACKEND" in
  host-zfs-iscsi|longhorn|alicloud) ;;
  *) echo "[!] 未知 STORAGE_BACKEND=$BACKEND（host-zfs-iscsi|longhorn|alicloud）"; exit 1 ;;
esac
[ -f "$DIR/$BACKEND/kustomization.yaml" ] || { echo "[!] 缺少 $DIR/$BACKEND/kustomization.yaml"; exit 1; }

command -v kubectl >/dev/null 2>&1 || { echo "[!] 需要 kubectl"; exit 1; }

echo "[+] 应用 StorageClass ${SC}（backend=${BACKEND}，Kustomize base+patch）"
# StorageClass 的 parameters 不可变：apply 失败则删除重建（Retain 策略下不动 PVC/PV）
if ! kubectl apply -k "$DIR/$BACKEND" 2>/tmp/sc-apply.err; then
  if grep -q "updates to parameters are forbidden\|field is immutable" /tmp/sc-apply.err; then
    echo "[=] StorageClass parameters 不可变 → 删除并重建 ${SC}"
    kubectl delete sc "$SC" --ignore-not-found >/dev/null
    kubectl apply -k "$DIR/$BACKEND"
  else
    cat /tmp/sc-apply.err >&2; exit 1
  fi
fi

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
