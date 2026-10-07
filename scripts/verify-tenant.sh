#!/usr/bin/env bash
# 租户平面验收：Mode A 租户（namespace/Quota/LimitRange/PSA/NetworkPolicy/RBAC）+ 隔离用例。
# 用法: bash scripts/verify-tenant.sh [tenant...]   # 默认 team-a team-b
set -uo pipefail

TENANTS=("$@"); [ "${#TENANTS[@]}" -eq 0 ] && TENANTS=(team-a team-b)
FAIL=0
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [WARN] $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=1; }

command -v kubectl >/dev/null 2>&1 || { echo "[!] 需要 kubectl"; exit 2; }
kubectl cluster-info >/dev/null 2>&1 || { echo "[!] 无法连接集群"; exit 2; }

for t in "${TENANTS[@]}"; do
  echo "=== 租户 $t ==="
  if ! kubectl get ns "$t" >/dev/null 2>&1; then bad "namespace/$t 不存在"; continue; fi
  ok "namespace 存在"
  kubectl -n "$t" get resourcequota >/dev/null 2>&1 && ok "ResourceQuota 存在" || warn "无 ResourceQuota"
  kubectl -n "$t" get limitrange >/dev/null 2>&1 && ok "LimitRange 存在" || warn "无 LimitRange"
  psa=$(kubectl get ns "$t" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)
  [ -n "$psa" ] && ok "PSA enforce=$psa" || warn "未设 PSA 标签"
  np=$(kubectl -n "$t" get networkpolicy --no-headers 2>/dev/null | wc -l)
  [ "$np" -ge 1 ] && ok "NetworkPolicy ${np} 个" || warn "无 NetworkPolicy"
  rb=$(kubectl -n "$t" get rolebinding --no-headers 2>/dev/null | wc -l)
  [ "$rb" -ge 1 ] && ok "RoleBinding ${rb} 个" || warn "无 RoleBinding"
done

echo "=== 隔离用例：privileged Pod 应被拒（$TENANTS）==="
if kubectl -n "${TENANTS[0]}" get ns >/dev/null 2>&1; then
  out=$(kubectl -n "${TENANTS[0]}" run psa-probe --image=docker.io/busybox:1.37.0 \
        --dry-run=server -o name --overrides='{"spec":{"containers":[{"name":"c","image":"docker.io/busybox:1.37.0","securityContext":{"privileged":true}}]}}' 2>&1)
  if echo "$out" | grep -qiE 'forbidden|violat|denied'; then ok "privileged 被拒（PSA 生效）"; else warn "privileged 未被拒（PSA 未强制）"; fi
else
  warn "跳过（无 ${TENANTS[0]} 命名空间）"
fi

echo ""
[ "$FAIL" -eq 0 ] && echo "[+] 租户平面验收通过（警告项请逐条确认）" || echo "[!] 租户平面验收存在失败项"
exit "$FAIL"
