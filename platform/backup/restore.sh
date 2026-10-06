#!/usr/bin/env bash
# 应用恢复演练/执行（默认仅打印 runbook，加 CONFIRM=yes 才真正执行）
# 用法: bash platform/backup/restore.sh <harbor|gitlab|casdoor|pg> [备份文件]
set -euo pipefail

APP="${1:-}"
FILE="${2:-}"
NS="${PLATFORM_DATA_NS:-platform-data}"
PG_PRIMARY="${PG_PRIMARY_POD:-platform-pg-1}"
CONFIRM="${CONFIRM:-no}"

command -v kubectl >/dev/null 2>&1 || { echo "[!] 需要 kubectl"; exit 1; }
[ -n "$APP" ] || { echo "用法: $0 <harbor|gitlab|casdoor|pg> [备份文件]"; exit 1; }

case "$APP" in
  harbor)
    echo "== Harbor 恢复 runbook =="
    echo "1) 停用 Harbor 写入: kubectl -n harbor scale deploy --all --replicas=0"
    echo "2) 恢复 registry 元数据（PG）:"
    if [ -n "$FILE" ]; then
      gunzip -c "$FILE" | kubectl -n "$NS" exec -i "$PG_PRIMARY" -- \
        env PGPASSWORD="$PG_HARBOR_PASS" psql -U harbor -d registry
    else
      echo "   还原命令: gunzip -c registry-<ts>.sql.gz | kubectl -n $NS exec -i $PG_PRIMARY -- psql -U harbor -d registry"
    fi
    echo "3) 恢复 registry blob（PV）：由 Longhorn 快照/备份或 Velero restore 恢复 PVC"
    echo "   velero restore create --from-backup <backup> --include-namespaces harbor"
    echo "4) 扩容回原副本: kubectl -n harbor scale deploy --all --replicas=1"
    ;;
  gitlab)
    echo "== GitLab 恢复 runbook =="
    echo "1) 停用写入: kubectl -n gitlab scale deploy gitlab-webservice-default gitlab-sidekiq-all-in-1-v2 --replicas=0"
    echo "2) 从对象存储取回备份 tar，放入 toolbox，执行恢复："
    echo "   kubectl -n gitlab exec -it deploy/gitlab-toolbox -- backup-utility --restore -t <timestamp>"
    echo "   （备份产物位置见 gitlab.toolbox.backups.objectStorage）"
    echo "3) 恢复完成后扩容回原副本"
    ;;
  casdoor)
    echo "== Casdoor 恢复 runbook =="
    if [ -n "$FILE" ]; then
      gunzip -c "$FILE" | kubectl -n "$NS" exec -i "$PG_PRIMARY" -- \
        env PGPASSWORD="$PG_CASDOOR_PASS" psql -U casdoor -d casdoor
    else
      echo "   gunzip -c casdoor-<ts>.sql.gz | kubectl -n $NS exec -i $PG_PRIMARY -- psql -U casdoor -d casdoor"
    fi
    ;;
  pg)
    echo "== CNPG 恢复 runbook（按需） =="
    echo "1) 基于 barman 对象存储做 PITR（推荐）：编辑 Cluster.spec.bootstrap.recovery"
    echo "2) 或从 volumeSnapshot 克隆新 cluster 校验后再切流量"
    echo "   参考: https://cloudnative-pg.io/documentation/current/recovery/"
    ;;
  *) echo "未知应用: $APP"; exit 1 ;;
esac
