#!/usr/bin/env bash
# 宿主云盘层：ZFS 池 + iSCSI target(LIO) + MinIO(docker)
# 目的：在 KVM 宿主上模拟阿里云「云盘 + OSS」，与计算(VM)分离。
#   - 块存储：ZFS pool/dataset → zvol → iSCSI 导出（由集群内 democratic-csi 供给）
#   - 对象存储：MinIO 承载 barman/Velero/GitLab 对象（模拟 OSS）
# 幂等：重复执行只补齐缺失项，不销毁既有池/数据。
# 详见 docs/cloud-disk-data-solution.md
# 用法: bash kvm/scripts/host-storage.sh
set -euo pipefail

POOL="${ZFS_POOL:-tank}"
USE_FILE="${HOST_ZFS_USE_FILE:-1}"
ZFS_FILE="${HOST_ZFS_FILE:-/data/zfs-pool.img}"
ZFS_FILE_SIZE="${HOST_ZFS_FILE_SIZE:-50G}"
VDEV="${HOST_ZFS_VDEV:-/dev/sdb}"
COMP="${ZFS_COMPRESSION:-zstd}"
ENC="${ZFS_ENCRYPTION:-off}"
BASE_IQN="${ISCSI_TARGET_IQN:-iqn.2026-01.com.baokuaiyun:k8s}"
PORTAL_ADDR="${NET_GATEWAY:-192.168.124.1}"
PORTAL_PORT="3260"
MINIO_PORT="${HOST_MINIO_PORT:-9000}"
MINIO_CONSOLE_PORT="${HOST_MINIO_CONSOLE_PORT:-9001}"
MINIO_DATA="${HOST_MINIO_DATA:-/data/minio}"
MINIO_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_PASS="${MINIO_ROOT_PASSWORD:-minioadmin}"
MINIO_IMAGE="${MINIO_IMAGE:-quay.io/minio/minio:latest}"
MINIO_MC_IMAGE="${MINIO_MC_IMAGE:-quay.io/minio/mc:latest}"
SSH_KEY="${HOST_CSI_SSH_KEY:-/etc/k8s-host-csi/id_ed25519}"

log()  { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }

# 仅云盘后端需要宿主 ZFS/iSCSI；其它后端（longhorn/aliyun）默认跳过
if [ "${STORAGE_BACKEND:-host-zfs-iscsi}" != "host-zfs-iscsi" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "[=] STORAGE_BACKEND=${STORAGE_BACKEND}≠host-zfs-iscsi，跳过宿主云盘层（FORCE=1 可强制）"
  exit 0
fi

# ---------- 0) 依赖 ----------
need=0
for t in zpool zfs targetcli; do command -v "$t" >/dev/null 2>&1 || need=1; done
if [ "$need" = 1 ]; then
  log "安装宿主依赖: zfsutils-linux targetcli-fb open-iscsi"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zfsutils-linux targetcli-fb open-iscsi
fi
command -v docker >/dev/null 2>&1 || { warn "缺少 docker（MinIO 需要）"; }

# ---------- 0.1) ZFS 内核模块检查 ----------
if ! modprobe zfs 2>/dev/null && ! zpool list >/dev/null 2>&1; then
  if [ "${SKIP_ZFS:-0}" = "1" ]; then
    warn "ZFS 模块不可用；SKIP_ZFS=1 → 跳过建池（仅部署 MinIO/iSCSI 基础）"
  else
    warn "ZFS 内核模块不可用：当前内核 $(uname -r) 无匹配模块/headers。"
    warn "解决: apt-get install -y linux-headers-$(uname -r) && dkms autoinstall && modprobe zfs"
    warn "     或改用带 headers 的内核并重启；只想部署 MinIO/iSCSI 基础可设 SKIP_ZFS=1"
    exit 1
  fi
fi

# ---------- 1) ZFS 池 ----------
if [ "${SKIP_ZFS:-0}" = "1" ]; then
  warn "SKIP_ZFS=1：跳过 ZFS 池与数据集创建"
elif zpool list "$POOL" >/dev/null 2>&1; then
  log "ZFS 池已存在: $POOL（保持不变）"
else
  if [ "$USE_FILE" = "1" ]; then
    [ -f "$ZFS_FILE" ] || { log "创建 ZFS 文件 vdev: $ZFS_FILE ($ZFS_FILE_SIZE)"; truncate -s "$ZFS_FILE_SIZE" "$ZFS_FILE"; }
    log "创建 ZFS 池 $POOL（file vdev=$ZFS_FILE）"
    zpool create -f "$POOL" "$ZFS_FILE"
  else
    [ -b "$VDEV" ] || { warn "块设备不存在: $VDEV"; exit 1; }
    if [ "$(lsblk -no NAME "$VDEV" | wc -l)" -gt 1 ]; then
      warn "$VDEV 已有分区/文件系统；确认可用于 ZFS 请设 FORCE=1"
      [ "${FORCE:-0}" = "1" ] || exit 1
    fi
    log "创建 ZFS 池 $POOL（裸盘 $VDEV）"
    zpool create -f "$POOL" "$VDEV"
  fi
fi
if [ "${SKIP_ZFS:-0}" != "1" ]; then
  zfs set compression="$COMP" "$POOL" 2>/dev/null || true
  zfs set atime=off "$POOL" 2>/dev/null || true
  zfs set xattr=sa "$POOL" 2>/dev/null || true

  # 数据集父目录：CSI 在其下建 zvol
  if zfs list "$POOL/k8s" >/dev/null 2>&1; then
    log "ZFS 数据集已存在: $POOL/k8s"
  else
    if [ "$ENC" = "on" ] && [ -n "${ZFS_ENCRYPTION_KEYFILE:-}" ]; then
      log "创建加密数据集 $POOL/k8s（keyfile=${ZFS_ENCRYPTION_KEYFILE}）"
      zfs create -o mountpoint=none -o compression="$COMP" \
        -o encryption=on -o keyformat=raw -o "keylocation=file://${ZFS_ENCRYPTION_KEYFILE}" "$POOL/k8s"
    else
      [ "$ENC" = "on" ] && warn "ZFS_ENCRYPTION=on 但未提供 ZFS_ENCRYPTION_KEYFILE，先建非加密数据集（生产请补）"
      log "创建数据集 $POOL/k8s（zvol 父目录）"
      zfs create -o mountpoint=none -o compression="$COMP" "$POOL/k8s"
    fi
  fi
fi

# ---------- 2) iSCSI target(LIO) ----------
log "加载 LIO 内核模块并启用 target 服务"
modprobe target_core_mod 2>/dev/null || true
modprobe iscsi_target_mod 2>/dev/null || true
systemctl enable --now target 2>/dev/null || systemctl enable --now targetcli 2>/dev/null || true

if targetcli /iscsi status >/dev/null 2>&1; then
  if ! targetcli /iscsi ls 2>/dev/null | grep -q "$BASE_IQN"; then
    log "创建 iSCSI target: $BASE_IQN"
    targetcli /iscsi create "$BASE_IQN" >/dev/null
  else
    log "iSCSI target 已存在: $BASE_IQN"
  fi
  if ! targetcli "/iscsi/${BASE_IQN}/tpg1/portals" ls 2>/dev/null | grep -q "$PORTAL_PORT"; then
    log "创建 iSCSI portal: ${PORTAL_ADDR}:${PORTAL_PORT}"
    targetcli "/iscsi/${BASE_IQN}/tpg1/portals" create "$PORTAL_ADDR" "$PORTAL_PORT" >/dev/null 2>&1 \
      || targetcli "/iscsi/${BASE_IQN}/tpg1/portals" create 0.0.0.0 "$PORTAL_PORT" >/dev/null
  fi
  targetcli /iscsi/"${BASE_IQN}"/tpg1 set attribute authentication=0 demo_mode_write_protect=0 generate_node_acls=1 >/dev/null 2>&1 || true
  targetcli saveconfig >/dev/null 2>&1 || true
else
  warn "targetcli 不可用：请确认已安装 targetcli-fb 且 LIO 已加载"
fi

# ---------- 3) CSI 管理用 SSH 密钥 ----------
if [ ! -f "$SSH_KEY" ]; then
  log "生成 CSI→宿主 SSH 密钥: $SSH_KEY"
  mkdir -p "$(dirname "$SSH_KEY")"
  ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "democratic-csi@host"
fi
mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
if ! grep -qF "$(cut -d' ' -f1,2 "$SSH_KEY.pub")" /root/.ssh/authorized_keys 2>/dev/null; then
  log "授权 CSI 公钥到宿主 root"
  cat "$SSH_KEY.pub" >> /root/.ssh/authorized_keys
fi

# ---------- 4) MinIO（对象/备份层，模拟 OSS）----------
mkdir -p "$MINIO_DATA"
if command -v docker >/dev/null 2>&1; then
  if ! docker image inspect "$MINIO_IMAGE" >/dev/null 2>&1; then
    log "本地无 ${MINIO_IMAGE}，尝试拉取（宿主代理受限时可换 MINIO_IMAGE 或预加载）..."
    docker pull "$MINIO_IMAGE" >/dev/null 2>&1 || \
      warn "拉取 ${MINIO_IMAGE} 失败；跳过 MinIO（可设 MINIO_IMAGE 或先 docker load）"
  fi
  if docker image inspect "$MINIO_IMAGE" >/dev/null 2>&1; then
    if [ "$(docker inspect -f '{{.State.Running}}' host-minio 2>/dev/null || echo false)" = "true" ]; then
      log "MinIO 容器已在运行（host-minio）"
    else
      log "启动 MinIO 容器（host-minio）: ${MINIO_PORT}/console ${MINIO_CONSOLE_PORT}"
      docker rm -f host-minio >/dev/null 2>&1 || true
      docker run -d --name host-minio --restart unless-stopped \
        -p "${MINIO_PORT}:9000" -p "${MINIO_CONSOLE_PORT}:9001" \
        -e MINIO_ROOT_USER="$MINIO_USER" -e MINIO_ROOT_PASSWORD="$MINIO_PASS" \
        -v "${MINIO_DATA}":/data \
        "$MINIO_IMAGE" server /data --console-address ":9001" >/dev/null
    fi
    # 建备份桶（幂等，best-effort）
    for b in pg-backups velero longhorn-backups gitlab-object; do
      docker run --rm --network host --entrypoint /bin/sh "$MINIO_MC_IMAGE" -c \
        "mc alias set local http://127.0.0.1:${MINIO_PORT} '${MINIO_USER}' '${MINIO_PASS}' >/dev/null 2>&1 && mc mb -p local/${b} >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    done
  else
    warn "跳过 MinIO（镜像不可用）"
  fi
else
  warn "未安装 docker，跳过 MinIO"
fi

# ---------- 5) 防火墙（可选）----------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${PORTAL_PORT}/tcp" >/dev/null 2>&1 || true
  ufw allow "${MINIO_PORT}/tcp" >/dev/null 2>&1 || true
fi

# ---------- 汇总 ----------
echo ""
log "宿主存储层就绪"
echo "    ZFS 池      : $POOL（dataset $POOL/k8s，compression=$COMP）"
echo "    iSCSI target: $BASE_IQN  portal ${PORTAL_ADDR}:${PORTAL_PORT}"
echo "    CSI SSH 密钥: $SSH_KEY"
echo "    MinIO       : http://${PORTAL_ADDR}:${MINIO_PORT}  (console :${MINIO_CONSOLE_PORT})"
echo "    下一步      : make k8s-common → make k8s-init → make csi-storage → make storage-class"
