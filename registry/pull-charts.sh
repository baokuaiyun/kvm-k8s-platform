#!/usr/bin/env bash
# 准备 Helm chart 到本地（HELM_CHARTS_DIR）
# 优先：云效 Codeup Git（HELM_GIT_URL）clone 后本地打包
# 回退：上游 Helm 仓库（helm repo add + helm pull）
# 用法: pull-charts.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIST="${LIST:-${SCRIPT_DIR}/helm-charts-list.txt}"
HELM_CHARTS_DIR="${HELM_CHARTS_DIR:-/data/kvm/charts}"
HELM_GIT_DIR="${HELM_GIT_DIR:-/data/kvm/helm-charts}"

command -v helm >/dev/null 2>&1 || { echo "[!] 需要 helm"; exit 1; }
# 国内直连（避免环境代理）
if [ "${BYPASS_PROXY:-1}" = "1" ]; then
  export no_proxy='*' NO_PROXY='*'
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
fi
mkdir -p "${HELM_CHARTS_DIR}"

urlencode() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }

# 打包某目录下所有 chart（含 Chart.yaml 的目录）
package_local_charts() {
  local root="$1" found=0
  while IFS= read -r cf; do
    [ -z "$cf" ] && continue
    local dir; dir="$(dirname "$cf")"
    echo "--- 打包 ${dir}"
    helm package "$dir" -d "${HELM_CHARTS_DIR}" >/dev/null
    found=1
  done < <(find "$root" -name Chart.yaml -not -path '*/.git/*' 2>/dev/null)
  return $(( 1 - found ))
}

# ---------- 优先：Codeup Git ----------
if [ -n "${HELM_GIT_URL:-}" ]; then
  echo "[+] chart 源: Codeup Git ${HELM_GIT_URL} (${HELM_GIT_REF:-main})"
  clone_url="${HELM_GIT_URL}"
  if [ -n "${HELM_GIT_USER:-}" ] && [ -n "${HELM_GIT_TOKEN:-}" ]; then
    u="$(urlencode "${HELM_GIT_USER}")"
    proto="${HELM_GIT_URL%%://*}"; rest="${HELM_GIT_URL#*://}"
    clone_url="${proto}://${u}:${HELM_GIT_TOKEN}@${rest}"
  fi

  clone_ok=0
  if [ -d "${HELM_GIT_DIR}/.git" ]; then
    if git -C "${HELM_GIT_DIR}" remote set-url origin "${clone_url}" \
       && git -C "${HELM_GIT_DIR}" fetch --depth=1 origin "${HELM_GIT_REF:-main}" \
       && git -C "${HELM_GIT_DIR}" checkout -q FETCH_HEAD; then
      clone_ok=1
    fi
  else
    rm -rf "${HELM_GIT_DIR}"
    if GIT_TERMINAL_PROMPT=0 git clone --depth=1 -b "${HELM_GIT_REF:-main}" "${clone_url}" "${HELM_GIT_DIR}"; then
      clone_ok=1
    fi
  fi

  if [ "$clone_ok" = 1 ] && package_local_charts "${HELM_GIT_DIR}"; then
    echo ""
    echo "[+] chart 已就绪（${HELM_CHARTS_DIR}）:"
    ls -1 "${HELM_CHARTS_DIR}"/*.tgz 2>/dev/null || echo "    (无)"
    exit 0
  fi
  echo "[!] Codeup Git 拉取/打包失败；回退上游拉取（可在云效建 baokuaiyun/helm-charts 仓库修复）"
fi

# ---------- 回退：上游 Helm 仓库 ----------
if [ -n "${HELM_REPO_URL:-}" ]; then
  echo "[+] 使用自定义 Helm 仓库: ${HELM_REPO_NAME} (${HELM_REPO_URL})"
  helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}" \
    --username "${HELM_REPO_USER:-}" --password "${HELM_REPO_PASS:-}" >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true
else
  echo "[+] 使用上游 Helm 仓库"
  awk '!/^#/ && NF>=4 {print $2" "$3}' "${LIST}" | sort -u | while read -r name url; do
    helm repo add "$name" "$url" >/dev/null 2>&1 || true
  done
  helm repo update >/dev/null 2>&1 || true
fi

while read -r chart repo url ver; do
  [[ "$chart" =~ ^#.*$ || -z "${chart:-}" ]] && continue
  [ -z "${ver:-}" ] && continue
  if [ -n "${HELM_REPO_URL:-}" ]; then
    ref="${HELM_REPO_NAME}/${chart}"
  else
    ref="${repo}/${chart}"
  fi
  echo "--- 拉取 ${ref}:${ver}"
  helm pull "$ref" --version "$ver" -d "${HELM_CHARTS_DIR}"
done < "${LIST}"

echo ""
echo "[+] chart 已下载到 ${HELM_CHARTS_DIR}:"
ls -1 "${HELM_CHARTS_DIR}"/*.tgz 2>/dev/null || echo "    (无)"
