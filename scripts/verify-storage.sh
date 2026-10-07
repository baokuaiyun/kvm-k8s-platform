#!/usr/bin/env bash
# 存储与备份验收：SC / Longhorn / PVC / 快照类 / 备份时效
# 用法: bash scripts/verify-storage.sh
set -uo pipefail

SC="${STORAGE_CLASS:-app-storage}"
SNAPSHOT_CLASS="${SNAPSHOT_CLASS:-host-zfs-iscsi}"
BACKEND="${STORAGE_BACKEND:-host-zfs-iscsi}"
CSI_NS="${CSI_NAMESPACE:-democratic-csi}"
FAIL=0
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [WARN] $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=1; }

command -v kubectl >/dev/null 2>&1 || { echo "[!] 需要 kubectl"; exit 2; }
kubectl cluster-info >/dev/null 2>&1 || { echo "[!] 无法连接集群"; exit 2; }

echo "=== 1. StorageClass ==="
if kubectl get sc "$SC" >/dev/null 2>&1; then
  prov=$(kubectl get sc "$SC" -o jsonpath='{.provisioner}')
  reclaim=$(kubectl get sc "$SC" -o jsonpath='{.reclaimPolicy}')
  expand=$(kubectl get sc "$SC" -o jsonpath='{.allowVolumeExpansion}')
  ok "存在 $SC (provisioner=$prov reclaim=$reclaim expand=$expand)"
  [ "$reclaim" = "Retain" ] || bad "$SC reclaimPolicy=$reclaim（应为 Retain）"
  [ "$expand" = "true" ] || warn "$SC allowVolumeExpansion=$expand"
  def=$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}')
  echo "       默认 SC: ${def:-<无>}"
else
  bad "StorageClass $SC 不存在（make storage-class）"
fi

echo "=== 2. 快照类 ==="
if kubectl get volumesnapshotclass "$SNAPSHOT_CLASS" >/dev/null 2>&1; then
  ok "VolumeSnapshotClass $SNAPSHOT_CLASS 存在"
else
  warn "VolumeSnapshotClass $SNAPSHOT_CLASS 不存在（CNPG volumeSnapshot 备份不可用）"
fi

echo "=== 3. 存储后端 ($BACKEND) ==="
if [ "$BACKEND" = "longhorn" ]; then
  if kubectl -n longhorn-system get ds longhorn-manager >/dev/null 2>&1; then
    ok "longhorn-manager DaemonSet 存在"
    ready=$(kubectl -n longhorn-system get ds longhorn-manager -o jsonpath='{.status.numberReady}')
    desired=$(kubectl -n longhorn-system get ds longhorn-manager -o jsonpath='{.status.desiredNumberScheduled}')
    [ "${ready:-0}" = "${desired:-0}" ] || warn "longhorn-manager ready $ready/$desired"
    bt=$(kubectl -n longhorn-system get setting backup-target -o jsonpath='{.value}' 2>/dev/null || true)
    if [ -n "$bt" ]; then ok "backupTarget=$bt"; else bad "Longhorn backup-target 未配置（无异地备份）"; fi
    rc=$(kubectl -n longhorn-system get setting default-replica-count -o jsonpath='{.value}' 2>/dev/null || true)
    echo "       default-replica-count=${rc:-<未设置>}"
  else
    bad "Longhorn 未安装（make storage-longhorn）"
  fi
elif [ "$BACKEND" = "host-zfs-iscsi" ]; then
  if kubectl get csidriver host-zfs-iscsi >/dev/null 2>&1; then
    ok "CSIDriver host-zfs-iscsi 存在"
  else
    bad "CSIDriver host-zfs-iscsi 不存在（make csi-storage）"
  fi
  if kubectl -n "$CSI_NS" get pods >/dev/null 2>&1; then
    dr=$(kubectl -n "$CSI_NS" get pods -l app.kubernetes.io/name=democratic-csi --no-headers 2>/dev/null | grep -c Running || true)
    tot=$(kubectl -n "$CSI_NS" get pods -l app.kubernetes.io/name=democratic-csi --no-headers 2>/dev/null | wc -l || echo 0)
    [ "${dr:-0}" -gt 0 ] && ok "democratic-csi Pod Running ${dr}/${tot}" || warn "democratic-csi 无 Running Pod"
  else
    warn "命名空间 $CSI_NS 不存在"
  fi
  kubectl -n "$CSI_NS" get secret democratic-csi-driver-config >/dev/null 2>&1 \
    && ok "driver 配置 Secret democratic-csi-driver-config 存在" \
    || warn "driver 配置 Secret democratic-csi-driver-config 缺失"
  # 宿主 ZFS/portal 只能在宿主上核对，这里给提示
  echo "       [提示] 宿主核对: zpool status、targetcli /iscsi ls、MinIO 容器"
else
  echo "  [=] backend=$BACKEND，跳过后端细节检查"
fi

echo "=== 4. PVC 状态 ==="
pvc_out=$(kubectl get pvc -A --no-headers 2>/dev/null || true)
if [ -z "$pvc_out" ]; then
  warn "集群内暂无 PVC"
else
  total=$(printf '%s\n' "$pvc_out" | wc -l)
  unbound=$(printf '%s\n' "$pvc_out" | awk '$3!="Bound" && $3!="Terminating"{c++} END{print c+0}')
  echo "$pvc_out" | awk '{printf "  %-18s %-28s %-8s %s\n",$1,$2,$3,$4}'
  [ "$unbound" -eq 0 ] && ok "$total 个 PVC 均为 Bound" || bad "$unbound/$total 个 PVC 非 Bound"
fi

echo "=== 5. 备份时效 ==="
# CNPG 最近备份
cnpg=$(kubectl get backup -A --no-headers 2>/dev/null | awk '$3=="completed"{print $2,$3,$5}' | tail -3 || true)
[ -n "$cnpg" ] && { echo "  CNPG 最近备份:"; echo "$cnpg" | sed 's/^/    /'; } || warn "无已完成的 CNPG Backup"
# Velero
if command -v velero >/dev/null 2>&1; then
  velero backup get 2>/dev/null | head -5 | sed 's/^/    /' || warn "velero backup get 失败"
else
  warn "未安装 velero CLI，无法核对 Velero 备份（见 scripts/velero-install.sh）"
fi

echo ""
[ "$FAIL" -eq 0 ] && echo "[+] 存储验收通过（警告项请逐条确认）" || echo "[!] 存储验收存在失败项"
exit "$FAIL"
