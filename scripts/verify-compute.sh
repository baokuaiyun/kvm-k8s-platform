#!/usr/bin/env bash
# 计算平面验收：节点规格 / 分配与超分 / 压力与调度 / 配额 / 弹性 / 节点池 / 异构 / 告警
# 用法: bash scripts/verify-compute.sh [readonly|drill|drill-only|all]
#   readonly  (默认) 只读巡检  8 项
#   drill / all      只读巡检 + 完整演练/压测（临时 ns，自清理）
#   drill-only       仅演练/压测
# 退出码: 0=通过（可含 WARN/SKIP），1=存在 FAIL，2=前置缺失
# 关联: docs/compute-verification.md / docs/compute-architecture.md
set -uo pipefail

TARGET="${1:-readonly}"

# ---- 参数（来自 variables.mk/profile 的导出；均给默认值）----
ENV="${ENV:-${FLEET_ENV:-drill}}"
POOL_LABEL="${COMPUTE_POOL_LABEL:-workload.baokuaiyun.com/pool}"
RESERVE_CPU="${RESERVE_CPU:-500m}"
RESERVE_MEM="${RESERVE_MEM:-1Gi}"
OC_CPU_MAX="${OVERCOMMIT_CPU_MAX:-2.0}"
OC_MEM_MAX="${OVERCOMMIT_MEM_MAX:-1.5}"
EN_METRICS="${COMPUTE_ENABLE_METRICS_SERVER:-1}"
EN_HPA="${COMPUTE_ENABLE_HPA:-1}"
EN_VPA="${COMPUTE_ENABLE_VPA:-0}"
EN_DESCHED="${COMPUTE_ENABLE_DESCHEDULER:-0}"
EN_AUTOSCALER="${COMPUTE_ENABLE_AUTOSCALER:-0}"
EN_GPU="${COMPUTE_ENABLE_GPU:-0}"
GPU_RES="${COMPUTE_GPU_RESOURCE:-nvidia.com/gpu}"
DRILL_NS="${COMPUTE_DRILL_NS:-compute-drill}"
DRILL_IMAGE="${COMPUTE_DRILL_IMAGE:-harbor.test.baokuaiyun.com/baokuaiyun/busybox:1.37.0}"
STRESS_CPU="${COMPUTE_STRESS_CPU:-2}"
STRESS_MEM="${COMPUTE_STRESS_MEM:-256Mi}"
DRILL_TIMEOUT="${COMPUTE_DRILL_TIMEOUT:-180}"
PROM_NS="${ALERT_NAMESPACE:-monitoring}"

FAIL=0
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [WARN] $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=1; }
skip() { echo "  [SKIP] $*"; }
have() { command -v "$1" >/dev/null 2>&1; }
ECHO_CMD="${KUBECTL_VERIFY_ECHO:-1}"
show() { [ "$ECHO_CMD" = "1" ] && echo "  \$ $*"; return 0; }
# 单位换算（与 jq 程序一致，避免重复）
to_mem_bytes() { # "128Mi" -> bytes（整数）
  local v="$1"
  case "$v" in
    *Ki) echo $(( ${v%Ki} * 1024 ));;
    *Mi) echo $(( ${v%Mi} * 1048576 ));;
    *Gi) echo $(( ${v%Gi} * 1073741824 ));;
    *Ti) echo $(( ${v%Ti} * 1099511627776 ));;
    *K)  echo $(( ${v%K} * 1000 ));;
    *M)  echo $(( ${v%M} * 1000000 ));;
    *G)  echo $(( ${v%G} * 1000000000 ));;
    ""|0) echo 0;;
    *)   echo "$v";;
  esac
}
to_mcpu() { # "100m"->100, "2"->2000
  local v="$1"
  case "$v" in
    *m) echo "${v%m}";;
    ""|0) echo 0;;
    *) echo $(( v * 1000 ));;
  esac
}

command -v kubectl >/dev/null 2>&1 || { echo "[!] 需要 kubectl"; exit 2; }
kubectl cluster-info >/dev/null 2>&1 || { echo "[!] 无法连接集群"; exit 2; }

echo "=================================================================="
echo " 计算验收  ENV=$ENV  TARGET=$TARGET"
echo "   节点池标签=$POOL_LABEL  超分阈值 cpu<=$OC_CPU_MAX mem<=$OC_MEM_MAX"
echo "   弹性: metrics=$EN_METRICS hpa=$EN_HPA vpa=$EN_VPA descheduler=$EN_DESCHED autoscaler=$EN_AUTOSCALER"
echo "   GPU: enable=$EN_GPU resource=$GPU_RES"
echo "=================================================================="

# ================= 只读巡检 =================
run_readonly() {

echo "=== 1. 节点就绪与规格 ==="
show "kubectl get nodes -o wide"
kubectl get nodes -o wide 2>/dev/null | sed 's/^/  /'
notready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{c++} END{print c+0}')
if [ "${notready:-0}" -eq 0 ]; then ok "全部节点 Ready"; else bad "$notready 个节点 NotReady"; fi
show "kubectl get nodes -o custom-columns (capacity vs allocatable)"
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAP_CPU:.status.capacity.cpu,ALLOC_CPU:.status.allocatable.cpu,CAP_MEM:.status.capacity.memory,ALLOC_MEM:.status.allocatable.memory' 2>/dev/null | sed 's/^/  /'
# KVM 宿主规格交叉核对（best-effort）
if have virsh; then
  echo "  [=] 宿主 VM 规格（virsh dominfo）:"
  for n in $(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}'); do
    if virsh dominfo "$n" >/dev/null 2>&1; then
      vc=$(virsh dominfo "$n" 2>/dev/null | awk -F: '/CPU\(s\)/{gsub(/ /,"",$2);print $2}')
      mem=$(virsh dominfo "$n" 2>/dev/null | awk -F: '/Max memory/{gsub(/^ +/,"",$2);print $2}')
      printf '    %-16s vCPU=%-3s maxMem=%s\n' "$n" "${vc:-?}" "${mem:-?}"
    fi
  done
else
  echo "       [=] 无 virsh（非 KVM 宿主），跳过宿主规格核对"
fi

echo "=== 2. 分配与超分（requests/allocatable）==="
if ! have jq; then
  warn "无 jq，跳过超分比计算（可从 kubectl describe node 的 Allocated resources 查看）"
else
  show "kubectl get nodes / kubectl get pods -A -o json | jq 聚合 requests"
  JQ_COMMON='def cpu: if .==null then 0 elif (type=="string") and endswith("m") then ((.[0:-1]|tonumber)/1000) else tonumber end;
def mem: if .==null then 0 elif endswith("Ki") then ((.[0:-2]|tonumber)*1024) elif endswith("Mi") then ((.[0:-2]|tonumber)*1048576) elif endswith("Gi") then ((.[0:-2]|tonumber)*1073741824) elif endswith("Ti") then ((.[0:-2]|tonumber)*1099511627776) elif endswith("K") then ((.[0:-1]|tonumber)*1000) elif endswith("M") then ((.[0:-1]|tonumber)*1000000) elif endswith("G") then ((.[0:-1]|tonumber)*1000000000) else tonumber end;'
  allocs=$(kubectl get nodes -o json 2>/dev/null | jq -r "$JQ_COMMON"'
    .items[] | [.metadata.name, (.status.allocatable.cpu|cpu), (.status.allocatable.memory|mem)] | @tsv' 2>/dev/null)
  reqs=$(kubectl get pods -A -o json 2>/dev/null | jq -r "$JQ_COMMON"'
    [.items[]
     | select(.spec.nodeName != null and .spec.nodeName != "")
     | .spec.nodeName as $n
     | ([.spec.containers[]?.resources.requests.cpu]     | map(cpu) | add // 0) as $c
     | ([.spec.containers[]?.resources.requests.memory]  | map(mem) | add // 0) as $m
     | [$n, $c, $m]]
    | group_by(.[0]) | .[]
    | [.[0][0], (map(.[1])|add), (map(.[2])|add)] | @tsv' 2>/dev/null)
  printf '  %-16s %-14s %-14s %-8s %-16s %-16s %-8s\n' NODE ALLOC_CPU REQ_CPU CPU_RATIO ALLOC_MEM REQ_MEM MEM_RATIO
  while IFS=$'\t' read -r node acpu amem; do
    [ -z "$node" ] && continue
    rcpu=0; rmem=0
    line=$(printf '%s\n' "$reqs" | awk -F'\t' -v n="$node" '$1==n{print $2"\t"$3}')
    [ -n "$line" ] && { rcpu=$(printf '%s' "$line" | cut -f1); rmem=$(printf '%s' "$line" | cut -f2); }
    ratios=$(awk -v ac="$acpu" -v am="$amem" -v rc="$rcpu" -v rm="$rmem" 'BEGIN{printf "%.2f %.2f", (ac>0?rc/ac:0), (am>0?rm/am:0)}')
    cr=$(echo "$ratios" | cut -d' ' -f1); mr=$(echo "$ratios" | cut -d' ' -f2)
    printf '  %-16s %-14.2f %-14.2f %-8s %-16.0f %-16.0f %-8s\n' "$node" "$acpu" "$rcpu" "$cr" "$amem" "$rmem" "$mr"
    awk -v r="$cr" -v m="$OC_CPU_MAX" 'BEGIN{exit !(r>m)}' && warn "$node CPU 超分比 $cr > $OC_CPU_MAX"
    awk -v r="$mr" -v m="$OC_MEM_MAX" 'BEGIN{exit !(r>m)}' && warn "$node 内存超分比 $mr > $OC_MEM_MAX（OOM 风险）"
  done <<< "$allocs"
  echo "       [提示] 预留参考: RESERVE_CPU=$RESERVE_CPU RESERVE_MEM=$RESERVE_MEM（生产建议设 kubeReserved/systemReserved）"
fi

echo "=== 3. 压力与调度 ==="
show "kubectl get nodes -o jsonpath (Memory/Disk/PIDPressure)"
press=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="MemoryPressure")].status}{" "}{.status.conditions[?(@.type=="DiskPressure")].status}{" "}{.status.conditions[?(@.type=="PIDPressure")].status}{"\n"}{end}' 2>/dev/null)
if [ -n "$press" ]; then
  printf '%s\n' "$press" | sed 's/^/  /'
  if printf '%s\n' "$press" | awk '{if($2=="True"||$3=="True"||$4=="True") print}' | grep -q .; then
    bad "存在资源压力条件为 True 的节点"
  else ok "无节点资源压力（Memory/Disk/PID 均 False）"; fi
fi
show "kubectl get pods -A --field-selector=status.phase=Pending"
pending=$(kubectl get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
[ "${pending:-0}" -eq 0 ] && ok "无 Pending Pod" || warn "$pending 个 Pod Pending（kubectl describe pod 查原因）"
show "kubectl get events -A --field-selector reason=Evicted"
evict=$(kubectl get events -A --field-selector reason=Evicted --no-headers 2>/dev/null | wc -l | tr -d ' ')
[ "${evict:-0}" -eq 0 ] && ok "无驱逐事件" || warn "$evict 条 Evicted 事件"

echo "=== 4. 配额与默认限 ==="
show "kubectl get resourcequota -A"
quota=$(kubectl get resourcequota -A --no-headers 2>/dev/null || true)
if [ -z "$quota" ]; then warn "集群内无 ResourceQuota"; else
  printf '%s\n' "$quota" | sed 's/^/  /'; ok "存在 ResourceQuota（$(printf '%s\n' "$quota" | wc -l | tr -d ' ') 个）"
fi
show "kubectl get limitrange -A"
lr=$(kubectl get limitrange -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
[ "${lr:-0}" -gt 0 ] && ok "存在 LimitRange（$lr 个）" || warn "无 LimitRange（未设默认 request/limit）"
if have jq; then
  show "kubectl get pods -A -o json | jq 统计缺 requests 的容器（排除系统 ns）"
  missing=$(kubectl get pods -A -o json 2>/dev/null | jq -r '
    ["kube-system","kube-node-lease","kube-public","monitoring","flux-system","cert-manager"] as $sys
    | [.items[] | select(.status.phase=="Running")
       | select((.metadata.namespace as $n | $sys | index($n)) == null)
       | .metadata.namespace as $ns | .metadata.name as $p
       | .spec.containers[] | select((.resources.requests.cpu == null) or (.resources.requests.memory == null))
       | "\($ns)/\($p)/\(.name)"] | length' 2>/dev/null)
  if [ "${missing:-0}" -eq 0 ]; then ok "业务容器均设 requests"; else warn "$missing 个业务容器缺 requests/limits（避免 BestEffort）"; fi
fi

echo "=== 5. 弹性能力 ==="
show "kubectl top nodes"
if kubectl top nodes >/dev/null 2>&1; then ok "metrics-server 可用（kubectl top 正常）"
elif [ "$EN_METRICS" = "1" ]; then warn "metrics-server 不可用（make metrics-server）；HPA/VPA 指标依赖它"
else skip "metrics-server 不可用（COMPUTE_ENABLE_METRICS_SERVER=0）"; fi
show "kubectl get hpa -A"
if kubectl get hpa -A >/dev/null 2>&1; then
  hpa=$(kubectl get hpa -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$EN_HPA" = "1" ] && ok "HPA API 可用（现有 $hpa 个）" || skip "HPA 未启用（COMPUTE_ENABLE_HPA=0）"
else warn "HPA API 不可用"; fi
if kubectl get crd verticalpodautoscalers.autoscaling.k8s.io >/dev/null 2>&1; then
  [ "$EN_VPA" = "1" ] && ok "VPA CRD 存在" || skip "VPA CRD 存在但未启用（COMPUTE_ENABLE_VPA=0）"
else
  [ "$EN_VPA" = "1" ] && warn "VPA 未安装（COMPUTE_ENABLE_VPA=1）" || skip "VPA 未启用"
fi
if kubectl -n kube-system get pods 2>/dev/null | grep -qi descheduler; then
  ok "descheduler 已部署"
elif [ "$EN_DESCHED" = "1" ]; then warn "descheduler 未部署（COMPUTE_ENABLE_DESCHEDULER=1）"
else skip "descheduler 未启用"; fi
if kubectl -n kube-system get pods 2>/dev/null | grep -qi autoscaler; then ok "cluster-autoscaler 已部署"
elif [ "$EN_AUTOSCALER" = "1" ]; then warn "cluster-autoscaler 未部署（COMPUTE_ENABLE_AUTOSCALER=1）"
else skip "cluster-autoscaler 未启用"; fi

echo "=== 6. 节点池 ==="
show "kubectl get nodes -L $POOL_LABEL"
kubectl get nodes -L "$POOL_LABEL" 2>/dev/null | sed 's/^/  /'
labeled=$(kubectl get nodes -o json 2>/dev/null | jq -r --arg k "$POOL_LABEL" '[.items[]|select(.metadata.labels[$k]!=null)]|length' 2>/dev/null || echo 0)
total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${labeled:-0}" -gt 0 ]; then ok "已打节点池标签 ${labeled}/${total}（键 $POOL_LABEL）"
else warn "无节点带节点池标签（make compute-node-pools 打标）"; fi
# 池标签与污点一致性
if have jq; then
  show "kubectl get nodes -o json | jq 池/污点一致性"
  inconsistent=$(kubectl get nodes -o json 2>/dev/null | jq -r --arg k "$POOL_LABEL" '
    [.items[] | select(.metadata.labels[$k]!=null) | .metadata.labels[$k] as $pool
     | select((.spec.taints // []) | map(select(.key=="dedicated")) | length > 0)
     | select(((.spec.taints[]?|select(.key=="dedicated").value) // "") != $pool) | .metadata.name] | length' 2>/dev/null)
  [ "${inconsistent:-0}" -eq 0 ] && ok "池标签与 dedicated 污点值一致" || warn "$inconsistent 个节点池标签与污点值不一致"
fi

echo "=== 7. 异构 / GPU ==="
if [ "$EN_GPU" != "1" ]; then
  skip "COMPUTE_ENABLE_GPU=0，跳过 GPU 检查"
else
  show "kubectl get nodes -o jsonpath (${GPU_RES})"
  gpu_total=$(kubectl get nodes -o json 2>/dev/null | jq -r --arg r "$GPU_RES" '[.items[].status.allocatable[$r] // "0" | tonumber] | add // 0' 2>/dev/null || echo 0)
  if [ "${gpu_total:-0}" -gt 0 ]; then ok "GPU 资源存在（总计 ${gpu_total} 个 $GPU_RES）"
  else bad "未发现 GPU 资源（$GPU_RES）；检查 VFIO 直通/驱动/device plugin（见 compute-architecture.md #7）"; fi
  show "kubectl -n kube-system get pods | grep -i 'device-plugin|nvidia'"
  if kubectl -n kube-system get pods 2>/dev/null | grep -qiE 'device-plugin|nvidia'; then ok "device plugin 已部署"
  else warn "未发现 device plugin Pod"; fi
fi

echo "=== 8. 计算告警规则 ==="
show "kubectl -n $PROM_NS get prometheusrule cluster-alerts"
if kubectl -n "$PROM_NS" get prometheusrule cluster-alerts >/dev/null 2>&1; then
  body=$(kubectl -n "$PROM_NS" get prometheusrule cluster-alerts -o yaml 2>/dev/null)
  cnt=0
  for a in CPUThrottlingHigh NodeAllocatableOvercommit QuotaNearFull UnschedulablePods; do
    printf '%s' "$body" | grep -q "$a" && cnt=$((cnt+1)) || warn "缺少计算告警规则 $a（make alerts 重放）"
  done
  [ "$cnt" -ge 3 ] && ok "计算告警规则在位（$cnt/4）"
else
  warn "未找到 PrometheusRule cluster-alerts（监控未就绪？）"
fi

}

# ================= 演练/压测 =================
DRILL_DONE=0
cleanup() {
  if [ "$DRILL_DONE" = "1" ]; then
    echo "  [=] 清理演练命名空间 $DRILL_NS ..."
    kubectl delete namespace "$DRILL_NS" --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

run_drill() {
echo "=== 9. 演练/压测（ns=$DRILL_NS image=$DRILL_IMAGE）==="
DRILL_DONE=1
show "kubectl delete namespace $DRILL_NS（幂等清理）"
kubectl delete namespace "$DRILL_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
show "kubectl create namespace $DRILL_NS"
kubectl create namespace "$DRILL_NS" >/dev/null 2>&1 || true
# PSA baseline（受限）
kubectl label namespace "$DRILL_NS" pod-security.kubernetes.io/enforce=baseline --overwrite >/dev/null 2>&1 || true

show "kubectl apply deployment/compute-stress（requests=${STRESS_CPU}/${STRESS_MEM}）"
kubectl apply -n "$DRILL_NS" -f - >/dev/null 2>&1 <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: compute-stress
  labels: {app: compute-stress}
spec:
  replicas: 1
  selector: {matchLabels: {app: compute-stress}}
  template:
    metadata: {labels: {app: compute-stress}}
    spec:
      containers:
      - name: stress
        image: ${DRILL_IMAGE}
        command: ["sh","-c","while true; do :; done"]
        resources:
          requests: {cpu: "${STRESS_CPU}", memory: "${STRESS_MEM}"}
          limits:   {cpu: "${STRESS_CPU}", memory: "512Mi"}
      terminationGracePeriodSeconds: 0
EOF

show "kubectl -n $DRILL_NS rollout status deploy/compute-stress --timeout=${DRILL_TIMEOUT}s"
if kubectl -n "$DRILL_NS" rollout status deploy/compute-stress --timeout="${DRILL_TIMEOUT}s" >/dev/null 2>&1; then
  ok "stress Pod 调度并 Running"
else
  bad "stress Pod 未就绪（资源不足或镜像 $DRILL_IMAGE 未镜像到 Harbor）"
  kubectl -n "$DRILL_NS" get pods -o wide 2>/dev/null | sed 's/^/    /'
  kubectl -n "$DRILL_NS" describe pod -l app=compute-stress 2>/dev/null | sed -n '/Events/,/^$/p' | sed 's/^/    /'
fi
qos=$(kubectl -n "$DRILL_NS" get pod -l app=compute-stress -o jsonpath='{.items[0].status.qosClass}' 2>/dev/null)
[ -n "$qos" ] && { [ "$qos" != "BestEffort" ] && ok "QoS=$qos" || warn "QoS=$qos（应设 requests 避免 BestEffort）"; }

show "kubectl top pod -n $DRILL_NS"
podtop=""
for i in $(seq 1 6); do
  podtop=$(kubectl top pod -n "$DRILL_NS" 2>/dev/null || true)
  printf '%s\n' "$podtop" | grep -q 'compute-stress' && break
  sleep 5
done
if printf '%s\n' "$podtop" | grep -q 'compute-stress'; then
  printf '%s\n' "$podtop" | sed 's/^/  /'; ok "metrics 通路正常（kubectl top 有数据）"
else
  warn "kubectl top 无数据（metrics-server 未就绪或采集延迟）"
fi

if [ "$EN_HPA" = "1" ] && kubectl top nodes >/dev/null 2>&1; then
  show "kubectl apply hpa/compute-stress-hpa（cpu 50%, 1-3）"
  kubectl apply -n "$DRILL_NS" -f - >/dev/null 2>&1 <<'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: compute-stress-hpa
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: compute-stress}
  minReplicas: 1
  maxReplicas: 3
  metrics:
  - type: Resource
    resource: {name: cpu, target: {type: Utilization, averageUtilization: 50}}
EOF
  echo "       [=] 等待 HPA 采集目标值（最多 60s）..."
  for i in $(seq 1 12); do
    tgt=$(kubectl -n "$DRILL_NS" get hpa compute-stress-hpa -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || true)
    [ -n "$tgt" ] && break
    sleep 5
  done
  if [ -n "${tgt:-}" ]; then ok "HPA TARGETS 采集到 CPU=${tgt}%"
  else warn "HPA 目标值暂未采集（可稍后再看 kubectl get hpa -n $DRILL_NS）"; fi
else
  skip "HPA 演练（未启用或无 metrics-server）"
fi

echo "  [=] 演练完成，退出时自动清理 ns $DRILL_NS"
}

case "$TARGET" in
  readonly) run_readonly;;
  drill|all) run_readonly; run_drill;;
  drill-only) run_drill;;
  *) echo "[!] 未知 TARGET=$TARGET（readonly|drill|drill-only|all）"; exit 2;;
esac

echo ""
[ "$FAIL" -eq 0 ] && echo "[+] 计算验收通过（警告/跳过项请逐条确认）" || echo "[!] 计算验收存在失败项"
exit "$FAIL"