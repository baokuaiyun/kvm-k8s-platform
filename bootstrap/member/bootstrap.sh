#!/usr/bin/env bash
# 成员集群引导：单点集群 → 指向本 Harbor → 安装 Flux → 接入模式
# 用法: FLEET_MODE=biz bash bootstrap/member/bootstrap.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "${DIR}/../lib.sh"

MODE="${FLEET_MODE:-biz}"
ENVNAME="${FLEET_ENV:-drill}"

log "==== 1) 指向本 Harbor（containerd） ===="
bash "${DIR}/configure-registry.sh"

if [ "${ENABLE_FLUX:-true}" = "true" ]; then
  log "==== 2) Flux Operator + 模式 ${MODE} ===="
  FLEET_MODE="${MODE}" bash "${DIR}/up-flux.sh"
else
  log "==== 2) ENABLE_FLUX=false：单独集群（脚本管理，不用 Flux） ===="
  bash "${DIR}/standalone.sh"
fi

log "==== 3) 制品按需拉取（默认检测式；离线可用 lock seed） ===="
if [ "${DATA_SOURCE:-local}" = "shared" ]; then
  log "DATA_SOURCE=shared：应用消费本数据平面（见 docs/data-source.md）"
fi

log "成员引导完成 ✅（mode=${MODE}, env=${ENVNAME}）"
