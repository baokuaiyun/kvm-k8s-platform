#!/usr/bin/env bash
# 引导面：Harbor（registry 就绪）
set -euo pipefail
source "$(dirname "$0")/../lib.sh"

log "安装 Harbor（外部 PG/Redis 指向 platform-data）"
m harbor

log "等待 Harbor 组件就绪"
for d in harbor-core harbor-registry harbor-jobservice harbor-nginx harbor-portal; do
  wait_rollout harbor "deploy/${d}" 300 2>/dev/null || warn "deploy/${d} 未就绪"
done

if harbor_up; then log "Harbor ping 200，registry 就绪"; else warn "Harbor 未返回 200（自签用 --noproxy 校验）"; fi
