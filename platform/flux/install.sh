#!/usr/bin/env bash
# 安装/升级 Flux Operator（Helm，对齐 D2 官方）
#   - chart 从镜像源拉取后推入 Harbor OCI；operator 镜像也从镜像源同步入 Harbor
#   - 注入 Harbor 自签 CA（供 operator 拉取 Harbor OCI 制品）
#   - helm upgrade --install ... --take-ownership（就地收编清单方式安装的旧资源）
# 用法: bash platform/flux/install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

HARBOR_HOST="${HARBOR_HOST:-harbor.test.baokuaiyun.com}"
HARBOR_PROJECT="${HARBOR_PROJECT:-baokuaiyun}"
: "${HARBOR_ROBOT_PASS:?}"
# robot 用户名在本地用 PROJECT 拼接，避免 $ 经 make/shell 多级展开被吞
ROBOT_USER="robot\$${HARBOR_PROJECT}+pushpull"
NS="${FLUX_NS:-flux-system}"
VER="${FLUX_OPERATOR_VERSION:-0.61.0}"
MIRROR="${GHCR_MIRROR:-ghcr.dockerproxy.net}"
CHART_REF="oci://${MIRROR}/controlplaneio-fluxcd/charts/flux-operator"
IMG_REPO="${HARBOR_HOST}/${HARBOR_PROJECT}/fluxcd/flux-operator"
OCI_REPO="oci://${HARBOR_HOST}/${HARBOR_PROJECT}"
CHART_DIR="${HELM_CHARTS_DIR:-/data/kvm/charts}"
CHART_TGZ="${CHART_DIR}/flux-operator-${VER}.tgz"
VALUES="${ROOT}/platform/flux/values.yaml"

command -v helm >/dev/null || { echo "[!] 需要 helm"; exit 1; }
command -v kubectl >/dev/null || { echo "[!] 需要 kubectl"; exit 1; }

# 海外源直连（绕过本机代理）
no_proxy_env() { env no_proxy='*' NO_PROXY='*' http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= "$@"; }

echo "[+] 命名空间 ${NS}"
kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# 1) Harbor CA（优先用平台网关通配证书的 CA；不存在则跳过）
if [ -f /tmp/harbor-ca.crt ]; then
  kubectl -n "$NS" create configmap harbor-ca --from-file=ca.crt=/tmp/harbor-ca.crt \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null && echo "    harbor-ca configmap ok"
else
  echo "[=] 未找到 /tmp/harbor-ca.crt，跳过 CA 注入（自签环境请先生成）"
fi

# 2) Harbor 拉取凭据 + cosign 公钥（fleet 验签）
kubectl -n "$NS" create secret docker-registry harbor-auth \
  --docker-server="$HARBOR_HOST" --docker-username="$ROBOT_USER" --docker-password="$HARBOR_ROBOT_PASS" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null && echo "    harbor-auth secret ok"
if [ -f "${COSIGN_PUB:-/root/cosign.pub}" ]; then
  kubectl -n "$NS" create secret generic cosign-pub --from-file=cosign.pub="${COSIGN_PUB:-/root/cosign.pub}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null && echo "    cosign-pub secret ok"
fi

# 3) operator 镜像同步入 Harbor
if skopeo inspect --tls-verify=false --creds "${ROBOT_USER}:${HARBOR_ROBOT_PASS}" \
     "docker://${IMG_REPO}:v${VER}" >/dev/null 2>&1; then
  echo "[=] 镜像已存在: ${IMG_REPO}:v${VER}"
else
  echo "[+] 同步 operator 镜像 -> ${IMG_REPO}:v${VER}"
  no_proxy_env skopeo copy --dest-tls-verify=false \
    --dest-creds "${ROBOT_USER}:${HARBOR_ROBOT_PASS}" \
    "docker://${MIRROR}/controlplaneio-fluxcd/flux-operator:v${VER}" \
    "docker://${IMG_REPO}:v${VER}"
fi

# 4) chart 入 Harbor OCI（本地有则用，否则从镜像源拉）
mkdir -p "$CHART_DIR"
if [ ! -f "$CHART_TGZ" ]; then
  echo "[+] 拉取 chart ${CHART_REF}:${VER}"
  no_proxy_env helm pull "$CHART_REF" --version "$VER" -d "$CHART_DIR"
fi
echo "[+] 推送 chart 到 ${OCI_REPO}"
no_proxy_env helm push "$CHART_TGZ" "$OCI_REPO" >/dev/null
echo "    pushed flux-operator:${VER}"

# 5) Helm 安装/升级（--take-ownership 收编旧资源）
echo "[+] helm upgrade --install flux-operator（--take-ownership）"
no_proxy_env helm upgrade --install flux-operator "${OCI_REPO}/flux-operator" \
  --version "$VER" -n "$NS" --take-ownership -f "$VALUES"

echo "[+] 完成。查看: helm -n ${NS} list; kubectl -n ${NS} get deploy,pods"
