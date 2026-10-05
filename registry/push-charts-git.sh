#!/usr/bin/env bash
# 把本地 chart(tgz) 推送到云效 Codeup Git 仓库
# 用法: push-charts-git.sh
set -euo pipefail

: "${HELM_GIT_URL:?HELM_GIT_URL 未设置（见 acr.env）}"
HELM_GIT_DIR="${HELM_GIT_DIR:-/data/kvm/helm-charts}"
HELM_CHARTS_DIR="${HELM_CHARTS_DIR:-/data/kvm/charts}"
HELM_GIT_REF="${HELM_GIT_REF:-main}"

command -v git >/dev/null 2>&1 || { echo "[!] 需要 git"; exit 1; }
if [ "${BYPASS_PROXY:-1}" = "1" ]; then
  export no_proxy='*' NO_PROXY='*'
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
fi

urlencode() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
clone_url="${HELM_GIT_URL}"
if [ -n "${HELM_GIT_USER:-}" ] && [ -n "${HELM_GIT_TOKEN:-}" ]; then
  u="$(urlencode "${HELM_GIT_USER}")"
  proto="${HELM_GIT_URL%%://*}"; rest="${HELM_GIT_URL#*://}"
  clone_url="${proto}://${u}:${HELM_GIT_TOKEN}@${rest}"
fi

# 确保本地仓库存在
if [ -d "${HELM_GIT_DIR}/.git" ]; then
  git -C "${HELM_GIT_DIR}" remote set-url origin "${clone_url}"
  git -C "${HELM_GIT_DIR}" fetch --depth=1 origin "${HELM_GIT_REF}"
  git -C "${HELM_GIT_DIR}" checkout -q FETCH_HEAD || true
else
  rm -rf "${HELM_GIT_DIR}"
  GIT_TERMINAL_PROMPT=0 git clone --depth=1 -b "${HELM_GIT_REF}" "${clone_url}" "${HELM_GIT_DIR}"
fi

shopt -s nullglob
tgzs=("${HELM_CHARTS_DIR}"/*.tgz)
[ "${#tgzs[@]}" -gt 0 ] || { echo "[!] ${HELM_CHARTS_DIR} 下无 .tgz；先 make charts-pull"; exit 1; }

mkdir -p "${HELM_GIT_DIR}/charts"
cp "${tgzs[@]}" "${HELM_GIT_DIR}/charts/"
git -C "${HELM_GIT_DIR}" add charts/
if git -C "${HELM_GIT_DIR}" diff --cached --quiet; then
  echo "[=] 无变化，跳过"
  exit 0
fi
git -C "${HELM_GIT_DIR}" \
  -c user.email="${HELM_GIT_USER:-ci@baokuaiyun.com}" \
  -c user.name="baokuaiyun-ci" \
  commit -m "charts: 同步 $(date +%F\ %T)"
GIT_TERMINAL_PROMPT=0 git -C "${HELM_GIT_DIR}" push origin "HEAD:${HELM_GIT_REF}"
echo "[+] 已推送到 ${HELM_GIT_URL} (${HELM_GIT_REF})"
