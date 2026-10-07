#!/usr/bin/env bash
# 预载 democratic-csi 所需镜像到节点 containerd（离线/代理受限环境用）
# 源：国内镜像；目标 ref 保持 chart 默认（或 Harbor scheme C 主镜像），IfNotPresent 命中。
# 用法: bash storage/host-zfs-iscsi/preload-images.sh [节点IP ...]
set -euo pipefail

HARBOR_HOST="${HARBOR_HOST:-harbor.test.baokuaiyun.com}"
HARBOR_PROJECT="${HARBOR_PROJECT:-baokuaiyun}"
IMAGE_TAG="${DEMOCRATIC_CSI_IMAGE_TAG:-v1.9.5}"
MIRROR_DOCKER="${MIRROR_DOCKER:-docker.m.daocloud.io}"
MIRROR_GHCR="${MIRROR_GHCR:-ghcr.nju.edu.cn}"
MIRROR_K8S="${MIRROR_K8S:-registry.cn-hangzhou.aliyuncs.com/google_containers}"

NODES=("$@")
if [ "${#NODES[@]}" -eq 0 ]; then
  i=0; for ip in ${CP_IPS:-192.168.124.10}; do [ "$i" -ge "${CP_INIT_COUNT:-1}" ] && break; NODES+=("$ip"); i=$((i+1)); done
fi
[ "${#NODES[@]}" -gt 0 ] || { echo "[!] 无目标节点"; exit 1; }

# "源镜像 目标ref"
IMAGES=$(cat <<EOF
${MIRROR_DOCKER}/democraticcsi/democratic-csi:${IMAGE_TAG} ${HARBOR_HOST}/${HARBOR_PROJECT}/democratic-csi:${IMAGE_TAG}
${MIRROR_DOCKER}/library/busybox:1.37.0 docker.io/busybox:1.37.0
${MIRROR_GHCR}/democratic-csi/csi-grpc-proxy:v0.5.7 ghcr.io/democratic-csi/csi-grpc-proxy:v0.5.7
${MIRROR_K8S}/csi-attacher:v4.4.0 registry.k8s.io/sig-storage/csi-attacher:v4.4.0
${MIRROR_K8S}/csi-provisioner:v3.6.0 registry.k8s.io/sig-storage/csi-provisioner:v3.6.0
${MIRROR_K8S}/csi-resizer:v1.9.0 registry.k8s.io/sig-storage/csi-resizer:v1.9.0
${MIRROR_K8S}/csi-snapshotter:v8.2.1 registry.k8s.io/sig-storage/csi-snapshotter:v8.2.1
${MIRROR_K8S}/csi-node-driver-registrar:v2.9.0 registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.9.0
${MIRROR_K8S}/snapshot-controller:v8.2.1 registry.k8s.io/sig-storage/snapshot-controller:v8.2.1
EOF
)

command -v skopeo >/dev/null 2>&1 || { echo "[!] 需要 skopeo"; exit 1; }
if [ "${BYPASS_PROXY:-1}" = "1" ]; then
  export no_proxy='*' NO_PROXY='*'; unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
fi

REMOTE_DIR="/var/lib/k8s-images-csi"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "[+] 拉取并导出 ${IMAGES//$'\n'/ }" >/dev/null
mapfile -t LINES < <(printf '%s\n' "$IMAGES" | grep -v '^$')
echo "[+] 准备 ${#LINES[@]} 个镜像"
TARS=()
for line in "${LINES[@]}"; do
  src="${line%% *}"; dst="${line##* }"
  tar="${TMP}/$(echo "$dst" | tr '/:' '__').tar"
  echo "[+] ${src} -> ${dst}"
  if skopeo copy --override-os linux --override-arch amd64 "docker://${src}" "docker-archive:${tar}:${dst}" >/dev/null 2>&1; then
    TARS+=("$tar")
  else
    echo "[!] 拉取失败: ${src}（跳过）"
  fi
done
[ "${#TARS[@]}" -gt 0 ] || { echo "[!] 无镜像可导入"; exit 1; }

for ip in "${NODES[@]}"; do
  echo "[+] 导入到节点 ${ip} ..."
  ssh -o StrictHostKeyChecking=no root@"$ip" "rm -rf ${REMOTE_DIR}; mkdir -p ${REMOTE_DIR}"
  scp -o StrictHostKeyChecking=no -q "${TARS[@]}" root@"$ip":"${REMOTE_DIR}"/
  for t in "${TARS[@]}"; do
    ssh -o StrictHostKeyChecking=no root@"$ip" "ctr -n k8s.io images import ${REMOTE_DIR}/$(basename "$t")" >/dev/null
  done
  ssh -o StrictHostKeyChecking=no root@"$ip" "rm -rf ${REMOTE_DIR}"
done
echo "[+] CSI 镜像预载完成"
