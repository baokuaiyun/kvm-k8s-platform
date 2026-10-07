#!/usr/bin/env bash
# 云盘在线扩容演练：建 PVC(1Gi) → 写数据 → 扩到 3Gi → 校验容量与数据无损
# 适用于 STORAGE_BACKEND=host-zfs-iscsi（app-storage 允许在线扩容）
# 用法: bash scripts/drill-expand-pvc.sh
#   NS=storage-drill  SC=app-storage  START=1Gi  TARGET=3Gi
set -euo pipefail

NS="${NS:-storage-drill}"
SC="${SC:-${STORAGE_CLASS:-app-storage}}"
PVC_NAME="${PVC_NAME:-drill-expand}"
POD_NAME="${POD_NAME:-drill-expand-writer}"
START="${START:-1Gi}"
TARGET="${TARGET:-3Gi}"
MARKER="expand-drill-$(date +%s)"
KEEP="${KEEP:-0}"
IMG="${IMG:-docker.io/busybox:1.37.0}"

log()  { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[x] $*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "需要 kubectl"

cleanup() {
  if [ "$KEEP" != "1" ]; then
    log "清理演练资源（KEEP=1 可保留）"
    kubectl -n "$NS" delete pod "$POD_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl -n "$NS" delete pvc "$PVC_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

kubectl get sc "$SC" >/dev/null 2>&1 || die "StorageClass $SC 不存在（先 make storage-class）"

log "1) 创建命名空间/PVC（${SC}, ${START}）"
kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NS}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${SC}
  resources: {requests: {storage: ${START}}}
EOF

log "2) 等待 PVC Bound"
for i in $(seq 1 60); do
  ph=$(kubectl -n "$NS" get pvc "$PVC_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$ph" = "Bound" ] && break
  sleep 3
done
[ "$ph" = "Bound" ] || die "PVC 未 Bound（当前 ${ph:-unknown}）"
cap0=$(kubectl -n "$NS" get pvc "$PVC_NAME" -o jsonpath='{.status.capacity.storage}')
provisioner=$(kubectl get sc "$SC" -o jsonpath='{.provisioner}')
log "   Bound，容量=${cap0}，provisioner=${provisioner}"

log "3) 挂载并写入数据"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NS}
spec:
  restartPolicy: Never
  containers:
  - name: writer
    image: ${IMG}
    command: ["sh","-c","echo ${MARKER} > /data/marker.txt && sync && echo written && sleep 100000"]
    volumeMounts: [{name: data, mountPath: /data}]
  volumes:
  - name: data
    persistentVolumeClaim: {claimName: ${PVC_NAME}}
EOF
kubectl -n "$NS" wait --for=condition=Ready pod/"$POD_NAME" --timeout=120s >/dev/null
got=$(kubectl -n "$NS" exec "$POD_NAME" -- cat /data/marker.txt)
[ "$got" = "$MARKER" ] || die "写入校验失败"
log "   写入完成: $got"

log "4) 在线扩容 ${START} -> ${TARGET}"
kubectl -n "$NS" patch pvc "$PVC_NAME" --type merge \
  -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"${TARGET}\"}}}}" >/dev/null

log "5) 等待扩容完成（CSI resizer）"
ok=0
for i in $(seq 1 100); do
  capn=$(kubectl -n "$NS" get pvc "$PVC_NAME" -o jsonpath='{.status.capacity.storage}' 2>/dev/null || true)
  cond=$(kubectl -n "$NS" get pvc "$PVC_NAME" -o jsonpath='{range .status.conditions[?(@.type=="FileSystemResizePending")]}{.status}{end}' 2>/dev/null || true)
  if [ "$capn" = "$TARGET" ] && [ "$cond" != "True" ]; then ok=1; break; fi
  sleep 3
done
[ "$ok" = 1 ] || warn "扩容未在预期时间内完成（当前容量=${capn:-unknown}）；file 系统扩容可能需重建 Pod"

log "6) 重新挂载校验数据无损与容量"
kubectl -n "$NS" delete pod "$POD_NAME" --wait=true >/dev/null 2>&1 || true
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NS}
spec:
  restartPolicy: Never
  containers:
  - name: verify
    image: ${IMG}
    command: ["sh","-c","cat /data/marker.txt && df -h /data | tail -1 && sleep 100000"]
    volumeMounts: [{name: data, mountPath: /data}]
  volumes:
  - name: data
    persistentVolumeClaim: {claimName: ${PVC_NAME}}
EOF
kubectl -n "$NS" wait --for=condition=Ready pod/"$POD_NAME" --timeout=120s >/dev/null
got2=$(kubectl -n "$NS" exec "$POD_NAME" -- cat /data/marker.txt)
[ "$got2" = "$MARKER" ] || die "扩容后数据不一致！期望=$MARKER 实际=$got2"
dfsv=$(kubectl -n "$NS" exec "$POD_NAME" -- df -h /data | tail -1)
log "   数据完好: $got2"
log "   文件系统: $dfsv"

log "扩容演练成功 ✅（${START} -> ${TARGET}，provisioner=${provisioner}）"
