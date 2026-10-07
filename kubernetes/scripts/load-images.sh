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

mapfile -t ALL_TARS < <(awk -F'\t' '{print $2}' "$MANIFEST" | sort -u)
[ "${#ALL_TARS[@]}" -gt 0 ] || { echo "[!] 清单为空"; exit 1; }

# 过滤缺失/空文件，避免单个坏 tar 中断整批导入
TARS=()
for t in "${ALL_TARS[@]}"; do
  if [ ! -s "$t" ]; then
    echo "[!] 跳过无效 tar（缺失或 0 字节）: $t（请 make acr-prepare FORCE=1 重建）"
    continue
  fi
  TARS+=("$t")
done
[ "${#TARS[@]}" -gt 0 ] || { echo "[!] 无有效 tar 可导入"; exit 1; }

# 远端目录用磁盘路径（/tmp 在云镜像里常是 ~2G tmpfs，装不下镜像 tar）
REMOTE_DIR="/var/lib/k8s-images"

echo "[+] 分发 ${#TARS[@]} 个 tar 到 ${#NODES[@]} 个节点（清单 ${#ALL_TARS[@]}）"
FAIL=0
for ip in "${NODES[@]}"; do
  echo "[+] 节点 ${ip}..."
  ssh -o StrictHostKeyChecking=no root@"$ip" "rm -rf ${REMOTE_DIR}; mkdir -p ${REMOTE_DIR}"
  scp -o StrictHostKeyChecking=no -q "${TARS[@]}" root@"$ip":"${REMOTE_DIR}"/
  for t in "${TARS[@]}"; do
    if ! ssh -o StrictHostKeyChecking=no root@"$ip" "ctr -n k8s.io images import ${REMOTE_DIR}/$(basename "$t")" >/dev/null 2>&1; then
      echo "[!] 导入失败: $(basename "$t")"
      FAIL=$((FAIL+1))
    fi
  done
  ssh -o StrictHostKeyChecking=no root@"$ip" "rm -rf ${REMOTE_DIR}"
  echo "    导入完成"
done
[ "$FAIL" -eq 0 ] || { echo "[!] 有 ${FAIL} 个 tar 导入失败"; exit 1; }
echo "[+] 镜像导入完成"
