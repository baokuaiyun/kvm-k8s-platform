#!/usr/bin/env bash
# 销毁所有 VM 和资源
set -euo pipefail

VMS=(k8s-cp-1 k8s-cp-2 k8s-cp-3 k8s-worker-1 k8s-worker-2)
DATA_DIR="/data/kvm"

for vm in "${VMS[@]}"; do
  echo "[+] 销毁 VM: ${vm}"
  virsh destroy "$vm" 2>/dev/null || true
  virsh undefine "$vm" --nvram 2>/dev/null || true
  rm -f "${DATA_DIR}/disks/${vm}.qcow2" "${DATA_DIR}/seeds/${vm}-seed.iso"
done

echo "[+] 销毁网络 br-prod"
virsh net-destroy br-prod 2>/dev/null || true
virsh net-undefine br-prod 2>/dev/null || true

echo "[+] 完成，所有 VM 和资源已销毁"
