#!/usr/bin/env bash
# 应用级一致性备份编排（L1 不可再生数据）
#   - CNPG：触发一次 on-demand Backup（快照 + barman 异地）
#   - Harbor：pg_dump registry（元数据）+ 依赖 Longhorn/Velero 备份 registry blob
#   - GitLab：toolbox backup-utility（PG + Gitaly + 对象存储，产物入对象存储）
#   - Casdoor：pg_dump casdoor
# 用法: bash platform/backup/backup.sh [all|pg|harbor|gitlab|casdoor]
set -euo pipefail

NS="${PLATFORM_DATA_NS:-platform-data}"
PG_PRIMARY="${PG_PRIMARY_POD:-platform-pg-1}"
WHICH="${1:-all}"
STAMP="$(date +%Y%m%d-%H%M%S)"

command -v kubectl >/dev/null 2>&1 || { echo "[!] 需要 kubectl"; exit 1; }

log() { echo "[+] $*"; }

dump_pg() {
  local db="$1" user="$2" pass="$3" out="$4"
  log "pg_dump ${db} (user=${user}) -> ${out}"
  kubectl -n "$NS" exec "$PG_PRIMARY" -- env PGPASSWORD="$pass" \
    pg_dump -h 127.0.0.1 -p 5432 -U "$user" -d "$db" --no-owner --no-privileges \
    | gzip > "$out"
  log "  完成 $(du -h "$out" | cut -f1)"
}

backup_cnpg() {
  local name="platform-pg-manual-${STAMP}"
  log "触发 CNPG on-demand Backup: ${name}"
  kubectl -n "$NS" apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${name}
  namespace: ${NS}
spec:
  cluster:
    name: platform-pg
  method: volumeSnapshot
EOF
  log "  查看: kubectl -n ${NS} get backup ${name}"
}

backup_harbor() {
  local dir="${BACKUP_OUT:-/data/backups}/harbor"
  mkdir -p "$dir"
  dump_pg "registry" "harbor" "${PG_HARBOR_PASS:?PG_HARBOR_PASS 未设置}" \
    "${dir}/registry-${STAMP}.sql.gz"
  log "Harbor registry 镜像 blob 由 Longhorn backupTarget/Velero 覆盖（PV 级）"
}

backup_gitlab() {
  log "GitLab toolbox 一致性备份（PG + Gitaly + 对象存储）"
  if ! kubectl -n gitlab get deploy gitlab-toolbox >/dev/null 2>&1; then
    echo "[!] 未找到 gitlab-toolbox，跳过"; return
  fi
  kubectl -n gitlab exec deploy/gitlab-toolbox -- backup-utility
  log "  产物已按 gitlab.toolbox.backups.objectStorage 配置落对象存储"
}

backup_casdoor() {
  local dir="${BACKUP_OUT:-/data/backups}/casdoor"
  mkdir -p "$dir"
  dump_pg "casdoor" "casdoor" "${PG_CASDOOR_PASS:?PG_CASDOOR_PASS 未设置}" \
    "${dir}/casdoor-${STAMP}.sql.gz"
}

case "$WHICH" in
  all)     backup_cnpg; backup_harbor; backup_gitlab; backup_casdoor ;;
  pg)      backup_cnpg ;;
  harbor)  backup_harbor ;;
  gitlab)  backup_gitlab ;;
  casdoor) backup_casdoor ;;
  *) echo "用法: $0 [all|pg|harbor|gitlab|casdoor]"; exit 1 ;;
esac

log "备份编排完成。异地校验: make verify-storage"
