#!/usr/bin/env bash
# 宿主机准备镜像：从 ACR（或上游）下载并重命名成本域镜像，导出为 tar
# 供 kubernetes/scripts/load-images.sh 分发导入各节点
#
# 用法: prepare-acr-images.sh [Tier0,Tier1,...]
#   TIERS     环境变量或第一个参数，默认 Tier0,Tier1
#   FORCE=1   重新拉取已存在的 tar
# 依赖: skopeo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIST="${LIST:-${SCRIPT_DIR}/acr-images-list.txt}"

: "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY 未设置（见 variables.mk/acr.env）}"
ACR_AUTH_MODE="${ACR_AUTH_MODE:-password}"
ACR_SOURCE="${ACR_SOURCE:-auto}"
# 仅非 upstream 模式才需要 ACR 参数
if [ "${ACR_SOURCE}" != "upstream" ]; then
  : "${ACR_REGISTRY:?ACR_REGISTRY 未设置}"
  : "${ACR_NAMESPACE:?ACR_NAMESPACE 未设置}"
fi

# 国内镜像直连（避免环境代理导致国外站点 TLS 失败）
if [ "${BYPASS_PROXY:-1}" = "1" ]; then
  export no_proxy='*' NO_PROXY='*'
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
fi

# 上游 -> 国内镜像重写
MIRROR_K8S="${MIRROR_K8S:-registry.cn-hangzhou.aliyuncs.com/google_containers}"
MIRROR_GHCR="${MIRROR_GHCR:-ghcr.nju.edu.cn}"
MIRROR_DOCKER="${MIRROR_DOCKER:-docker.1ms.run}"
MIRROR_QUAY="${MIRROR_QUAY:-quay.m.daocloud.io}"
mirror_src() {
  local img="$1" rest
  case "$img" in
    registry.k8s.io/*) rest="${img#registry.k8s.io/}"; rest="${rest##*/}"; echo "${MIRROR_K8S}/${rest}" ;;
    ghcr.io/*)         rest="${img#ghcr.io/}";         echo "${MIRROR_GHCR}/${rest}" ;;
    docker.io/*)       rest="${img#docker.io/}";       echo "${MIRROR_DOCKER}/${rest}" ;;
    quay.io/*)         rest="${img#quay.io/}";         echo "${MIRROR_QUAY}/${rest}" ;;
    *)                 echo "$img" ;;
  esac
}
IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-/data/kvm/images/registry}"
TIERS="${1:-${TIERS:-Tier0,Tier1}}"
FORCE="${FORCE:-0}"

command -v skopeo >/dev/null 2>&1 || { echo "[!] 需要 skopeo: apt-get install -y skopeo"; exit 1; }
mkdir -p "${IMAGE_CACHE_DIR}"
MANIFEST="${IMAGE_CACHE_DIR}/manifest.tsv"
: > "${MANIFEST}"

# 组装源凭据（仅 ACR 用）
SRC_CREDS=""
case "${ACR_AUTH_MODE}" in
  password) SRC_CREDS="${ACR_USER:-}:${ACR_PASS:-}" ;;
  ak)       SRC_CREDS="${ALIYUN_ACCESS_KEY:-}:${ALIYUN_SECRET_KEY:-}" ;;
  none)     SRC_CREDS="" ;;
  *)        echo "[!] 未知 ACR_AUTH_MODE: ${ACR_AUTH_MODE}"; exit 1 ;;
esac
CREDS_FLAG=()
[ -n "${SRC_CREDS}" ] && CREDS_FLAG=(--src-creds "${SRC_CREDS}")

tier_match() {
  local t="$1" IFS=','
  for x in ${TIERS}; do [ "$x" = "$t" ] && return 0; done
  return 1
}

ok=0; skip=0; fail=0

while read -r src dst tier acr_src; do
  [[ "$src" =~ ^#.*$ || -z "$src" ]] && continue
  [ -z "${dst:-}" ] && continue
  [ -z "${tier:-}" ] && tier="Tier2"

  tier_match "$tier" || continue

  tag="${src##*:}"
  target="${IMAGE_REPOSITORY}/${dst}:${tag}"
  acr_repo="${acr_src:-${ACR_NAMESPACE}/${dst}}"
  acr_ref="${ACR_REGISTRY}/${acr_repo}:${tag}"
  safe=$(echo "${target}" | tr '/:' '__')
  tar="${IMAGE_CACHE_DIR}/${safe}.tar"

  if [ -f "$tar" ] && [ "$FORCE" != "1" ]; then
    echo "[=] 已存在，跳过: ${target}"
    echo -e "${target}\t${tar}" >> "${MANIFEST}"
    skip=$((skip+1)); continue
  fi

  # 选择来源（上游走国内镜像重写）
  src_mirror="$(mirror_src "$src")"
  source_ref=""
  case "${ACR_SOURCE}" in
    acr)      source_ref="${acr_ref}" ;;
    upstream) source_ref="${src_mirror}" ;;
    auto)
      if skopeo inspect "${CREDS_FLAG[@]}" "docker://${acr_ref}" >/dev/null 2>&1; then
        source_ref="${acr_ref}"
      else
        source_ref="${src_mirror}"
      fi ;;
    *) echo "[!] 未知 ACR_SOURCE: ${ACR_SOURCE}"; exit 1 ;;
  esac

  # 仅当源为 ACR 时才附带 ACR 凭据（否则会污染公共/镜像站认证）
  copy_creds=()
  case "${source_ref}" in
    "${ACR_REGISTRY}"/*) copy_creds=("${CREDS_FLAG[@]}") ;;
  esac

  echo "--- 拉取: ${source_ref}"
  echo "    重命名: ${target}"
  if skopeo copy --override-os linux --override-arch amd64 \
       "${copy_creds[@]}" "docker://${source_ref}" "docker-archive:${tar}:${target}"; then
    echo -e "${target}\t${tar}" >> "${MANIFEST}"
    ok=$((ok+1))
  else
    echo "[!] 失败: ${source_ref}"
    fail=$((fail+1))
  fi
done < "${LIST}"

echo ""
echo "[+] 完成。成功: ${ok}, 跳过: ${skip}, 失败: ${fail}"
echo "[+] 清单: ${MANIFEST}"
[ "${fail}" -eq 0 ] || exit 1
