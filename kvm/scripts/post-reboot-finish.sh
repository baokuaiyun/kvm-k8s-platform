#!/usr/bin/env bash
# 重启后自动收尾：等待集群 → 加载 zfs → 建宿主存储 → 装 CSI/快照 → 应用 SC → 验收
# 由 systemd 单元 post-reboot-finish.service 触发（make post-reboot-install 安装）。
# 日志: /var/log/post-reboot-finish.log
set -x
export HOME="${HOME:-/root}"
export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
exec >/var/log/post-reboot-finish.log 2>&1

echo "=== post-reboot finish $(date) kernel=$(uname -r) ==="
cd /root/k8s || exit 1

# 等 libvirt 网络/VM
for i in $(seq 1 60); do virsh net-info "${NET_NAME:-br-prod}" >/dev/null 2>&1 && break; sleep 5; done
virsh start k8s-cp-1 2>/dev/null || true

# 等 k8s API 可用（失败即明确报错，避免静默超时）
ok=0
for i in $(seq 1 120); do kubectl get nodes >/dev/null 2>&1 && { ok=1; break; }; sleep 10; done
if [ "$ok" != 1 ]; then echo "[x] k8s API 不可达，放弃收尾"; exit 1; fi
kubectl get nodes || true

modprobe zfs && echo "zfs module loaded" || echo "zfs module FAILED"

make host-storage || echo "host-storage FAILED"
make csi-storage  || echo "csi-storage FAILED"
make storage-class || true
make verify-storage || true

echo "=== post-reboot finish DONE $(date) ==="
