#!/usr/bin/env bash
# 在节点安装 containerd + kubelet/kubeadm/kubectl
# 前置: VM 已创建且 cloud-init 完成（SSH 可用）
# 用法: install-common.sh [节点IP ...]   # 不给参数则安装起步节点（CP_INIT_COUNT+WK_INIT_COUNT）
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-1.31.0}"
K8S_MINOR="${K8S_VERSION%.*}"   # 1.31

# 目标节点列表
if [ "$#" -gt 0 ]; then
  ALL_IPS=("$@")
else
  ALL_IPS=()
  i=0; for ip in ${CP_IPS:-192.168.124.10 192.168.124.11 192.168.124.12}; do
    [ "$i" -ge "${CP_INIT_COUNT:-1}" ] && break; ALL_IPS+=("$ip"); i=$((i+1));
  done
  i=0; for ip in ${WK_IPS:-192.168.124.20 192.168.124.21}; do
    [ "$i" -ge "${WK_INIT_COUNT:-1}" ] && break; ALL_IPS+=("$ip"); i=$((i+1));
  done
fi

install_node() {
  local ip=$1
  echo "[+] 安装节点: ${ip}"

  # 等待 cloud-init 完成（否则 gnupg/containerd 等包可能尚未安装）
  echo "[+] 等待 cloud-init 完成..."
  ssh -o StrictHostKeyChecking=no root@"${ip}" 'cloud-init status --wait >/dev/null 2>&1' || true

  ssh -o StrictHostKeyChecking=no root@"${ip}" \
    "K8S_VERSION=${K8S_VERSION} K8S_MINOR=${K8S_MINOR} K8S_APT_REPO_URL=${K8S_APT_REPO_URL:-} NODE_IP=${ip} bash -s" <<'NODE'
set -euo pipefail
KV=${K8S_VERSION}
KM=${K8S_MINOR}
REPO="${K8S_APT_REPO_URL:-https://pkgs.k8s.io/core:/stable:/v${KM}/deb/}"
REPO="${REPO%/}"

# k8s apt 源（默认阿里云镜像；末尾 /deb/）
# 注意：k8s 上游 Release 用 v3 签名，Debian 13 的 sqv 自 2026-02 起拒绝，故 trusted=yes
echo "deb [trusted=yes] ${REPO}/ /" > /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet=${KV}-1.1 kubeadm=${KV}-1.1 kubectl=${KV}-1.1
apt-mark hold kubelet kubeadm kubectl

# containerd 配置 SystemdCgroup
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml 2>/dev/null || true
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml 2>/dev/null || true
systemctl enable --now containerd
systemctl enable --now kubelet

echo "[+] 节点 ${NODE_IP} 安装完成"
NODE
}

for ip in "${ALL_IPS[@]}"; do
  install_node "$ip"
done

echo "[+] 所有目标节点安装完成"
