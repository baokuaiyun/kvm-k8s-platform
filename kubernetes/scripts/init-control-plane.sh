#!/usr/bin/env bash
# 初始化控制面（cp-1）
# 前置: install-common.sh 已完成
set -euo pipefail

CP1_IP="${CP1_IP:-192.168.124.10}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
ENDPOINT="${CP1_IP}:6443"

echo "[+] 初始化控制面: ${CP1_IP}"

ssh -o StrictHostKeyChecking=no root@"${CP1_IP}" \
  "POD_CIDR=${POD_CIDR} SERVICE_CIDR=${SERVICE_CIDR} ENDPOINT=${ENDPOINT} bash -s" <<'NODE'
set -euo pipefail

kubeadm init \
  --control-plane-endpoint=${ENDPOINT} \
  --pod-network-cidr=${POD_CIDR} \
  --service-cidr=${SERVICE_CIDR} \
  --upload-certs \
  --v=5 2>&1 | tee /root/kubeadm-init.log

mkdir -p $HOME/.kube
cp /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

echo "[+] 控制面初始化完成"
echo "[+] 保存 init 日志到 /root/kubeadm-init.log"
NODE

# 拉取 kubeconfig 到宿主机
mkdir -p ~/.kube
scp -o StrictHostKeyChecking=no root@"${CP1_IP}":/etc/kubernetes/admin.conf ~/.kube/config 2>/dev/null || \
  scp -o StrictHostKeyChecking=no root@"${CP1_IP}":/root/.kube/config ~/.kube/config

echo "[+] kubeconfig 已保存到 ~/.kube/config"
echo ""
echo "[+] 后续步骤:"
echo "    1. 获取 control-plane join 命令（cp-2/cp-3 加入）:"
echo "       ssh root@${CP1_IP} 'kubeadm token create --print-join-command'"
echo "    2. 获取 worker join 命令:"
echo "       ssh root@${CP1_IP} 'kubeadm token create --print-join-command'"
echo "    3. 安装 CNI: make cni"
