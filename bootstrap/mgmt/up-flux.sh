#!/usr/bin/env bash
# 引导面：安装 Flux Operator 并接入 fleet 模式（接管"非引导面"）
set -euo pipefail
source "$(dirname "$0")/../lib.sh"

MODE="${FLEET_MODE:-all-in-one}"

log "安装/升级 Flux Operator（Helm，chart+镜像走 Harbor）"
m flux-operator

log "接入 fleet 模式：${MODE}"
m gitops FLEET_MODE="${MODE}"

log "等待 FluxInstance 就绪"
kubectl -n flux-system wait --for=condition=Ready fluxinstance/flux --timeout=180s 2>/dev/null || warn "FluxInstance 未就绪"

log "Flux 引导完成。UI: https://flux.test.baokuaiyun.com"
