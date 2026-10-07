#!/usr/bin/env bash
# [危险] 清除宿主云盘层：ZFS 池 + MinIO 容器（+ 可选文件 vdev）
# 会删除宿主上的所有 zvol 数据！仅在确认废弃时使用。
# 用法: FORCE=1 bash kvm/scripts/purge-host-storage.sh
set -euo pipefail

ZFS_POOL="${ZFS_POOL:-tank}"
HOST_ZFS_FILE="${HOST_ZFS_FILE:-/data/zfs-pool.img}"
FORCE="${FORCE:-0}"

echo "[!] 将删除宿主存储：ZFS 池 ${ZFS_POOL}、MinIO 容器、文件 vdev ${HOST_ZFS_FILE}"
echo "[!] 此操作不可逆，宿主上的 PVC 数据将全部丢失！"
if [ "$FORCE" != "1" ]; then
  read -r -p "输入 yes 确认: " ans
  [ "$ans" = "yes" ] || { echo "已取消"; exit 0; }
fi

if command -v docker >/dev/null 2>&1; then
  echo "[+] 删除 MinIO 容器 host-minio"
  docker rm -f host-minio 2>/dev/null || true
fi
if command -v zpool >/dev/null 2>&1; then
  echo "[+] 销毁 ZFS 池 ${ZFS_POOL}"
  zpool destroy "$ZFS_POOL" 2>/dev/null || true
fi
[ -n "$HOST_ZFS_FILE" ] && rm -f "$HOST_ZFS_FILE" || true
echo "[+] 完成：宿主存储已清除"
