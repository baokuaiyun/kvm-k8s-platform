#!/usr/bin/env bash
# 用 oras 把 GitLab CNG/Operator 镜像同步到本域 Harbor（scheme C 短名）
# 源 registry.gitlab.com（skopeo 对其失败，用 oras）；Harbor 自签 -> --to-insecure
# 用法: push-gitlab-to-harbor.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIST="${LIST:-${SCRIPT_DIR}/images/gitlab-cng.txt}"
HARBOR_HOST="${HARBOR_HOST:-harbor.test.baokuaiyun.com}"
HARBOR_PROJECT="${HARBOR_PROJECT:-baokuaiyun}"
: "${HARBOR_ROBOT_USER:?}"; : "${HARBOR_ROBOT_PASS:?}"

command -v oras >/dev/null 2>&1 || { echo "[!] 需要 oras"; exit 1; }

if [ "${BYPASS_PROXY:-1}" = "1" ]; then export no_proxy='*' NO_PROXY='*'; unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; fi

ok=0; skip=0; fail=0
while read -r src dst rest; do
  [[ "$src" =~ ^#.*$ || -z "${src:-}" ]] && continue
  tag="${src##*:}"
  target="${HARBOR_HOST}/${HARBOR_PROJECT}/${dst}:${tag}"
  echo "--- ${src}  ==>  ${target}"
  if oras copy --to-insecure \
       --to-username "${HARBOR_ROBOT_USER}" --to-password "${HARBOR_ROBOT_PASS}" \
       "$src" "$target" >/dev/null 2>&1; then
    ok=$((ok+1)); echo "    ok"
  else
    # 已存在则跳过
    if oras manifest fetch --insecure \
         --username "${HARBOR_ROBOT_USER}" --password "${HARBOR_ROBOT_PASS}" \
         "$target" >/dev/null 2>&1; then
      skip=$((skip+1)); echo "    已存在，跳过"
    else
      fail=$((fail+1)); echo "    [!] 失败"
    fi
  fi
done < "$LIST"

echo ""
echo "[+] 完成。新增: ${ok}, 跳过: ${skip}, 失败: ${fail}"
