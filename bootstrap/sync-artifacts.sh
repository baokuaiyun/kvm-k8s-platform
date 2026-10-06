#!/usr/bin/env bash
# 按 lock 做"检测 → 按需导入"到 Harbor（幂等），可选 cosign 签名。
# 用法: bash bootstrap/sync-artifacts.sh <mode> [env] [--sign]
set -euo pipefail

GITOPS_DIR="${GITOPS_DIR:-$(cd "$(dirname "$0")/../gitops" && pwd)}"
MODE="${1:-all-in-one}"
ENVNAME="${2:-drill}"
SIGN=0; [ "${3:-}" = "--sign" ] && SIGN=1

HARBOR_HOST="${HARBOR_HOST:-harbor.test.baokuaiyun.com}"
HARBOR_PROJECT="${HARBOR_PROJECT:-baokuaiyun}"
: "${HARBOR_ROBOT_PASS:?}"
ROBOT_USER="robot\$${HARBOR_PROJECT}+pushpull"
CREDS="${ROBOT_USER}:${HARBOR_ROBOT_PASS}"

# 海外源镜像映射（默认）
MIRROR_DOCKER="${MIRROR_DOCKER:-docker.m.daocloud.io}"
MIRROR_QUAY="${MIRROR_QUAY:-quay.m.daocloud.io}"
MIRROR_GHCR="${MIRROR_GHCR:-ghcr.dockerproxy.net}"
MIRROR_K8S="${MIRROR_K8S:-k8s-gcr.m.daocloud.io}"

CTYPE="${CLUSTER_TYPE:-all}"
LOCK="${GITOPS_DIR}/locks/${MODE}-${ENVNAME}-${CTYPE}.lock"
[ -f "$LOCK" ] || { echo "[!] 无 lock：${LOCK}（先跑 make resolve-artifacts FLEET_MODE=${MODE} FLEET_ENV=${ENVNAME} CLUSTER_TYPE=${CTYPE}）"; exit 1; }

mirror() {
  local s="$1" rest
  case "$s" in
    docker.io/*) rest="${s#docker.io/}"; echo "${MIRROR_DOCKER}/${rest}" ;;
    quay.io/*)   rest="${s#quay.io/}";   echo "${MIRROR_QUAY}/${rest}" ;;
    ghcr.io/*)   rest="${s#ghcr.io/}";   echo "${MIRROR_GHCR}/${rest}" ;;
    registry.k8s.io/*) rest="${s#registry.k8s.io/}"; echo "${MIRROR_K8S}/${rest}" ;;
    *) echo "$s" ;;
  esac
}

bypass() { env no_proxy='*' NO_PROXY='*' http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= "$@"; }

ok=0; skip=0; fail=0
while read -r src dst; do
  [[ "$src" =~ ^#.*$ || -z "${src:-}" ]] && continue
  if skopeo inspect --tls-verify=false --creds "$CREDS" "docker://${dst}" >/dev/null 2>&1; then
    echo "[=] 已存在 ${dst}"; skip=$((skip+1)); continue
  fi
  msrc="$(mirror "$src")"
  echo "[+] ${msrc} -> ${dst}"
  if bypass timeout -s KILL 900 skopeo copy --dest-tls-verify=false --dest-creds "$CREDS" \
        "docker://${msrc}" "docker://${dst}" >/tmp/sync-err 2>&1; then
    ok=$((ok+1))
    if [ "$SIGN" = 1 ] && [ -f "${COSIGN_KEY:-/root/cosign.key}" ]; then
      COSIGN_PASSWORD="${COSIGN_PASSWORD:-drill}" bypass cosign sign --key "${COSIGN_KEY:-/root/cosign.key}" \
        --allow-insecure-registry --yes "$dst" >/dev/null 2>&1 && echo "    signed" || echo "    [!] sign 失败"
    fi
  else
    echo "    [!] 失败"; tail -1 /tmp/sync-err; fail=$((fail+1))
  fi
done < "$LOCK"

echo ""
echo "[+] 完成 mode=${MODE} env=${ENVNAME}: 新增=${ok} 跳过=${skip} 失败=${fail}"
