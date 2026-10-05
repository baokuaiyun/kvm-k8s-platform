#!/usr/bin/env bash
# etcd 快照恢复
# 用法: bash restore-etcd.sh <备份文件路径> [cp_ip]
# 警告: 恢复会中断集群，需谨慎执行
set -euo pipefail

BACKUP_FILE="${1:-}"
CP_IP="${2:-192.168.124.10}"

[ -z "$BACKUP_FILE" ] && { echo "用法: bash restore-etcd.sh <备份文件.db> [cp_ip]"; exit 1; }
[ -f "$BACKUP_FILE" ] || { echo "[!] 备份文件不存在: $BACKUP_FILE"; exit 1; }

echo "[!] 恢复 etcd 将中断集群，确认继续? (输入 yes)"
read -r confirm
[ "$confirm" = "yes" ] || { echo "已取消"; exit 0; }

echo "[+] 上传备份到节点 ${CP_IP}..."
scp -o StrictHostKeyChecking=no "$BACKUP_FILE" root@"${CP_IP}":/tmp/etcd-restore.db

echo "[+] 执行恢复..."
ssh -o StrictHostKeyChecking=no root@"${CP_IP}" "bash -s" <<'NODE'
set -euo pipefail
# 备份当前 etcd 数据目录
mv /var/lib/etcd /var/lib/etcd.bak.$(date +%Y%m%d%H%M%S)

# 用快照恢复
etcdctl snapshot restore /tmp/etcd-restore.db \
  --name=$(hostname) \
  --initial-cluster=$(hostname)=https://127.0.0.1:2380 \
  --initial-advertise-peer-urls=https://127.0.0.1:2380 \
  --data-dir=/var/lib/etcd-restore

mv /var/lib/etcd-restore /var/lib/etcd
chown -R etcd:etcd /var/lib/etcd 2>/dev/null || true

echo "[+] 恢复完成，重启 etcd (kubeadm 静态 Pod 自动重启)"
NODE

echo "[+] etcd 恢复执行完成，等待 etcd Pod 重启..."
