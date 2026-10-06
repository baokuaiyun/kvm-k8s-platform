#!/usr/bin/env bash
# 引导脚本共享库
set -euo pipefail

BOOT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BOOT_ROOT

HARBOR_HOST="${HARBOR_HOST:-harbor.test.baokuaiyun.com}"
HARBOR_PROJECT="${HARBOR_PROJECT:-baokuaiyun}"
: "${HARBOR_ROBOT_PASS:?HARBOR_ROBOT_PASS 未设置（acr.env）}"
export HARBOR_HOST HARBOR_PROJECT
ROBOT_USER="robot\$${HARBOR_PROJECT}+pushpull"
export ROBOT_USER

log() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die() { echo "[x] $*" >&2; exit 1; }

# 海外源直连
bypass() { env no_proxy='*' NO_PROXY='*' http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= "$@"; }

# make 封装（在仓库根执行）
m() { make -C "$BOOT_ROOT" "$@"; }

# 等待 Deployment/STS ready
wait_rollout() { local ns="$1" res="$2" t="${3:-180}"; kubectl -n "$ns" rollout status "$res" --timeout="${t}s"; }

harbor_up() { curl -sk --noproxy '*' -o /dev/null -w '%{http_code}' "https://${HARBOR_HOST}/api/v2.0/ping" 2>/dev/null | grep -q 200; }
