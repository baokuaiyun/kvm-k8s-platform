#!/usr/bin/env bash
# 成员集群：安装 Flux Operator 并指向"本"Harbor 的 fleet 制品
set -euo pipefail
source "$(dirname "$0")/../lib.sh"

MODE="${FLEET_MODE:-biz}"

if [ "${ENABLE_FLUX:-true}" != "true" ]; then
  warn "ENABLE_FLUX=false：跳过 Flux 安装（该模式不需要 Flux）"
  exit 0
fi

log "安装 Flux Operator（Helm，chart+镜像走本 Harbor）"
m flux-operator

log "接入 fleet 模式 ${MODE}（source=本 Harbor OCI）"
m gitops FLEET_MODE="${MODE}"

log "成员 Flux 就绪（源：${HARBOR_HOST}）"
