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

# 引导期先把 VIP 绑到本节点网卡，避免 kube-vip 读 admin.conf(server=VIP) 的循环依赖
CP_VIP="${CP_VIP:-}"
if [ -n "$CP_VIP" ]; then
  IFACE="${VIP_IFACE:-enp1s0}"
  ssh -o StrictHostKeyChecking=no root@"${CP1_IP}" \
    "ip addr add ${CP_VIP}/32 dev ${IFACE} 2>/dev/null || true; ip -br addr show ${IFACE} | grep -q ${CP_VIP} && echo '[+] VIP ${CP_VIP} 已就绪'" || true
fi

ssh -o StrictHostKeyChecking=no root@"${CP1_IP}" \
  "ENDPOINT=${ENDPOINT} POD_CIDR=${POD_CIDR} SERVICE_CIDR=${SERVICE_CIDR} \
   K8S_VERSION=${K8S_VERSION} K8S_IMAGE_REPOSITORY=${K8S_IMAGE_REPOSITORY} CP_VIP=${CP_VIP:-} \
   WK_INIT_COUNT=${WK_INIT_COUNT:-0} bash -s" <<'NODE'
set -euo pipefail

ARGS=(init
  --control-plane-endpoint="${ENDPOINT}"
  --pod-network-cidr="${POD_CIDR}"
  --service-cidr="${SERVICE_CIDR}"
  --kubernetes-version="v${K8S_VERSION}"
  --cri-socket="unix:///run/containerd/containerd.sock"
  --upload-certs)

# 把 VIP 加入 apiserver 证书 SAN（否则经 VIP 访问会 TLS 校验失败）
[ -n "${CP_VIP:-}" ] && ARGS+=(--apiserver-cert-extra-sans="${CP_VIP}")

if [ -n "${K8S_IMAGE_REPOSITORY:-}" ]; then
  ARGS+=(--image-repository="${K8S_IMAGE_REPOSITORY}")
fi

kubeadm "${ARGS[@]}" --v=5 2>&1 | tee /root/kubeadm-init.log

mkdir -p $HOME/.kube
cp /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# 单节点起步：唯一节点需承载业务负载，移除 control-plane 污点
if [ "${WK_INIT_COUNT:-0}" -lt 1 ]; then
  echo "[+] 单节点模式：等待节点注册并移除 control-plane 污点..."
  for i in $(seq 1 30); do
    if kubectl --kubeconfig=/etc/kubernetes/admin.conf get node >/dev/null 2>&1; then break; fi
    sleep 2
  done
  kubectl --kubeconfig=/etc/kubernetes/admin.conf taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null \
    && echo "[+] 已移除 control-plane 污点（业务可调度到本节点）" \
    || echo "[!] 移除污点失败（可稍后手动: kubectl taint nodes --all node-role.kubernetes.io/control-plane-)"
fi

echo "[+] 控制面初始化完成"
echo "[+] init 日志: /root/kubeadm-init.log"
NODE

# 导出并【合并】kubeconfig（独立脚本，绝不覆盖用户已有 ~/.kube/config）
bash "$(cd "$(dirname "$0")" && pwd)/export-kubeconfig.sh" "${CP1_IP}"
CONTEXT="${K8S_CONTEXT:-kvm-test}"

# 持久化 worker join 命令（24h 有效）
WORKER_JOIN=$(ssh -o StrictHostKeyChecking=no root@"${CP1_IP}" 'kubeadm token create --print-join-command')
mkdir -p /root/k8s/.join
echo "$WORKER_JOIN" > /root/k8s/.join/worker-join.sh
chmod +x /root/k8s/.join/worker-join.sh

echo "[+] kubeconfig 已合并进 ~/.kube/config，context=${CONTEXT}（当前已切换）"
echo "    独立文件: ~/.kube/${CONTEXT}.config"
echo "[+] worker join 命令已保存到 .join/worker-join.sh"
echo ""
echo "[+] 后续步骤:"
echo "    make k8s-join                 # 加入起步 worker"
echo "    make scale-out                # 扩容到 3CP+2W"
echo "    make join-cp IDX=2            # 单独加入控制面 cp-2"
