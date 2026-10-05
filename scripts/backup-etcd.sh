#!/usr/bin/env bash
# etcd 定时快照备份
# 用法: bash backup-etcd.sh [cp_ip]
# crontab: 0 2 * * * /root/k8s/scripts/backup-etcd.sh
set -euo pipefail

CP_IP="${1:-192.168.124.10}"
BACKUP_DIR="${BACKUP_DIR:-/data/backups/etcd}"
DATE=$(date +%Y%m%d-%H%M%S)
RETENTION_DAYS=7

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

echo "[+] 备份完成: ${BACKUP_DIR}/etcd-${DATE}.db"

# 清理超过保留期的备份
find "$BACKUP_DIR" -name "*.db" -mtime +${RETENTION_DAYS} -delete

echo "[+] 当前备份列表:"
ls -lh "$BACKUP_DIR" | tail -5
