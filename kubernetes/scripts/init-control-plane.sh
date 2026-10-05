#!/usr/bin/env bash
# 初始化控制面（首个 CP 节点）
# 前置: install-common.sh 完成、setup-kube-vip.sh 已放置 VIP
# endpoint 使用 CP_ENDPOINT（内网 DNS）而非单机 IP，便于后续扩容 HA
set -euo pipefail

CP1_IP="${CP_IPS%% *}"
CP1_IP="${CP1_IP:-192.168.124.10}"
ENDPOINT="${CP_ENDPOINT:-k8s-api.test.baokuaiyun.com}:${CP_ENDPOINT_PORT:-6443}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
K8S_VERSION="${K8S_VERSION:-1.31.0}"
# 本域镜像仓库前缀（镜像已预载，kubeadm 命中本地不回源）
K8S_IMAGE_REPOSITORY="${K8S_IMAGE_REPOSITORY:-${IMAGE_REPOSITORY:-}}"

echo "[+] 初始化控制面: ${CP1_IP} (endpoint=${ENDPOINT})"
echo "[+] image-repository: ${K8S_IMAGE_REPOSITORY:-<默认 registry.k8s.io>}"

ssh -o StrictHostKeyChecking=no root@"${CP1_IP}" \
  "ENDPOINT=${ENDPOINT} POD_CIDR=${POD_CIDR} SERVICE_CIDR=${SERVICE_CIDR} \
   K8S_VERSION=${K8S_VERSION} K8S_IMAGE_REPOSITORY=${K8S_IMAGE_REPOSITORY} bash -s" <<'NODE'
set -euo pipefail

ARGS=(init
  --control-plane-endpoint="${ENDPOINT}"
  --pod-network-cidr="${POD_CIDR}"
  --service-cidr="${SERVICE_CIDR}"
  --kubernetes-version="v${K8S_VERSION}"
  --cri-socket="unix:///run/containerd/containerd.sock"
  --upload-certs)

if [ -n "${K8S_IMAGE_REPOSITORY:-}" ]; then
  ARGS+=(--image-repository="${K8S_IMAGE_REPOSITORY}")
fi

kubeadm "${ARGS[@]}" --v=5 2>&1 | tee /root/kubeadm-init.log

mkdir -p $HOME/.kube
cp /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

echo "[+] 控制面初始化完成"
echo "[+] init 日志: /root/kubeadm-init.log"
NODE

# 拉取 kubeconfig 到宿主机
mkdir -p ~/.kube
scp -o StrictHostKeyChecking=no root@"${CP1_IP}":/etc/kubernetes/admin.conf ~/.kube/config 2>/dev/null || \
  scp -o StrictHostKeyChecking=no root@"${CP1_IP}":/root/.kube/config ~/.kube/config

# 持久化 worker join 命令（24h 有效）
WORKER_JOIN=$(ssh -o StrictHostKeyChecking=no root@"${CP1_IP}" 'kubeadm token create --print-join-command')
mkdir -p /root/k8s/.join
echo "$WORKER_JOIN" > /root/k8s/.join/worker-join.sh
chmod +x /root/k8s/.join/worker-join.sh

echo "[+] kubeconfig 已保存到 ~/.kube/config"
echo "[+] worker join 命令已保存到 .join/worker-join.sh"
echo ""
echo "[+] 后续步骤:"
echo "    make k8s-join                 # 加入起步 worker"
echo "    make scale-out                # 扩容到 3CP+2W"
echo "    make join-cp IDX=2            # 单独加入控制面 cp-2"
