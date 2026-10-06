#!/usr/bin/env bash
# 本集群（mgmt/all-in-one）引导：单点→数据平面→Harbor→制品→Flux
# 用法: FLEET_MODE=mgmt bash bootstrap/mgmt/bootstrap.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "${DIR}/../lib.sh"

MODE="${FLEET_MODE:-all-in-one}"
ENVNAME="${FLEET_ENV:-drill}"

log "==== 0) preflight ===="; bash "${DIR}/preflight.sh"
log "==== 1) Day-0 镜像导入（破环） ===="; bash "${DIR}/import-images.sh"
log "==== 2) 集群核心 （Cilium/Longhorn/cert-manager/kgateway/Gateway） ===="; bash "${DIR}/up-core.sh"
log "==== 3) 数据平面 （PG/Redis） ===="; bash "${DIR}/up-data.sh"
log "==== 4) Harbor （registry 就绪） ===="; bash "${DIR}/up-harbor.sh"
log "==== 5) 制品导入（fleet 模式，检测式+签名） ===="
m publish-artifacts FLEET_MODE="${MODE}" FLEET_ENV="${ENVNAME}" CLUSTER_TYPE="${CLUSTER_TYPE:-all}"
log "==== 6) Flux Operator + fleet 模式 ===="
FLEET_MODE="${MODE}" bash "${DIR}/up-flux.sh"
log "==== 验收 ===="
m verify-bootstrap FLEET_MODE="${MODE}" FLEET_ENV="${ENVNAME}" CLUSTER_TYPE="${CLUSTER_TYPE:-all}"
log "引导完成 ✅"
