#!/usr/bin/env bash
# 安装宿主 ZFS+iSCSI 云盘 CSI（democratic-csi），模拟阿里云云盘/计算分离。
# 前置：已执行 host-storage.sh（ZFS 池 + iSCSI target + SSH 授权），且集群 kubeconfig 可用。
# 幂等：helm upgrade --install。
# 用法: bash storage/host-zfs-iscsi/deploy-csi.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"

# 国内直连（避免宿主代理导致 github/helm 拉取失败）
if [ "${BYPASS_PROXY:-1}" = "1" ]; then
  export no_proxy='*' NO_PROXY='*'
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
fi

HARBOR_HOST="${HARBOR_HOST:-harbor.test.baokuaiyun.com}"
HARBOR_PROJECT="${HARBOR_PROJECT:-baokuaiyun}"
CSI_NAMESPACE="${CSI_NAMESPACE:-democratic-csi}"
ZFS_POOL="${ZFS_POOL:-tank}"
ZFS_COMPRESSION="${ZFS_COMPRESSION:-zstd}"
SSH_KEY="${HOST_CSI_SSH_KEY:-/etc/k8s-host-csi/id_ed25519}"
TARGET_PORTAL="${NET_GATEWAY:-192.168.124.1}"
TARGET_IQN="${ISCSI_TARGET_IQN:-iqn.2026-01.com.baokuaiyun:k8s}"
CSI_TAG="${DEMOCRATIC_CSI_VERSION:-0.15.1}"
# chart 解析：优先显式变量，其次本地缓存，最后上游仓库（避免依赖 github 可达）
if [ -n "${HELM_DEMOCRATIC_CSI:-}" ]; then
  CHART="$HELM_DEMOCRATIC_CSI"
else
  CHART="$(ls "${HELM_CHARTS_DIR:-/data/kvm/charts}"/democratic-csi-*.tgz 2>/dev/null | head -1)"
  [ -n "$CHART" ] || CHART="democratic-csi/democratic-csi"
fi

log()  { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[x] $*" >&2; exit 1; }

command -v helm >/dev/null 2>&1 || die "需要 helm"
command -v kubectl >/dev/null 2>&1 || die "需要 kubectl"
[ -f "$SSH_KEY" ] || die "缺少 CSI SSH 密钥 $SSH_KEY（先执行 make host-storage）"

# 本域镜像 tag：应用镜像版本（与 chart 版本是两条流）
CSI_IMAGE_TAG="${DEMOCRATIC_CSI_IMAGE_TAG:-${CSI_IMAGE_TAG:-v1.9.5}}"
# snapshot-controller：若集群已有，可 ENABLE_SNAPSHOT_CONTROLLER=false
SNAP_CTRL="${ENABLE_SNAPSHOT_CONTROLLER:-false}"

# 渲染 values
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
KEY_INDENTED="$(sed 's/^/        /' "$SSH_KEY")"
export KEY_INDENTED
sed \
  -e "s|__HARBOR_HOST__|${HARBOR_HOST}|g" \
  -e "s|__HARBOR_PROJECT__|${HARBOR_PROJECT}|g" \
  -e "s|__CSI_TAG__|${CSI_IMAGE_TAG}|g" \
  -e "s|__SNAPSHOT_CONTROLLER__|${SNAP_CTRL}|g" \
  -e "s|__INSTANCE_ID__|${CSI_NAMESPACE}|g" \
  -e "s|__ZFS_DATASET__|${ZFS_POOL}/k8s|g" \
  -e "s|__ZFS_SNAPSHOT_DATASET__|${ZFS_POOL}/k8s-snapshots|g" \
  -e "s|__ZFS_COMPRESSION__|${ZFS_COMPRESSION}|g" \
  -e "s|__TARGET_PORTAL__|${TARGET_PORTAL}|g" \
  -e "s|__TARGET_IQN__|${TARGET_IQN}|g" \
  -e "s|__ISCSI_IQN_PREFIX__|${ISCSI_IQN_PREFIX:-iqn.2026-01.com.baokuaiyun}|g" \
  -e "s|__SSH_HOST__|${TARGET_PORTAL}|g" \
  -e "s|__SSH_USER__|root|g" \
  "${DIR}/values.yaml.tmpl" > "$TMP"

# 插入 SSH 私钥（多行，用 awk 替换占位行）
awk -v key="$KEY_INDENTED" '{ if ($0=="__SSH_PRIVATE_KEY__") print key; else print }' "$TMP" > "$TMP.2"
mv "$TMP.2" "$TMP"

log "安装 democratic-csi -> ns ${CSI_NAMESPACE}（chart=${CHART}, image=${HARBOR_HOST}/${HARBOR_PROJECT}/democratic-csi:${CSI_IMAGE_TAG}）"
if [ ! -f "$CHART" ]; then
  helm repo add democratic-csi https://democratic-csi.github.io/charts/ >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true
fi

# 本地 tgz 不能带 --version；仅远程 chart 指定版本
VER_ARG=()
[ -f "$CHART" ] || VER_ARG=(--version "$CSI_TAG")

helm upgrade --install democratic-csi "$CHART" \
  --namespace "$CSI_NAMESPACE" --create-namespace \
  "${VER_ARG[@]}" \
  -f "$TMP" \
  --wait --timeout 5m || {
    warn "带 --wait 安装失败，重试不带 --wait（便于查看事件）"
    helm upgrade --install democratic-csi "$CHART" -n "$CSI_NAMESPACE" "${VER_ARG[@]}" -f "$TMP"
  }

log "应用 StorageClass / VolumeSnapshotClass（app-storage）"
# 快照 CRD/控制器（VolumeSnapshotClass 依赖 snapshot.storage.k8s.io CRD）
SNAP_CHART="$(ls "${HELM_CHARTS_DIR:-/data/kvm/charts}"/snapshot-controller-*.tgz 2>/dev/null | head -1)"
if [ -n "$SNAP_CHART" ] && ! kubectl get crd volumesnapshots.snapshot.storage.k8s.io >/dev/null 2>&1; then
  log "安装 snapshot-controller（CRD + controller）"
  helm upgrade --install snapshot-controller "$SNAP_CHART" -n kube-system \
    --set controller.replicaCount=1 --set controller.image.tag=v8.2.1 \
    --set validatingWebhook.enabled=false || warn "snapshot-controller 安装失败（快照类将不可用）"
fi
STORAGE_BACKEND=host-zfs-iscsi bash "${ROOT}/storage/apply.sh"

log "CSI 就绪。验证: kubectl get csidriver,sc; kubectl get pods -n ${CSI_NAMESPACE}"
