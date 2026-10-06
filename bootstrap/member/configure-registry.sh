#!/usr/bin/env bash
# 成员集群：把节点 containerd 指向"本"Harbor（insecure + robot 认证）
set -euo pipefail
source "$(dirname "$0")/../lib.sh"

HUSER="robot\$${HARBOR_PROJECT}+pushpull"
HPASS_B64="$(printf '%s' "$HARBOR_ROBOT_PASS" | base64 -w0)"

mapfile -t NODES < <(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')
[ "${#NODES[@]}" -gt 0 ] || die "未发现节点"

for ip in "${NODES[@]}"; do
  log "配置节点 ${ip} 的 containerd -> ${HARBOR_HOST}"
  ssh -o StrictHostKeyChecking=no root@"${ip}" \
    "HARBOR_HOST=${HARBOR_HOST} HUSER_B64=$(printf '%s' "$HUSER" | base64 -w0) HPASS_B64=${HPASS_B64} bash -s" <<'NODE'
set -euo pipefail
HUSER="$(printf '%s' "${HUSER_B64}" | base64 -d)"
HPASS="$(printf '%s' "${HPASS_B64}" | base64 -d)"
if ! grep -q "registry.configs.\"${HARBOR_HOST}\"" /etc/containerd/config.toml; then
  {
    echo ""
    echo "[plugins.\"io.containerd.grpc.v1.cri\".registry.configs.\"${HARBOR_HOST}\".tls]"
    echo "  insecure_skip_verify = true"
    echo "[plugins.\"io.containerd.grpc.v1.cri\".registry.configs.\"${HARBOR_HOST}\".auth]"
    echo "  username = \"${HUSER}\""
    echo "  password = \"${HPASS}\""
  } >> /etc/containerd/config.toml
fi
systemctl restart containerd
echo "[+] ${HARBOR_HOST} 配置完成"
NODE
done
log "成员 registry 配置完成"
