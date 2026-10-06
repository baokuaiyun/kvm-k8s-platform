#!/usr/bin/env bash
# Day-0：把本地镜像包导入各节点 containerd（离线破环，无 registry 也能起核心/Harbor/Flux）
# 幂等：ctr import 对已存在镜像为 no-op。
set -euo pipefail
source "$(dirname "$0")/../lib.sh"

CACHE_DIR="${IMAGE_CACHE_DIR:-/data/kvm/images/registry}"
[ -d "$CACHE_DIR" ] || die "无镜像缓存目录 ${CACHE_DIR}"

log "导入本地镜像包 -> 各节点（${CACHE_DIR}）"
# 复用既有分发导入逻辑（scp + ctr -n k8s.io images import）
m image-load

log "导入完成。可选：启动本地 bootstrap registry（zot/registry:2）承载引导制品"
if command -v docker >/dev/null 2>&1; then
  log "提示：如需离线 registry，可 docker run -d -p 5000:5000 registry:2 并推送 Day-0 制品"
fi
