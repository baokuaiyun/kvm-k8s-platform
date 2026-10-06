#!/usr/bin/env bash
# 构建 CI 工具镜像（oras+cosign+git+tar）并推入 Harbor
# 需要：docker + 外网（或代理）；Harbor 凭据在 acr.env
# 用法: bash ci/build-tools.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARBOR_HOST="${HARBOR_HOST:-harbor.test.baokuaiyun.com}"
HARBOR_PROJECT="${HARBOR_PROJECT:-baokuaiyun}"
HARBOR_ROBOT_USER="${HARBOR_ROBOT_USER:-robot\$${HARBOR_PROJECT}+pushpull}"
: "${HARBOR_ROBOT_PASS:?HARBOR_ROBOT_PASS 未设置}"
IMG="ci-tools:latest"
DST="${HARBOR_HOST}/${HARBOR_PROJECT}/ci-tools:latest"

command -v docker >/dev/null || { echo "[!] 需要 docker"; exit 1; }

echo "[+] docker build ${IMG}"
docker build --network host \
  --build-arg http_proxy="${http_proxy:-}" --build-arg https_proxy="${https_proxy:-}" \
  -f "${ROOT}/ci/tools.Dockerfile" -t "$IMG" "$ROOT"

echo "[+] save + skopeo push -> ${DST}（不经 docker 的 Harbor 信任）"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
docker save "$IMG" -o "${tmp}/ci-tools.tar"
skopeo copy --dest-tls-verify=false \
  --dest-creds "${HARBOR_ROBOT_USER}:${HARBOR_ROBOT_PASS}" \
  "docker-archive:${tmp}/ci-tools.tar" "docker://${DST}"
echo "[+] pushed ${DST}"
