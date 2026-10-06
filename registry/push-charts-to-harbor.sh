#!/usr/bin/env bash
# 把本地 chart(HELM_CHARTS_DIR/*.tgz) 推入 Harbor OCI（oci://<harbor>/<project>）
# 用法: push-charts-to-harbor.sh
set -euo pipefail

HELM_CHARTS_DIR="${HELM_CHARTS_DIR:-/data/kvm/charts}"
: "${HARBOR_HOST:?}"; : "${HARBOR_PROJECT:?}"
: "${HARBOR_ROBOT_USER:?}"; : "${HARBOR_ROBOT_PASS:?}"
OCI_REPO="oci://${HARBOR_HOST}/${HARBOR_PROJECT}"

command -v helm >/dev/null 2>&1 || { echo "[!] 需要 helm"; exit 1; }
if [ "${BYPASS_PROXY:-1}" = "1" ]; then export no_proxy='*' NO_PROXY='*'; unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; fi

shopt -s nullglob
tgzs=("${HELM_CHARTS_DIR}"/*.tgz)
[ "${#tgzs[@]}" -gt 0 ] || { echo "[!] ${HELM_CHARTS_DIR} 无 .tgz"; exit 1; }

ok=0; fail=0
for t in "${tgzs[@]}"; do
  echo "--- push $(basename "$t") -> ${OCI_REPO}"
  if helm push "$t" "${OCI_REPO}" \
       --insecure-skip-tls-verify \
       --username "${HARBOR_ROBOT_USER}" --password "${HARBOR_ROBOT_PASS}" >/dev/null 2>&1; then
    ok=$((ok+1)); echo "    OK"
  else
    echo "    FAIL"; fail=$((fail+1))
  fi
done
echo ""
echo "[+] chart 推送完成。成功: ${ok}, 失败: ${fail}"
