#!/usr/bin/env bash
# 单独集群（无 Flux）：用脚本/Operator 声明式管理，不依赖 Flux
# 适用 ENABLE_FLUX=false（如 data/edge/小客户）
set -euo pipefail
source "$(dirname "$0")/../lib.sh"

UNITS="${FLEET_MODES:-${FLEET_MODE:-all-in-one}}"
ENVNAME="${FLEET_ENV:-drill}"
CTYPE="${CLUSTER_TYPE:-all}"

log "单独模式（无 Flux）：units=${UNITS} env=${ENVNAME} type=${CTYPE}"

# 1) 制品按需导入 Harbor（检测式）
m publish-artifacts FLEET_MODES="${UNITS}" FLEET_ENV="${ENVNAME}" CLUSTER_TYPE="${CTYPE}"

# 2) 引导面组件（集群核心/数据）用脚本管理（如需）
#    说明：本模式不用 Flux；核心用 bootstrap/mgmt 的脚本目标，应用用 Operator/清单。
log "提示：核心组件用脚本管理（make cni / storage / cert ...）；"
log "      应用数据用 Operator/清单直接 apply（参考 gitops/components/*）"
log "单独集群（无 Flux）准备完成 ✅"
