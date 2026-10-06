#!/usr/bin/env bash
# etcd 定时快照备份
# 用法: bash backup-etcd.sh [cp_ip]
# crontab: 0 2 * * * /root/k8s/scripts/backup-etcd.sh
set -euo pipefail

CP_IP="${1:-192.168.124.10}"
BACKUP_DIR="${BACKUP_DIR:-/data/backups/etcd}"
# 异地目录（NFS 挂载点）或 rsync 远端；二者可任一，留空则仅本地
OFFSITE_DIR="${OFFSITE_DIR:-/data/backups/etcd-offsite}"
OFFSITE_REMOTE="${OFFSITE_REMOTE:-}"
DATE=$(date +%Y%m%d-%H%M%S)
RETENTION_DAYS="${RETENTION_DAYS:-7}"
OFFSITE_RETENTION_DAYS="${OFFSITE_RETENTION_DAYS:-30}"

mkdir -p "$BACKUP_DIR"

echo "[+] 备份 etcd (节点: ${CP_IP})..."

ssh -o StrictHostKeyChecking=no root@"${CP_IP}" "bash -s" <<NODE
set -euo pipefail
DATE=${DATE}
etcdctl snapshot save /tmp/etcd-\${DATE}.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key 2>/dev/null || \
etcdctl snapshot save /tmp/etcd-\${DATE}.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/peer.crt \
  --key=/etc/kubernetes/pki/etcd/peer.key
echo "[+] 节点快照完成: /tmp/etcd-\${DATE}.db"
NODE

scp -o StrictHostKeyChecking=no root@"${CP_IP}":/tmp/etcd-"${DATE}".db "$BACKUP_DIR/"
ssh -o StrictHostKeyChecking=no root@"${CP_IP}" "rm -f /tmp/etcd-${DATE}.db"

echo "[+] 本地备份完成: ${BACKUP_DIR}/etcd-${DATE}.db"

# 异地副本：先 NFS 目录，再 rsync 远端（若配置）
if [ -n "$OFFSITE_DIR" ]; then
  mkdir -p "$OFFSITE_DIR"
  cp -f "${BACKUP_DIR}/etcd-${DATE}.db" "$OFFSITE_DIR/"
  echo "[+] 异地(NFS/目录)副本: ${OFFSITE_DIR}/etcd-${DATE}.db"
  find "$OFFSITE_DIR" -name "*.db" -mtime +${OFFSITE_RETENTION_DAYS} -delete
fi
if [ -n "$OFFSITE_REMOTE" ]; then
  rsync -az --partial "${BACKUP_DIR}/etcd-${DATE}.db" "$OFFSITE_REMOTE/" && \
    echo "[+] 异地(rsync)副本: ${OFFSITE_REMOTE}/etcd-${DATE}.db"
fi

# 写入最近成功时间，供 node-exporter textfile / 告警核对
if [ -d /var/lib/node_exporter/textfile ]; then
  printf 'etcd_backup_last_success_timestamp_seconds %s\n' "$(date +%s)" \
    > /var/lib/node_exporter/textfile/etcd_backup.prom.tmp && \
    mv /var/lib/node_exporter/textfile/etcd_backup.prom.tmp \
       /var/lib/node_exporter/textfile/etcd_backup.prom
fi

# 清理超过保留期的本地备份
find "$BACKUP_DIR" -name "*.db" -mtime +${RETENTION_DAYS} -delete

echo "[+] 当前备份列表:"
ls -lh "$BACKUP_DIR" | tail -5
