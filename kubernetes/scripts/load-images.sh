#!/usr/bin/env bash
# 分发本域镜像 tar 到节点并导入 containerd(k8s.io)
# 用法: load-images.sh [节点IP ...]   # 缺省为起步节点
set -euo pipefail

IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-/data/kvm/images/registry}"
MANIFEST="${IMAGE_CACHE_DIR}/manifest.tsv"
[ -f "$MANIFEST" ] || { echo "[!] 缺少清单: $MANIFEST（先 make acr-prepare）"; exit 1; }

# 目标节点
NODES=("$@")
if [ "${#NODES[@]}" -eq 0 ]; then
  i=0; for ip in ${CP_IPS:-}; do [ "$i" -ge "${CP_INIT_COUNT:-1}" ] && break; NODES+=("$ip"); i=$((i+1)); done
  i=0; for ip in ${WK_IPS:-}; do [ "$i" -ge "${WK_INIT_COUNT:-1}" ] && break; NODES+=("$ip"); i=$((i+1)); done
fi
[ "${#NODES[@]}" -gt 0 ] || { echo "[!] 没有目标节点"; exit 1; }

mapfile -t TARS < <(awk -F'\t' '{print $2}' "$MANIFEST" | sort -u)
[ "${#TARS[@]}" -gt 0 ] || { echo "[!] 清单为空"; exit 1; }

# 远端目录用磁盘路径（/tmp 在云镜像里常是 ~2G tmpfs，装不下镜像 tar）
REMOTE_DIR="/var/lib/k8s-images"

echo "[+] 分发 ${#TARS[@]} 个 tar 到 ${#NODES[@]} 个节点"
for ip in "${NODES[@]}"; do
  echo "[+] 节点 ${ip}..."
  ssh -o StrictHostKeyChecking=no root@"$ip" "rm -rf ${REMOTE_DIR}; mkdir -p ${REMOTE_DIR}"
  scp -o StrictHostKeyChecking=no -q "${TARS[@]}" root@"$ip":"${REMOTE_DIR}"/
  for t in "${TARS[@]}"; do
    ssh -o StrictHostKeyChecking=no root@"$ip" "ctr -n k8s.io images import ${REMOTE_DIR}/$(basename "$t")" >/dev/null
  done
  ssh -o StrictHostKeyChecking=no root@"$ip" "rm -rf ${REMOTE_DIR}"
  echo "    导入完成"
done
echo "[+] 镜像导入完成"
