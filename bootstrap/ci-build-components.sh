#!/usr/bin/env bash
# CI：检测改动的组件目录并构建 OCI 制品（+cosign 签名）推入 Harbor
# 用法（CI 内）: bash bootstrap/ci-build-components.sh
# 依据: CI_COMMIT_BEFORE_SHA..CI_COMMIT_SHA 的 diff（或 $RANGE）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RANGE="${RANGE:-${CI_COMMIT_BEFORE_SHA:-}..${CI_COMMIT_SHA:-HEAD}}"
# 首个提交（before 全 0）时退化为与父提交比较
case "$RANGE" in
  0000000000000000000000000000000000000000..*) RANGE="HEAD~1..HEAD" ;;
esac

echo "[+] 检测改动组件（range=${RANGE}）"
mapfile -t CHANGED < <(git diff --name-only "$RANGE" 2>/dev/null | grep -oE '^gitops/components/[^/]+/[^/]+/' | sort -u || true)

if [ "${#CHANGED[@]}" -eq 0 ]; then
  echo "[=] 无组件改动，跳过"
  exit 0
fi

fail=0
for d in "${CHANGED[@]}"; do
  spec="${d#gitops/components/}"; spec="${spec%/}"
  echo "== 构建组件 ${spec} =="
  if bash bootstrap/build-component.sh "$spec" "${COMPONENT_TAG:-latest}" --push --sign; then
    echo "   ok ${spec}"
  else
    echo "   FAIL ${spec}"; fail=$((fail+1))
  fi
done
echo "[+] 完成，失败=${fail}"
[ "$fail" = 0 ]
