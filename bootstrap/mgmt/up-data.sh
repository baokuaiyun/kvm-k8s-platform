#!/usr/bin/env bash
# 引导面：数据平面（CNPG + redis-operator → platform-pg/platform-redis）
set -euo pipefail
source "$(dirname "$0")/../lib.sh"

log "安装 Operator（CNPG + redis-operator）"
m operators
log "部署共享数据层 platform-data（Harbor 前置依赖）"
m platform-data
log "数据平面就绪：platform-pg-rw / platform-redis"
