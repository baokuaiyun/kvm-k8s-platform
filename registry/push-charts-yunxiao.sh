#!/usr/bin/env bash
# 把本地 vendored chart 推送到云效制品仓库(Helm)
# 依赖: helm + helm-push 插件 (helm plugin install https://github.com/chartmuseum/helm-push)
# 用法: push-charts-yunxiao.sh
set -euo pipefail

: "${HELM_REPO_URL:?请设置 HELM_REPO_URL（云效 Helm 仓库地址，见 acr.env）}"
: "${HELM_REPO_NAME:?请设置 HELM_REPO_NAME}"
HELM_CHARTS_DIR="${HELM_CHARTS_DIR:-/data/kvm/charts}"

command -v helm >/dev/null 2>&1 || { echo "[!] 需要 helm"; exit 1; }
if ! helm plugin list 2>/dev/null | grep -qE 'cm-push|push'; then
  echo "[!] 需要 helm-push 插件:"
  echo "    helm plugin install https://github.com/chartmuseum/helm-push"
  exit 1
fi

echo "[+] 添加云效仓库 ${HELM_REPO_NAME}..."
helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}" \
  --username "${HELM_REPO_USER:-}" --password "${HELM_REPO_PASS:-}" >/dev/null 2>&1 || true

shopt -s nullglob
tgzs=("${HELM_CHARTS_DIR}"/*.tgz)
[ "${#tgzs[@]}" -gt 0 ] || { echo "[!] ${HELM_CHARTS_DIR} 下无 .tgz；先 make charts-pull"; exit 1; }

for tgz in "${tgzs[@]}"; do
  echo "--- 推送 $(basename "$tgz")"
  helm cm-push "$tgz" "${HELM_REPO_NAME}"
done
echo "[+] 推送完成"
