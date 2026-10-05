#!/usr/bin/env bash
# 部署 Casdoor（集群内统一用户管理 IdP）
# 渲染 __占位__ -> 变量后 kubectl apply -k
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
RENDER="/tmp/casdoor-render"

: "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY 未设置（见 variables.mk/acr.env）}"
: "${CASDOOR_HOST:?CASDOOR_HOST 未设置}"
: "${CASDOOR_DB_USER:?CASDOOR_DB_USER 未设置}"
: "${CASDOOR_DB_PASS:?CASDOOR_DB_PASS 未设置}"
: "${CASDOOR_DB_NAME:?CASDOOR_DB_NAME 未设置}"

command -v kubectl >/dev/null 2>&1 || { echo "[!] 需要 kubectl"; exit 1; }

rm -rf "$RENDER"; mkdir -p "$RENDER"
for f in "$DIR"/*.yaml; do
  sed -e "s|__IMAGE_REPOSITORY__|${IMAGE_REPOSITORY}|g" \
      -e "s|__CASDOOR_VERSION__|${CASDOOR_VERSION:-latest}|g" \
      -e "s|__CASDOOR_DB_USER__|${CASDOOR_DB_USER}|g" \
      -e "s|__CASDOOR_DB_PASS__|${CASDOOR_DB_PASS}|g" \
      -e "s|__CASDOOR_DB_NAME__|${CASDOOR_DB_NAME}|g" \
      -e "s|__CASDOOR_HOST__|${CASDOOR_HOST}|g" \
      "$f" > "$RENDER/$(basename "$f")"
done

echo "[+] 应用 Casdoor 清单..."
kubectl apply -k "$RENDER"

echo "[+] 等待 postgres/casdoor 就绪..."
kubectl -n casdoor rollout status deploy/casdoor-postgres --timeout=240s || true
kubectl -n casdoor rollout status deploy/casdoor --timeout=300s || true

echo "[+] Casdoor: https://${CASDOOR_HOST}  （初始管理员通常 admin/123，请立即改密）"
