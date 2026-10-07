#!/usr/bin/env bash
# 部署 kube-vip：生成静态 Pod 清单（ARP/L2），分发到控制面节点
# 说明：kube-vip 官方已不再附带发布二进制，这里直接写清单，镜像用本域预载地址
# 前置: install-common.sh 已装 kubelet；在 kubeadm init / join 之前执行
# 用法: setup-kube-vip.sh [节点IP ...]   # 不给参数则部署到起步控制面节点
set -euo pipefail

VIP="${CP_VIP:-192.168.124.30}"
KV_VERSION="${KUBE_VIP_VERSION:-1.2.4}"
IFACE="${VIP_IFACE:-}"
CP_INIT="${CP_INIT_COUNT:-1}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-}"

# 国内直连（避免环境代理）
if [ "${BYPASS_PROXY:-1}" = "1" ]; then
  export no_proxy='*' NO_PROXY='*'
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
fi

CP_IPS_ARR=(${CP_IPS:-192.168.124.10})

if [ "$#" -gt 0 ]; then
  NODES=("$@")
else
  NODES=(); i=0
  for ip in "${CP_IPS_ARR[@]}"; do
    [ "$i" -ge "$CP_INIT" ] && break
    NODES+=("$ip"); i=$((i+1))
  done
fi

remote() { ssh -o StrictHostKeyChecking=no root@"$1" "$2"; }

# 探测网卡
if [ -z "$IFACE" ]; then
  IFACE=$(remote "${NODES[0]}" "ip -o -4 addr show scope global | awk '{print \$2}' | head -1")
  echo "[+] 自动探测网卡: ${IFACE}"
fi

# 镜像地址：优先本域预载
if [ -n "$IMAGE_REPOSITORY" ]; then
  KVIP_IMAGE="${IMAGE_REPOSITORY}/kube-vip:v${KV_VERSION}"
else
  KVIP_IMAGE="ghcr.io/kube-vip/kube-vip:v${KV_VERSION}"
fi

MANIFEST=/tmp/kube-vip.yaml
cat > "$MANIFEST" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-vip
  namespace: kube-system
  labels:
    app: kube-vip
spec:
  hostNetwork: true
  containers:
    - name: kube-vip
      image: ${KVIP_IMAGE}
      imagePullPolicy: IfNotPresent
      args: ["manager"]
      env:
        - { name: vip_arp,          value: "true" }
        - { name: port,             value: "6443" }
        - { name: vip_interface,    value: "${IFACE}" }
        # 注意: v1.x 已移除 vip_cidr，统一用 vip_subnet
        - { name: vip_subnet,       value: "32" }
        - { name: cp_enable,        value: "true" }
        - { name: cp_namespace,     value: "kube-system" }
        - { name: vip_leaderelection, value: "${VIP_LEADERELECTION:-true}" }
        - { name: vip_leaseduration,  value: "15" }
        - { name: vip_renewdeadline,  value: "10" }
        - { name: vip_retryperiod,    value: "2" }
        - { name: address,          value: "${VIP}" }
        - { name: prometheus_server, value: ":2112" }
      securityContext:
        capabilities:
          add: ["NET_ADMIN", "NET_RAW", "SYS_TIME"]
      volumeMounts:
        - { name: kubeconfig, mountPath: /.kube/config }
  volumes:
    - name: kubeconfig
      hostPath:
        path: /etc/kubernetes/kube-vip.conf
        type: FileOrCreate
EOF

echo "[+] 生成 kube-vip 清单 (VIP=${VIP}, iface=${IFACE}, image=${KVIP_IMAGE})"

for ip in "${NODES[@]}"; do
  echo "[+] 部署 kube-vip 到 ${ip}..."
  remote "$ip" "mkdir -p /etc/kubernetes/manifests"
  # 生成本节点 kubeconfig（server 指向本节点 IP，避免经 VIP 的循环依赖）
  remote "$ip" "test -f /etc/kubernetes/admin.conf && \
    sed 's#server: https://[^ ]*#server: https://${ip}:6443#' /etc/kubernetes/admin.conf > /etc/kubernetes/kube-vip.conf" \
    || echo "[!] ${ip} 无 admin.conf（请先 kubeadm init）"
  NODE_MANIFEST="/tmp/kube-vip-${ip}.yaml"
  sed "s|__NODE_IP__|${ip}|g" "$MANIFEST" > "$NODE_MANIFEST"
  scp -o StrictHostKeyChecking=no -q "$NODE_MANIFEST" root@"$ip":/etc/kubernetes/manifests/kube-vip.yaml
  rm -f "$NODE_MANIFEST"
done

echo "[+] kube-vip 部署完成。VIP=${VIP}  endpoint=${CP_ENDPOINT:-$VIP}"
