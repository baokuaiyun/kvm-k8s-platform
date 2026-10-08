#!/usr/bin/env bash
# 存储与备份验收：SC / Longhorn / PVC / 快照类 / 备份时效 / 云盘使用情况
# 用法: bash scripts/verify-storage.sh
# 命令默认逐条回显（方便讲学/证据留痕）；KUBECTL_VERIFY_ECHO=0 可静默。教程: docs/storage-verification.md
set -uo pipefail

SC="${STORAGE_CLASS:-app-storage}"
SNAPSHOT_CLASS="${SNAPSHOT_CLASS:-host-zfs-iscsi}"
BACKEND="${STORAGE_BACKEND:-host-zfs-iscsi}"
CSI_NS="${CSI_NAMESPACE:-democratic-csi}"
ZFS_POOL="${ZFS_POOL:-tank}"
ZFS_DATASET="${ZFS_DATASET:-$ZFS_POOL/k8s}"
PROM_NS="${ALERT_NAMESPACE:-monitoring}"
PROM_SVC="${PROM_SVC:-monitoring-kube-prometheus-prometheus}"
FAIL=0
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [WARN] $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=1; }
# 命令回显：默认开启，方便讲学与证据留痕（KUBECTL_VERIFY_ECHO=0 可静默）
ECHO_CMD="${KUBECTL_VERIFY_ECHO:-1}"
show() { [ "$ECHO_CMD" = "1" ] && echo "  \$ $*"; return 0; }

command -v kubectl >/dev/null 2>&1 || { echo "[!] 需要 kubectl"; exit 2; }
kubectl cluster-info >/dev/null 2>&1 || { echo "[!] 无法连接集群"; exit 2; }

echo "=== 1. StorageClass ==="
show "kubectl get sc $SC -o jsonpath='{.provisioner}'"
if kubectl get sc "$SC" >/dev/null 2>&1; then
  prov=$(kubectl get sc "$SC" -o jsonpath='{.provisioner}')
  reclaim=$(kubectl get sc "$SC" -o jsonpath='{.reclaimPolicy}')
  expand=$(kubectl get sc "$SC" -o jsonpath='{.allowVolumeExpansion}')
  ok "存在 $SC (provisioner=$prov reclaim=$reclaim expand=$expand)"
  [ "$reclaim" = "Retain" ] || bad "$SC reclaimPolicy=$reclaim（应为 Retain）"
  [ "$expand" = "true" ] || warn "$SC allowVolumeExpansion=$expand"
  show "kubectl get sc (默认类注解 is-default-class)"
  def=$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}')
  echo "       默认 SC: ${def:-<无>}"
else
  bad "StorageClass $SC 不存在（make storage-class）"
fi

echo "=== 2. 快照类 ==="
show "kubectl get volumesnapshotclass $SNAPSHOT_CLASS"
if kubectl get volumesnapshotclass "$SNAPSHOT_CLASS" >/dev/null 2>&1; then
  ok "VolumeSnapshotClass $SNAPSHOT_CLASS 存在"
else
  warn "VolumeSnapshotClass $SNAPSHOT_CLASS 不存在（CNPG volumeSnapshot 备份不可用）"
fi

echo "=== 3. 存储后端 ($BACKEND) ==="
if [ "$BACKEND" = "longhorn" ]; then
  show "kubectl -n longhorn-system get ds longhorn-manager"
  if kubectl -n longhorn-system get ds longhorn-manager >/dev/null 2>&1; then
    ok "longhorn-manager DaemonSet 存在"
    ready=$(kubectl -n longhorn-system get ds longhorn-manager -o jsonpath='{.status.numberReady}')
    desired=$(kubectl -n longhorn-system get ds longhorn-manager -o jsonpath='{.status.desiredNumberScheduled}')
    [ "${ready:-0}" = "${desired:-0}" ] || warn "longhorn-manager ready $ready/$desired"
    show "kubectl -n longhorn-system get setting backup-target -o jsonpath='{.value}'"
    bt=$(kubectl -n longhorn-system get setting backup-target -o jsonpath='{.value}' 2>/dev/null || true)
    if [ -n "$bt" ]; then ok "backupTarget=$bt"; else bad "Longhorn backup-target 未配置（无异地备份）"; fi
    rc=$(kubectl -n longhorn-system get setting default-replica-count -o jsonpath='{.value}' 2>/dev/null || true)
    echo "       default-replica-count=${rc:-<未设置>}"
  else
    bad "Longhorn 未安装（make storage-longhorn）"
  fi
elif [ "$BACKEND" = "host-zfs-iscsi" ]; then
  show "kubectl get csidriver host-zfs-iscsi"
  if kubectl get csidriver host-zfs-iscsi >/dev/null 2>&1; then
    ok "CSIDriver host-zfs-iscsi 存在"
  else
    bad "CSIDriver host-zfs-iscsi 不存在（make csi-storage）"
  fi
  show "kubectl -n $CSI_NS get pods -l app.kubernetes.io/name=democratic-csi"
  if kubectl -n "$CSI_NS" get pods >/dev/null 2>&1; then
    dr=$(kubectl -n "$CSI_NS" get pods -l app.kubernetes.io/name=democratic-csi --no-headers 2>/dev/null | grep -c Running || true)
    tot=$(kubectl -n "$CSI_NS" get pods -l app.kubernetes.io/name=democratic-csi --no-headers 2>/dev/null | wc -l || echo 0)
    [ "${dr:-0}" -gt 0 ] && ok "democratic-csi Pod Running ${dr}/${tot}" || warn "democratic-csi 无 Running Pod"
  else
    warn "命名空间 $CSI_NS 不存在"
  fi
  show "kubectl -n $CSI_NS get secret democratic-csi-driver-config"
  kubectl -n "$CSI_NS" get secret democratic-csi-driver-config >/dev/null 2>&1 \
    && ok "driver 配置 Secret democratic-csi-driver-config 存在" \
    || warn "driver 配置 Secret democratic-csi-driver-config 缺失"
  # 宿主 ZFS/portal 只能在宿主上核对，这里给提示
  echo "       [提示] 宿主核对: zpool status、targetcli /iscsi ls、MinIO 容器"
else
  echo "  [=] backend=$BACKEND，跳过后端细节检查"
fi

echo "=== 4. PVC 状态 ==="
show "kubectl get pvc -A"
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
show "kubectl get backup -A"
cnpg=$(kubectl get backup -A --no-headers 2>/dev/null | awk '$3=="completed"{print $2,$3,$5}' | tail -3 || true)
[ -n "$cnpg" ] && { echo "  CNPG 最近备份:"; echo "$cnpg" | sed 's/^/    /'; } || warn "无已完成的 CNPG Backup"
# Velero
if command -v velero >/dev/null 2>&1; then
  show "velero backup get"
  velero backup get 2>/dev/null | head -5 | sed 's/^/    /' || warn "velero backup get 失败"
else
  warn "未安装 velero CLI，无法核对 Velero 备份（见 scripts/velero-install.sh）"
fi

echo "=== 6. 云盘使用情况 ==="
# 6a. 集群侧：PVC 申请/容量
show "kubectl get pvc -A -o custom-columns=NS,NAME,SC,REQ,CAP"
pvc_usage=$(kubectl get pvc -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SC:.spec.storageClassName,REQ:.spec.resources.requests.storage,CAP:.status.capacity.storage' 2>/dev/null || true)
if [ -n "$pvc_usage" ]; then
  printf '%s\n' "$pvc_usage" | sed 's/^/  /'
else
  warn "无 PVC 或无读取权限"
fi

# 6b. 实际使用率（Prometheus，best-effort）
if command -v jq >/dev/null 2>&1 && kubectl -n "$PROM_NS" get svc "$PROM_SVC" >/dev/null 2>&1; then
  q='kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes'
  enc=$(jq -rn --arg q "$q" '$q|@uri')
  show "Prometheus: $q（$PROM_NS/$PROM_SVC）"
  res=$(kubectl -n "$PROM_NS" get --raw --request-timeout=10s \
    "/api/v1/namespaces/${PROM_NS}/services/http:${PROM_SVC}:9090/proxy/api/v1/query?query=${enc}" 2>/dev/null || true)
  usage=$(printf '%s' "$res" | jq -r '.data.result[]? | [.metric.namespace, .metric.persistentvolumeclaim, (((.value[1]|tonumber)*100|floor)|tostring)+"%"] | @tsv' 2>/dev/null | sort || true)
  if [ -n "$usage" ]; then
    printf '  %-16s %-34s %s\n' "NS" "PVC" "USED%"
    printf '%s\n' "$usage" | awk -F'\t' '{printf "  %-16s %-34s %s\n",$1,$2,$3}'
    high=$(printf '%s\n' "$usage" | awk -F'\t' '($3+0)>=85' | wc -l | tr -d ' ')
    [ "${high:-0}" -gt 0 ] && warn "$high 个 PVC 使用率 ≥85%（告警 PVCNearlyFull）" || ok "各 PVC 使用率 <85%"
  else
    echo "       [=] 无卷用量数据（监控未采集到）"
  fi
else
  echo "       [提示] 实际使用率指标: kubelet_volume_stats_used_bytes/capacity_bytes（告警 PVCNearlyFull>85%、PVCCriticalFull>95%）"
fi

# 6c. 宿主 ZFS 云盘层（drill）
if command -v zpool >/dev/null 2>&1 && zpool list "$ZFS_POOL" >/dev/null 2>&1; then
  show "zpool list $ZFS_POOL"
  zpool list -o name,size,alloc,free,cap,health "$ZFS_POOL" | sed 's/^/  /'
  pcap=$(zpool list -H -o cap "$ZFS_POOL" 2>/dev/null | tr -d '%')
  [ "${pcap:-0}" -lt 80 ] && ok "ZFS 池 $ZFS_POOL 已用 ${pcap}%" || warn "ZFS 池 $ZFS_POOL 已用 ${pcap}%（≥80%）"
  show "zfs list -o name,used,avail,refer,quota -r $ZFS_DATASET"
  zfs list -o name,used,avail,refer,quota -r "$ZFS_DATASET" 2>/dev/null | sed 's/^/  /' || warn "数据集 $ZFS_DATASET 不存在（make host-storage）"
elif command -v zpool >/dev/null 2>&1; then
  warn "未发现 ZFS 池 $ZFS_POOL（drill 未建池？make host-storage）"
else
  echo "       [=] 无 zpool（prod/非宿主），云盘用量见云控制台或 CSI 指标"
fi

echo ""
[ "$FAIL" -eq 0 ] && echo "[+] 存储验收通过（警告项请逐条确认）" || echo "[!] 存储验收存在失败项"
exit "$FAIL"
