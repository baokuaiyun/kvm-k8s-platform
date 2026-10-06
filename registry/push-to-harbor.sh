#!/usr/bin/env bash
# 把镜像推入本域 Harbor（私有项目 baokuaiyun）
# 源: 国内镜像(docker/quay/ghcr via skopeo) / registry.gitlab.com (via oras)
# 用法: push-to-harbor.sh [list-file]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIST="${1:-${LIST:-${SCRIPT_DIR}/images}}"
if [ -d "$LIST" ]; then _t="$(mktemp)"; cat "$LIST"/tier*.txt > "$_t"; LIST="$_t"; trap 'rm -f "$_t"' EXIT; fi

: "${HARBOR_HOST:?HARBOR_HOST 未设置}"
: "${HARBOR_PROJECT:?HARBOR_PROJECT 未设置}"
: "${HARBOR_ROBOT_USER:?HARBOR_ROBOT_USER 未设置（见 acr.env）}"
: "${HARBOR_ROBOT_PASS:?HARBOR_ROBOT_PASS 未设置（见 acr.env）}"

MIRROR_DOCKER="${MIRROR_DOCKER:-docker.m.daocloud.io}"
MIRROR_QUAY="${MIRROR_QUAY:-quay.m.daocloud.io}"
MIRROR_GHCR="${MIRROR_GHCR:-ghcr.nju.edu.cn}"
MIRROR_K8S="${MIRROR_K8S:-registry.cn-hangzhou.aliyuncs.com/google_containers}"
DEST="${HARBOR_HOST}/${HARBOR_PROJECT}"
CREDS="${HARBOR_ROBOT_USER}:${HARBOR_ROBOT_PASS}"

# 国内直连
if [ "${BYPASS_PROXY:-1}" = "1" ]; then
  export no_proxy='*' NO_PROXY='*'; unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
fi

# scheme C：去 registry 域，路径段用 - 拼接
scheme_c() {
  local ref="$1" path first
  path="${ref}"; first="${path%%/*}"
  if [ "$first" != "$path" ] && [[ "$first" == *.* ]]; then path="${path#*/}"; fi
  echo "$path" | tr '/' '-'
}
# 源 -> 国内镜像重写
mirror_src() {
  local img="$1" rest
  case "$img" in
    registry.k8s.io/*) rest="${img#registry.k8s.io/}"; rest="${rest##*/}"; echo "${MIRROR_K8S}/${rest}" ;;
    ghcr.io/*)         echo "${MIRROR_GHCR}/${img#ghcr.io/}" ;;
    docker.io/*)       echo "${MIRROR_DOCKER}/${img#docker.io/}" ;;
    quay.io/*)         echo "${MIRROR_QUAY}/${img#quay.io/}" ;;
    */*)               echo "${MIRROR_DOCKER}/${img}" ;;   # 裸名(docker hub)
    *)                 echo "$img" ;;
  esac
}

ok=0; fail=0
while read -r src dst tier rest; do
  [[ "$src" =~ ^#.*$ || -z "${src:-}" ]] && continue
  tag="${src##*:}"
  repo="${dst:-$(scheme_c "${src%%:*}")}"
  target="docker://${DEST}/${repo}:${tag}"

  case "$src" in
    registry.gitlab.com/*)
      # skopeo 对 registry.gitlab.com 失败 -> 用 oras 拉到本地 OCI，再由 skopeo 推 Harbor
      echo "--- oras+skopeo ${src} -> ${DEST}/${repo}:${tag}"
      TMPD="$(mktemp -d)"
      if oras pull --output "$TMPD" "${src}" >/dev/null 2>&1 \
         && skopeo copy --dest-tls-verify=false --dest-creds "${CREDS}" \
              "oci:${TMPD}:${tag}" "$target"; then
        ok=$((ok+1))
      else
        echo "[!] 推送失败(gitlab): ${src}"; fail=$((fail+1))
      fi
      rm -rf "$TMPD" ;;
    *)
      m="$(mirror_src "$src")"
      echo "--- skopeo ${m} -> ${DEST}/${repo}:${tag}"
      if skopeo copy --dest-tls-verify=false --dest-creds "${CREDS}" \
           --override-os linux --override-arch amd64 "docker://${m}" "$target"; then
        ok=$((ok+1))
      else
        echo "[!] 推送失败: ${src}"; fail=$((fail+1))
      fi ;;
  esac
done < "$LIST"

echo ""
echo "[+] 完成。成功: ${ok}, 失败: ${fail}"
