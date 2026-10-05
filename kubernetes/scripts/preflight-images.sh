#!/usr/bin/env bash
# 集群创建前镜像预检：确认每个本域镜像已导入节点 containerd
# 用法: preflight-images.sh [节点IP ...]   # 缺省为起步节点
# 任一镜像缺失 -> exit 1（阻止 kubeadm init）
set -euo pipefail

IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-/data/kvm/images/registry}"
MANIFEST="${IMAGE_CACHE_DIR}/manifest.tsv"
[ -f "$MANIFEST" ] || { echo "[!] 缺少清单: $MANIFEST（先 make acr-prepare）"; exit 1; }

NODES=("$@")
if [ "${#NODES[@]}" -eq 0 ]; then
  i=0; for ip in ${CP_IPS:-}; do [ "$i" -ge "${CP_INIT_COUNT:-1}" ] && break; NODES+=("$ip"); i=$((i+1)); done
  i=0; for ip in ${WK_IPS:-}; do [ "$i" -ge "${WK_INIT_COUNT:-1}" ] && break; NODES+=("$ip"); i=$((i+1)); done
fi
[ "${#NODES[@]}" -gt 0 ] || { echo "[!] 没有目标节点"; exit 1; }

mapfile -t REFS < <(awk -F'\t' '{print $1}' "$MANIFEST")
[ "${#REFS[@]}" -gt 0 ] || { echo "[!] 清单为空"; exit 1; }

echo "[+] 预检 ${#REFS[@]} 个镜像 / ${#NODES[@]} 个节点"
missing_total=0
for ip in "${NODES[@]}"; do
  remote_ls=$(ssh -o StrictHostKeyChecking=no root@"$ip" "ctr -n k8s.io images ls -q" 2>/dev/null || true)
  miss=0
  for ref in "${REFS[@]}"; do
    if ! grep -qxF "$ref" <<<"$remote_ls"; then
      echo "[!] ${ip} 缺少: ${ref}"
      miss=$((miss+1))
    fi
  done
  if [ "$miss" -eq 0 ]; then
    echo "[+] ${ip} OK (${#REFS[@]})"
  else
    missing_total=$((missing_total+miss))
  fi
done

if [ "$missing_total" -gt 0 ]; then
  echo ""
  echo "[!] 预检失败：共缺 ${missing_total} 个镜像，禁止 kubeadm init"
  exit 1
fi
echo "[+] 预检通过"
