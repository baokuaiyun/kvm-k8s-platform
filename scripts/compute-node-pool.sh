#!/usr/bin/env bash
# 节点池打标（幂等）：给节点打角色标签；非默认池可自动加 dedicated 污点。
# 用法:
#   bash scripts/compute-node-pool.sh                       # 全部节点标为默认池 workload（不污点）
#   bash scripts/compute-node-pool.sh k8s-worker-2=data     # 指定节点池
#   COMPUTE_NODE_POOLS="k8s-worker-1=data k8s-worker-2=gpu" bash scripts/compute-node-pool.sh
#   POOL_TAINT=0 bash scripts/compute-node-pool.sh ...      # 不加污点
#   DRY_RUN=1 bash scripts/compute-node-pool.sh ...         # 只打印不执行
# 关联: docs/compute-architecture.md #3
set -uo pipefail

POOL_LABEL="${COMPUTE_POOL_LABEL:-workload.baokuaiyun.com/pool}"
DEFAULT_POOL="${COMPUTE_DEFAULT_POOL:-workload}"
# 会附加 dedicated=<pool>:NoSchedule 污点的池（默认池不加）
TAINT_POOLS="${COMPUTE_TAINT_POOLS:-toolchain data gpu}"
POOL_TAINT="${POOL_TAINT:-1}"
DRY_RUN="${DRY_RUN:-0}"

command -v kubectl >/dev/null 2>&1 || { echo "[!] 需要 kubectl"; exit 2; }
kubectl cluster-info >/dev/null 2>&1 || { echo "[!] 无法连接集群"; exit 2; }

run() { echo "  \$ $*"; [ "$DRY_RUN" = "1" ] || "$@"; }

# 组装 节点=池 列表：命令行参数优先，其次 COMPUTE_NODE_POOLS
pairs=()
if [ "$#" -gt 0 ]; then
  pairs=("$@")
elif [ -n "${COMPUTE_NODE_POOLS:-}" ]; then
  # shellcheck disable=SC2206
  pairs=(${COMPUTE_NODE_POOLS})
else
  for n in $(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}'); do
    pairs+=("${n}=${DEFAULT_POOL}")
  done
fi

[ "${#pairs[@]}" -eq 0 ] && { echo "[!] 无节点可打标"; exit 1; }

echo "[+] 节点池打标（键=$POOL_LABEL，污点=$POOL_TAINT，DRY_RUN=$DRY_RUN）"
for p in "${pairs[@]}"; do
  node="${p%%=*}"; pool="${p##*=}"
  [ -z "$node" ] || [ -z "$pool" ] && { echo "  [WARN] 忽略非法项: $p"; continue; }
  if ! kubectl get node "$node" >/dev/null 2>&1; then echo "  [WARN] 节点 $node 不存在，跳过"; continue; fi
  run kubectl label node "$node" "${POOL_LABEL}=${pool}" --overwrite
  if [ "$POOL_TAINT" = "1" ] && printf '%s' " $TAINT_POOLS " | grep -q " $pool "; then
    run kubectl taint node "$node" "dedicated=${pool}:NoSchedule" --overwrite
  fi
  echo "  [OK]   $node -> pool=$pool"
done
echo "[+] 完成。查看: kubectl get nodes -L $POOL_LABEL"