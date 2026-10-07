#!/usr/bin/env bash
# 加入 Worker 节点
# 用法: join-worker.sh all | <worker-name> [worker-name ...]
# - all : 加入起步 worker（前 WK_INIT_COUNT 台）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CP1_IP="${CP_IPS%% *}"; CP1_IP="${CP1_IP:-192.168.124.10}"

WK_NAMES_ARR=(${WK_NAMES:-})
WK_IPS_ARR=(${WK_IPS:-})

resolve_ip() {
  local name="$1" i=0
  for n in "${WK_NAMES_ARR[@]}"; do
    [ "$n" = "$name" ] && { echo "${WK_IPS_ARR[$i]}"; return 0; }
    i=$((i+1))
  done
  return 1
}

targets=()
if [ "${1:-}" = "all" ]; then
  n="${WK_INIT_COUNT:-1}"; i=0
  for name in "${WK_NAMES_ARR[@]}"; do
    [ "$i" -ge "$n" ] && break
    targets+=("$name"); i=$((i+1))
  done
else
  targets=("$@")
fi

if [ "${#targets[@]}" -eq 0 ]; then
  echo "[=] 无起步 Worker（WK_INIT_COUNT=${WK_INIT_COUNT:-0}），跳过 join-worker"
  exit 0
fi

join_one() {
  local name="$1" ip
  ip=$(resolve_ip "$name") || { echo "[!] 未知 worker: $name"; return 1; }

  echo "[+] 安装 kubelet/kubeadm 到 ${name} (${ip})..."
  bash "${SCRIPT_DIR}/install-common.sh" "$ip"

  local join
  join=$(ssh -o StrictHostKeyChecking=no root@"$CP1_IP" 'kubeadm token create --print-join-command')
  echo "[+] 加入 ${name}..."
  ssh -o StrictHostKeyChecking=no root@"$ip" "$join"
}

for t in "${targets[@]}"; do
  join_one "$t"
done
echo "[+] Worker 加入完成"
