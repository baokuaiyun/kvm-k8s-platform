#!/usr/bin/env bash
# 数据平面验收：CNPG 集群/多库/角色、Redis、备份（ScheduledBackup + 对象存储）、端点。
# 用法: bash scripts/verify-data.sh    # 退出码 0=通过（WARN 不致命）
set -uo pipefail

NS="${PLATFORM_DATA_NS:-platform-data}"
S3_ENDPOINT_V="${S3_ENDPOINT:-}"; PG_BUCKET="${PG_BACKUP_BUCKET:-}"
FAIL=0
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [WARN] $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=1; }

command -v kubectl >/dev/null 2>&1 || { echo "[!] 需要 kubectl"; exit 2; }
kubectl cluster-info >/dev/null 2>&1 || { echo "[!] 无法连接集群"; exit 2; }

echo "=== 1. CNPG 集群 ==="
if kubectl -n "$NS" get cluster platform-pg >/dev/null 2>&1; then
  ready=$(kubectl -n "$NS" get cluster platform-pg -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  inst=$(kubectl -n "$NS" get cluster platform-pg -o jsonpath='{.spec.instances}' 2>/dev/null)
  [ "$ready" = "True" ] && ok "platform-pg Ready（instances=$inst）" || bad "platform-pg 未 Ready（$ready）"
  # 多库
  for db in registry gitlabhq-production casdoor; do
    kubectl -n "$NS" get database "$db" >/dev/null 2>&1 && ok "Database/$db" || warn "Database/$db 不存在"
  done
else
  bad "Cluster/platform-pg 不存在（make platform-data）"
fi

echo "=== 2. Redis ==="
if kubectl -n "$NS" get statefulset platform-redis >/dev/null 2>&1; then
  r=$(kubectl -n "$NS" get statefulset platform-redis -o jsonpath='{.status.readyReplicas}')
  [ "${r:-0}" -ge 1 ] && ok "platform-redis ready=${r}" || bad "platform-redis 未就绪"
else
  warn "platform-redis 不存在（可能用 RedisReplication）"
fi

echo "=== 3. 端点（ClusterIP Service）==="
for svc in platform-pg-rw platform-redis; do
  kubectl -n "$NS" get svc "$svc" >/dev/null 2>&1 && ok "svc/$svc" || bad "svc/$svc 缺失"
done

echo "=== 4. 备份 ==="
sb=$(kubectl -n "$NS" get scheduledbackup --no-headers 2>/dev/null | wc -l)
[ "$sb" -ge 1 ] && ok "ScheduledBackup ${sb} 个" || warn "无 ScheduledBackup"
last=$(kubectl -n "$NS" get backup --no-headers 2>/dev/null | awk '$3=="completed"' | tail -1)
[ -n "$last" ] && ok "最近完成备份: $last" || warn "无已完成 Backup"
if [ -n "$PG_BUCKET" ] && [ -n "$S3_ENDPOINT_V" ]; then
  bc=$(kubectl -n "$NS" get cluster platform-pg -o jsonpath='{.spec.backup.barmanObjectStore.destinationPath}' 2>/dev/null)
  [ -n "$bc" ] && ok "barman 异地: $bc" || warn "未配置 barman（异地 PITR 不可用）"
else
  warn "未设 PG_BACKUP_BUCKET/S3_ENDPOINT（drill 本地，无异地 PITR）"
fi

echo ""
[ "$FAIL" -eq 0 ] && echo "[+] 数据平面验收通过（警告项请逐条确认）" || echo "[!] 数据平面验收存在失败项"
exit "$FAIL"
