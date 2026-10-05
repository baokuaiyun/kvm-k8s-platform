#!/usr/bin/env bash
# 部署 kube-vip：在控制面节点放置静态 Pod，提供 control-plane-endpoint 的 VIP
# 前置: install-common.sh 已安装 kubelet；在 kubeadm init / join 之前执行
# 用法: setup-kube-vip.sh [节点IP ...]   # 不给参数则部署到起步控制面节点
set -euo pipefail

VIP="${CP_VIP:-192.168.124.30}"
KV_VERSION="${KUBE_VIP_VERSION:-0.8.7}"
IFACE="${VIP_IFACE:-}"
CP_INIT="${CP_INIT_COUNT:-1}"

CP_IPS_ARR=(${CP_IPS:-192.168.124.10})

# 目标节点：命令行参数优先，否则取前 CP_INIT 个控制面
if [ "$#" -gt 0 ]; then
  NODES=("$@")
else
  NODES=()
  i=0
  for ip in "${CP_IPS_ARR[@]}"; do
    [ "$i" -ge "$CP_INIT" ] && break
    NODES+=("$ip"); i=$((i+1))
  done
fi

remote() { ssh -o StrictHostKeyChecking=no root@"$1" "$2"; }

# 探测网卡（未显式指定时）
if [ -z "$IFACE" ]; then
  IFACE=$(remote "${NODES[0]}" "ip -o -4 addr show scope global | awk '{print \$2}' | head -1")
  echo "[+] 自动探测网卡: ${IFACE}"
fi

# 下载 kube-vip 二进制（宿主机）
BIN=/tmp/kube-vip
if [ ! -x "$BIN" ]; then
  echo "[+] 下载 kube-vip v${KV_VERSION}..."
  curl -fsSL -o "$BIN" \
    "https://github.com/kube-vip/kube-vip/releases/download/v${KV_VERSION}/kube-vip-linux-amd64"
  chmod +x "$BIN"
fi

# 生成静态 Pod 清单（ARP/L2 模式）
MANIFEST=/tmp/kube-vip.yaml
"$BIN" manifest pod \
  --interface "$IFACE" \
  --address "$VIP" \
  --controlplane \
  --services \
  --arp \
  --leaderElection > "$MANIFEST"

# 镜像改写为本域地址（镜像已预载）
if [ -n "${IMAGE_REPOSITORY:-}" ]; then
  sed -i "s|ghcr.io/kube-vip/kube-vip:v${KV_VERSION}|${IMAGE_REPOSITORY}/kube-vip:v${KV_VERSION}|g" "$MANIFEST"
  echo "[+] kube-vip 镜像 -> ${IMAGE_REPOSITORY}/kube-vip:v${KV_VERSION}"
fi
echo "[+] 生成 kube-vip 清单 (VIP=${VIP}, iface=${IFACE})"

# 分发到目标控制面节点
for ip in "${NODES[@]}"; do
  echo "[+] 部署 kube-vip 到 ${ip}..."
  remote "$ip" "mkdir -p /etc/kubernetes/manifests"
  scp -o StrictHostKeyChecking=no "$MANIFEST" root@"$ip":/etc/kubernetes/manifests/kube-vip.yaml
done

echo "[+] kube-vip 部署完成。VIP=${VIP}  endpoint=${CP_ENDPOINT:-$VIP}"
