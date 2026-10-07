#!/usr/bin/env bash
# 销毁 KVM VM（配置驱动，用于“删除→重建”）
#   KEEP_NETWORK=1        保留 br-prod（默认 1）
#   PURGE_HOST_STORAGE=1  额外销毁宿主 ZFS 池与 MinIO（默认 0，危险）
#   FORCE=1               非交互确认（自动化用）
# VM 列表取 CP_NAMES + WK_NAMES（variables.mk 已 export；直接运行时回退默认）
# 详见 docs/makefile-design.md、docs/cloud-disk-data-solution.md
set -euo pipefail

CP_NAMES="${CP_NAMES:-k8s-cp-1 k8s-cp-2 k8s-cp-3}"
WK_NAMES="${WK_NAMES:-k8s-worker-1 k8s-worker-2}"
DATA_DIR="${DATA_DIR:-/data/kvm}"
NET_NAME="${NET_NAME:-br-prod}"
KEEP_NETWORK="${KEEP_NETWORK:-1}"
PURGE_HOST_STORAGE="${PURGE_HOST_STORAGE:-0}"
FORCE="${FORCE:-0}"

VMS=($CP_NAMES $WK_NAMES)

echo "[+] 目标 VM: ${VMS[*]}"
echo "    保留网络=${KEEP_NETWORK}  清宿主存储=${PURGE_HOST_STORAGE}"

if [ "$FORCE" != "1" ]; then
  read -r -p "确认销毁以上 VM? [y/N] " ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "已取消"; exit 0 ;; esac
fi

for vm in "${VMS[@]}"; do
  echo "[+] 销毁 VM: ${vm}"
  virsh destroy "$vm" 2>/dev/null || true
  virsh undefine "$vm" --nvram 2>/dev/null || true
  rm -f "${DATA_DIR}/disks/${vm}.qcow2" "${DATA_DIR}/seeds/${vm}-seed.iso"
done

if [ "$KEEP_NETWORK" != "1" ]; then
  echo "[+] 销毁网络 ${NET_NAME}"
  virsh net-destroy "$NET_NAME" 2>/dev/null || true
  virsh net-undefine "$NET_NAME" 2>/dev/null || true
else
  echo "[=] 保留网络 ${NET_NAME}（KEEP_NETWORK=1）"
fi

if [ "$PURGE_HOST_STORAGE" = "1" ]; then
  ZFS_POOL="${ZFS_POOL:-tank}"
  echo "[!] 清理宿主存储：ZFS 池 ${ZFS_POOL} + MinIO 容器"
  if command -v zpool >/dev/null 2>&1; then zpool destroy "$ZFS_POOL" 2>/dev/null || true; fi
  if command -v docker >/dev/null 2>&1; then docker rm -f host-minio 2>/dev/null || true; fi
  [ -n "${HOST_ZFS_FILE:-}" ] && rm -f "${HOST_ZFS_FILE}" || true
else
  echo "[=] 保留宿主存储（ZFS / MinIO / 镜像缓存 / charts）"
fi

echo "[+] 完成：VM 已销毁"
