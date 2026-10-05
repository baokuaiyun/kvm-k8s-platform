#!/usr/bin/env bash
# 创建单台 KVM VM
# 用法: create-vm.sh <name> <ip> <mac> <vcpu> <ram> <disk>
set -euo pipefail

NAME=$1
IP=$2
MAC=$3
VCPU=${4:-2}
RAM=${5:-4096}
DISK=${6:-30G}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${BASE_DIR}/.." && pwd)"

# 读取变量
DATA_DIR="/data/kvm"
IMAGE_DIR="${DATA_DIR}/images"
DISK_DIR="${DATA_DIR}/disks"
SEED_DIR="${DATA_DIR}/seeds"
BASE_IMAGE="${IMAGE_DIR}/debian-13-generic-amd64.qcow2"

# 检查依赖
command -v cloud-localds >/dev/null 2>&1 || { echo "[!] 缺少 cloud-localds (apt install cloud-image-utils)"; exit 1; }
command -v qemu-img >/dev/null 2>&1 || { echo "[!] 缺少 qemu-img (apt install qemu-utils)"; exit 1; }
command -v virt-install >/dev/null 2>&1 || { echo "[!] 缺少 virt-install (apt install virtinst)"; exit 1; }

[ -f "$BASE_IMAGE" ] || { echo "[!] 基础镜像不存在: $BASE_IMAGE"; echo "    请先执行: make image-download"; exit 1; }

mkdir -p "$SEED_DIR" "$DISK_DIR"

# 注入 SSH 公钥到 user-data
SSH_PUBKEY=$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null || echo "")
[ -z "$SSH_PUBKEY" ] && echo "[!] 警告: 未找到 SSH 公钥，VM 将无法免密登录"

# 生成 seed ISO
NODE_TYPE="worker"
[[ "$NAME" == *cp* ]] && NODE_TYPE="cp"

SEED_ISO="${SEED_DIR}/${NAME}-seed.iso"
TMP_UD="/tmp/${NAME}-user-data"
TMP_MD="/tmp/${NAME}-meta-data"
sed -e "s|__SSH_PUBKEY__|${SSH_PUBKEY}|g" \
    -e "s|__HOSTNAME__|${NAME}|g" \
    "${BASE_DIR}/cloud-init/${NODE_TYPE}-user-data" > "$TMP_UD"
printf 'instance-id: %s\nlocal-hostname: %s\n' "$NAME" "$NAME" > "$TMP_MD"

echo "[+] 生成 seed ISO: ${NAME}"
cloud-localds "$SEED_ISO" "$TMP_UD" "$TMP_MD"
rm -f "$TMP_UD" "$TMP_MD"

# 创建磁盘（backing file 节省空间）
DISK_IMG="${DISK_DIR}/${NAME}.qcow2"
echo "[+] 创建磁盘: ${NAME} (${DISK}, backing: ${BASE_IMAGE})"
qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$DISK_IMG" "$DISK"

# 创建 VM
echo "[+] 启动 VM: ${NAME} (${VCPU} vCPU / ${RAM}MB / ${DISK})"
virt-install \
  --name "$NAME" \
  --vcpus "$VCPU" \
  --memory "$RAM" \
  --boot uefi \
  --disk path="$DISK_IMG",format=qcow2,bus=virtio \
  --disk path="$SEED_ISO",device=cdrom \
  --network bridge=br-prod,mac="$MAC",model=virtio \
  --os-variant debiantrixie \
  --graphics none \
  --console pty,target_type=virtio \
  --serial pty \
  --noautoconsole \
  --import

echo "[+] ${NAME} 创建完成. IP: ${IP}, MAC: ${MAC}"
