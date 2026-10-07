#!/usr/bin/env bash
# 列出宿主 ZFS 上的 K8s 卷（zvol），用于“删集群/重建”后核对数据是否仍在宿主。
# 云盘方案：集群删除不删宿主 zvol；重建后数据通过备份恢复或用本清单人工核对/导出。
# 用法: bash scripts/list-orphan-volumes.sh
set -euo pipefail

ZFS_POOL="${ZFS_POOL:-tank}"
DATASET="${ZFS_POOL}/k8s"

command -v zfs >/dev/null 2>&1 || { echo "[!] 宿主未安装 ZFS（zfsutils-linux）"; exit 1; }
zfs list "$DATASET" >/dev/null 2>&1 || { echo "[=] 数据集不存在: ${DATASET}（尚无卷或未建池）"; exit 0; }

echo "=== 宿主 ZFS 卷（${DATASET}）==="
zfs list -t volume -r "$DATASET" -o name,volsize,used,creation 2>/dev/null || true

echo ""
echo "=== 快照 ==="
zfs list -t snapshot -r "$DATASET" -o name,used,creation 2>/dev/null || true

echo ""
echo "提示：删除/重建集群不会删除以上卷；恢复路径见 docs/cloud-disk-data-solution.md §8。"
