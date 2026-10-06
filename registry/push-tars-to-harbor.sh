#!/usr/bin/env bash
# 把已预载的 tar 按 scheme C 推入本域 Harbor（项目 baokuaiyun）
# 免重新下载：skopeo 读 docker-archive(旧名) -> 推 Harbor(新名)
# 用法: push-tars-to-harbor.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIST="${LIST:-${SCRIPT_DIR}/images}"
if [ -d "$LIST" ]; then _t="$(mktemp)"; cat "$LIST"/tier*.txt > "$_t"; LIST="$_t"; trap 'rm -f "$_t"' EXIT; fi
IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-/data/kvm/images/registry}"
OLD_REPO_PREFIX="${OLD_REPO_PREFIX:-harbor.test.baokuaiyun.com/k8s-library}"
HARBOR_HOST="${HARBOR_HOST:-harbor.test.baokuaiyun.com}"
HARBOR_PROJECT="${HARBOR_PROJECT:-baokuaiyun}"
: "${HARBOR_ROBOT_USER:?}"; : "${HARBOR_ROBOT_PASS:?}"
CREDS="${HARBOR_ROBOT_USER}:${HARBOR_ROBOT_PASS}"

if [ "${BYPASS_PROXY:-1}" = "1" ]; then export no_proxy='*' NO_PROXY='*'; unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; fi

# scheme C：去 registry 域(首段含.)，剩余段用 - 拼；核心(k8s.io)/kube-vip 用 basename
scheme_c() {
  local ref="$1" path="$1" first
  first="${path%%/*}"
  if [ "$first" != "$path" ] && [[ "$first" == *.* ]]; then path="${path#*/}"; fi
  case "$ref" in
    registry.k8s.io/*) echo "${ref##*/}" ;;                       # 核心 basename
    ghcr.io/kube-vip/kube-vip*) echo kube-vip ;;                   # 特例
    *) echo "$path" | tr '/' '-' ;;
  esac
}

ok=0; skip=0; fail=0
while read -r src dst tier rest; do
  [[ "$src" =~ ^#.*$ || -z "${src:-}" ]] && continue
  tag="${src##*:}"
  repo="${dst:-$(scheme_c "${src%%:*}")}"
  newrepo="$(scheme_c "${src%%:*}")"
  oldref="${OLD_REPO_PREFIX}/${repo}:${tag}"
  safe=$(echo "$oldref" | tr '/:' '__')
  tar="${IMAGE_CACHE_DIR}/${safe}.tar"
  target="docker://${HARBOR_HOST}/${HARBOR_PROJECT}/${newrepo}:${tag}"

  if [ ! -f "$tar" ]; then
    echo "[=] 无 tar，跳过: ${oldref}"; skip=$((skip+1)); continue
  fi
  echo "--- ${oldref}  ==>  ${HARBOR_HOST}/${HARBOR_PROJECT}/${newrepo}:${tag}"
  if skopeo copy --dest-tls-verify=false --dest-creds "${CREDS}" \
       "docker-archive:${tar}:${oldref}" "$target" >/dev/null 2>&1; then
    ok=$((ok+1))
  else
    # 可能已在 Harbor，重试一次显式错误
    if skopeo inspect --tls-verify=false --creds "${CREDS}" "$target" >/dev/null 2>&1; then
      skip=$((skip+1))
    else
      echo "[!] 失败"; fail=$((fail+1))
    fi
  fi
done < "$LIST"

echo ""
echo "[+] 完成。成功/新增: ${ok}, 跳过: ${skip}, 失败: ${fail}"
