#!/usr/bin/env bash
# Kubernetes 集群升级脚本
# 用法: upgrade.sh <新版本>  # 例: bash upgrade.sh 1.32.0
set -euo pipefail

NEW_VERSION="${1:-1.32.0}"
CUR_VERSION="${CUR_VERSION:-1.31.0}"

CP_IPS=(192.168.124.10 192.168.124.11 192.168.124.12)
WK_IPS=(192.168.124.20 192.168.124.21)

echo "[+] 升级 Kubernetes: ${CUR_VERSION} → ${NEW_VERSION}"

# 升级第一个控制面节点
echo "[+] 升级 cp-1..."
ssh root@${CP_IPS[0]} "bash -s" <<NODE
set -euo pipefail
apt-get update -qq
apt-get install -y -qq kubeadm=${NEW_VERSION}-1.1
kubeadm upgrade apply v${NEW_VERSION} -y
NODE

# 升级其余控制面节点
for i in 1 2; do
  ip=${CP_IPS[$i]}
  echo "[+] 升级 ${ip}..."
  kubectl drain "$(ssh root@$ip hostname)" --ignore-daemonsets --delete-emptydir-data 2>/dev/null || true
  ssh root@$ip "bash -s" <<NODE
set -euo pipefail
apt-get install -y -qq kubeadm=${NEW_VERSION}-1.1
kubeadm upgrade node
apt-get install -y -qq kubelet=${NEW_VERSION}-1.1 kubectl=${NEW_VERSION}-1.1
systemctl restart kubelet
NODE
  kubectl uncordon "$(ssh root@$ip hostname)" 2>/dev/null || true
done

# 升级 worker 节点
for ip in "${WK_IPS[@]}"; do
  echo "[+] 升级 ${ip}..."
  ssh root@$ip "bash -s" <<NODE
set -euo pipefail
apt-get install -y -qq kubeadm=${NEW_VERSION}-1.1
kubeadm upgrade node
apt-get install -y -qq kubelet=${NEW_VERSION}-1.1
systemctl restart kubelet
NODE
done

echo "[+] 升级完成，验证:"
kubectl get nodes
