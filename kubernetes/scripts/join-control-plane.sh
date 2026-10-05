#!/usr/bin/env bash
# 加入控制面节点（扩容 HA）
# 用法: join-control-plane.sh <cp-node-name>
# 说明: certificate-key 有效期 2h，本脚本每次现取现用
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE="${1:?用法: join-control-plane.sh <cp-node-name>}"
CP1_IP="${CP_IPS%% *}"; CP1_IP="${CP1_IP:-192.168.124.10}"

CP_NAMES_ARR=(${CP_NAMES:-})
CP_IPS_ARR=(${CP_IPS:-})

IP=""
i=0
for n in "${CP_NAMES_ARR[@]}"; do
  [ "$n" = "$NODE" ] && { IP="${CP_IPS_ARR[$i]}"; break; }
  i=$((i+1))
done
[ -z "$IP" ] && { echo "[!] 未知控制面节点: $NODE"; exit 1; }

echo "[+] 安装 kubelet/kubeadm 到 ${NODE} (${IP})..."
bash "${SCRIPT_DIR}/install-common.sh" "$IP"

echo "[+] 放置 kube-vip 清单到 ${NODE}..."
bash "${SCRIPT_DIR}/setup-kube-vip.sh" "$IP"

echo "[+] 生成 certificate-key..."
CERT_KEY=$(ssh -o StrictHostKeyChecking=no root@"$CP1_IP" \
  'kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1')
JOIN=$(ssh -o StrictHostKeyChecking=no root@"$CP1_IP" 'kubeadm token create --print-join-command')

echo "[+] 加入控制面 ${NODE}..."
ssh -o StrictHostKeyChecking=no root@"$IP" \
  "$JOIN --control-plane --certificate-key ${CERT_KEY}"

echo "[+] ${NODE} 已加入控制面"
