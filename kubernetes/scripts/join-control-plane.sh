#!/usr/bin/env bash
# 加入控制面节点（扩容 HA）
# 用法: join-control-plane.sh <cp-node-name>
# 说明: certificate-key 有效期 2h，本脚本每次现取现用
#       kube-vip 在 join 之后再部署（需要 admin.conf 生成 kube-vip.conf）
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

echo "[+] 生成 certificate-key..."
CERT_KEY=$(ssh -o StrictHostKeyChecking=no root@"$CP1_IP" \
  'kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1')
JOIN=$(ssh -o StrictHostKeyChecking=no root@"$CP1_IP" 'kubeadm token create --print-join-command')

echo "[+] 加入控制面 ${NODE}..."
ssh -o StrictHostKeyChecking=no root@"$IP" \
  "$JOIN --control-plane --certificate-key ${CERT_KEY}"

# join 后确保 admin.conf 存在（供 kube-vip 生成 kube-vip.conf）
if ! ssh -o StrictHostKeyChecking=no root@"$IP" 'test -f /etc/kubernetes/admin.conf'; then
  echo "[+] ${NODE} 无 admin.conf，从 ${CP1_IP} 拷贝..."
  ssh -o StrictHostKeyChecking=no root@"$CP1_IP" 'cat /etc/kubernetes/admin.conf' \
    | ssh -o StrictHostKeyChecking=no root@"$IP" 'cat > /etc/kubernetes/admin.conf'
fi

echo "[+] 部署 kube-vip（join 之后，使用本节点 kubeconfig）..."
bash "${SCRIPT_DIR}/setup-kube-vip.sh" "$IP"

echo "[+] ${NODE} 已加入控制面"
