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

  HPASS_B64="$(printf '%s' "${HARBOR_ROBOT_PASS:-}" | base64 -w0)"
  ssh -o StrictHostKeyChecking=no root@"${ip}" \
    "K8S_VERSION=${K8S_VERSION} K8S_MINOR=${K8S_MINOR} K8S_APT_REPO_URL=${K8S_APT_REPO_URL:-} IMAGE_REPOSITORY=${IMAGE_REPOSITORY:-} HARBOR_HOST=${HARBOR_HOST:-} HARBOR_PROJECT=${HARBOR_PROJECT:-baokuaiyun} HPASS_B64=${HPASS_B64} NODE_IP=${ip} bash -s" <<'NODE'
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

# Longhorn 依赖 open-iscsi
apt-get install -y -qq open-iscsi
systemctl enable --now iscsid 2>/dev/null || true

# containerd 配置 SystemdCgroup
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml 2>/dev/null || true
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml 2>/dev/null || true
# CNI 插件目录：Debian 默认 /usr/lib/cni，但 kubernetes-cni/Cilium 装在 /opt/cni/bin
sed -i 's|bin_dir = "/usr/lib/cni"|bin_dir = "/opt/cni/bin"|' /etc/containerd/config.toml 2>/dev/null || true

# sandbox_image 必须与 kubeadm 期望的 pause 一致，并指向本域预载镜像
# （containerd 默认 registry.k8s.io/pause:3.8，会去公网拉取失败）
PAUSE_TAG=$(kubeadm config images list --kubernetes-version "v${KV}" 2>/dev/null | sed -n 's|.*/pause:||p' | head -1)
if [ -n "${PAUSE_TAG}" ]; then
  SANDBOX="${IMAGE_REPOSITORY:+${IMAGE_REPOSITORY}/}pause:${PAUSE_TAG}"
  sed -i "s|sandbox_image = .*|sandbox_image = \"${SANDBOX}\"|" /etc/containerd/config.toml
  echo "[+] sandbox_image -> ${SANDBOX}"
fi

# Harbor registry 配置（自签 insecure + robot 认证），节点可从本域 Harbor 拉取
if [ -n "${HARBOR_HOST:-}" ]; then
  RPASS="$(printf '%s' "${HPASS_B64:-}" | base64 -d 2>/dev/null || true)"
  # robot 用户名在节点内用 PROJECT 拼接，避免 $ 经多级 shell 传递被吞掉
  RUSER='robot$'"${HARBOR_PROJECT:-baokuaiyun}"'+pushpull'
  # 先移除任何既有 harbor 配置块（幂等），再写回正确配置
  python3 - "$HARBOR_HOST" <<'PYCLEAN' 2>/dev/null || true
import sys
h = sys.argv[1]
p = "/etc/containerd/config.toml"
marker = '[plugins."io.containerd.grpc.v1.cri".registry.configs."' + h + '"'
out, skip = [], False
for line in open(p):
    if line.lstrip().startswith('['):
        skip = line.strip().startswith(marker)
        if skip:
            continue
    if not skip:
        out.append(line)
open(p, "w").write("".join(out))
PYCLEAN
  {
    echo ""
    echo "[plugins.\"io.containerd.grpc.v1.cri\".registry.configs.\"${HARBOR_HOST}\".tls]"
    echo "  insecure_skip_verify = true"
    echo "[plugins.\"io.containerd.grpc.v1.cri\".registry.configs.\"${HARBOR_HOST}\".auth]"
    echo "  username = \"${RUSER}\""
    echo "  password = \"${RPASS}\""
  } >> /etc/containerd/config.toml
  echo "[+] containerd 已配置 Harbor: ${HARBOR_HOST} (user=${RUSER})"
fi

systemctl restart containerd
systemctl enable containerd
systemctl enable --now kubelet

echo "[+] 节点 ${NODE_IP} 安装完成"
NODE
}

wait_ssh() {
  local ip=$1 i=0
  echo "[+] 等待 SSH 就绪: ${ip}"
  while [ "$i" -lt 60 ]; do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=4 -o BatchMode=yes \
         root@"$ip" true >/dev/null 2>&1; then
      return 0
    fi
    i=$((i+1)); sleep 5
  done
  echo "[!] ${ip} SSH 超时"; return 1
}

for ip in "${ALL_IPS[@]}"; do
  wait_ssh "$ip"
  install_node "$ip"
done

echo "[+] 所有目标节点安装完成"
