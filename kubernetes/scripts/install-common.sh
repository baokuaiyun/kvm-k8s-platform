#!/usr/bin/env bash
# 在所有节点安装 containerd + kubelet/kubeadm
# 前置: VM 已创建且 cloud-init 完成（SSH 可用）
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-1.31.0}"
K8S_MINOR="${K8S_VERSION%.*}"   # 1.31

# 节点 IP 列表（演练环境固定）
CP_IPS=(192.168.124.10 192.168.124.11 192.168.124.12)
WK_IPS=(192.168.124.20 192.168.124.21)
ALL_IPS=("${CP_IPS[@]}" "${WK_IPS[@]}")

install_node() {
  local ip=$1
  echo "[+] 安装节点: ${ip}"

  ssh -o StrictHostKeyChecking=no root@"${ip}" \
    "K8S_VERSION=${K8S_VERSION} bash -s" <<'NODE'
set -euo pipefail
KV=${K8S_VERSION}

# k8s apt 源
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key" | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet=${KV}-1.1 kubeadm=${KV}-1.1 kubectl=${KV}-1.1
apt-mark hold kubelet kubeadm kubectl

# containerd 配置 SystemdCgroup
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml 2>/dev/null || true
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml 2>/dev/null || true
systemctl enable --now containerd
systemctl enable --now kubelet

echo "[+] 节点 ${ip} 安装完成"
NODE
}

for ip in "${ALL_IPS[@]}"; do
  install_node "$ip"
done

echo "[+] 所有节点安装完成"
