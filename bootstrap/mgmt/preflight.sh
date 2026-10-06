#!/usr/bin/env bash
# 引导前置检查：工具 / Harbor 可达 / 凭据 / CA / 版本
set -euo pipefail
source "$(dirname "$0")/../lib.sh"

fail=0
for t in kubectl helm skopeo oras cosign; do
  if command -v "$t" >/dev/null 2>&1; then log "工具 $t: OK"; else warn "缺少工具 $t"; fail=1; fi
done

log "检查 Harbor 可达: https://${HARBOR_HOST}"
if harbor_up; then log "Harbor ping: 200"; else warn "Harbor 不可达（引导面需可访问；离线请用 Day-0 本地包）"; fi

log "检查 Harbor 凭据（robot push/pull）"
if skopeo inspect --tls-verify=false --creds "${ROBOT_USER}:${HARBOR_ROBOT_PASS}" \
     "docker://${HARBOR_HOST}/${HARBOR_PROJECT}/pause:3.10" >/dev/null 2>&1; then
  log "robot 凭据: OK"
else
  warn "robot 凭据校验失败（或 pause 镜像不存在）"
fi

log "检查 Harbor CA（自签环境需可注入）"
kubectl -n gateway get secret wildcard-test-tls -o jsonpath='{.data.ca\.crt}' >/dev/null 2>&1 \
  && log "发现网关通配证书 CA（可用于注入）" \
  || warn "未发现网关证书（自签 CA 需另行提供）"

echo ""
[ "$fail" = 0 ] && log "preflight 通过" || die "preflight 有缺失项"
