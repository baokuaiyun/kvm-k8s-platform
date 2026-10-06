#!/usr/bin/env bash
# 把 gitops/components/<plane>/<name>/ 打包为 OCI 制品并（可选）签名推入 Harbor
# 制品内容 = 该目录的 base/ + overlays/（不含 component.yaml），供 Flux Kustomization path=./overlays/<env> 消费
# 用法: bash bootstrap/build-component.sh <plane>/<name> [tag] [--push] [--sign]
set -euo pipefail
GITOPS_DIR="${GITOPS_DIR:-$(cd "$(dirname "$0")/../gitops" && pwd)}"
HARBOR_HOST="${HARBOR_HOST:-harbor.test.baokuaiyun.com}"
HARBOR_PROJECT="${HARBOR_PROJECT:-baokuaiyun}"
: "${HARBOR_ROBOT_PASS:?}"
ROBOT_USER="robot\$${HARBOR_PROJECT}+pushpull"

SPEC="${1:?用法: build-component.sh <plane>/<name> [tag] [--push] [--sign]}"
TAG="${2:-latest}"
PUSH=0; SIGN=0
for a in "$@"; do [ "$a" = "--push" ] && PUSH=1; [ "$a" = "--sign" ] && SIGN=1; done

DIR="${GITOPS_DIR}/components/${SPEC}"
[ -d "$DIR" ] || { echo "[!] 无组件目录 ${DIR}"; exit 1; }
NAME="$(basename "$SPEC")"
TARGET="${HARBOR_HOST}/${HARBOR_PROJECT}/${NAME}:${TAG}"

bypass() { env no_proxy='*' NO_PROXY='*' http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= "$@"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# 只打包 base/ 与 overlays/（保留相对路径）
[ -d "${DIR}/base" ] && cp -r "${DIR}/base" "$tmp/"
[ -d "${DIR}/overlays" ] && cp -r "${DIR}/overlays" "$tmp/"
tar czf "$tmp/${NAME}.tar.gz" -C "$tmp" $(cd "$tmp" && ls -d base overlays 2>/dev/null)

if [ "$PUSH" = 1 ]; then
  bypass oras push --insecure --disable-path-validation \
    --username "$ROBOT_USER" --password "$HARBOR_ROBOT_PASS" \
    --artifact-type application/vnd.oci.image.config.v1+json \
    "$TARGET" "$tmp/${NAME}.tar.gz:application/vnd.oci.image.layer.v1.tar+gzip"
  echo "[+] pushed ${TARGET}"
  if [ "$SIGN" = 1 ] && [ -f "${COSIGN_KEY:-/root/cosign.key}" ]; then
    COSIGN_PASSWORD="${COSIGN_PASSWORD:-drill}" bypass cosign sign --key "${COSIGN_KEY:-/root/cosign.key}" \
      --allow-insecure-registry --yes "$TARGET" >/dev/null 2>&1 && echo "[+] signed ${TARGET}"
  fi
else
  echo "[=] 未 --push，仅打包: ${tmp}/${NAME}.tar.gz"
  cp "$tmp/${NAME}.tar.gz" "/tmp/${NAME}-component.tar.gz"
  echo "    已存 /tmp/${NAME}-component.tar.gz"
fi
