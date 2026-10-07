#!/usr/bin/env bash
# PV 云盘自动扩容控制器（单次扫描）
#   读 Prometheus 的 kubelet_volume_stats_* -> 对超阈值的 Bound PVC 自动 patch
#   spec.resources.requests.storage，由 CSI external-resizer 完成在线扩容。
# 默认 DRY_RUN=1：只写 auto-expand/recommendation 注解并打印，不实际扩容。
# 详见 docs/cloud-disk-data-solution.md §5、docs/parameters.md
# 用法:
#   bash scripts/auto-expand-pvc.sh              # dry-run（默认）
#   DRY_RUN=0 bash scripts/auto-expand-pvc.sh    # 实际扩容
set -euo pipefail

DRY_RUN="${DRY_RUN:-${PV_AUTOSCALER_DRY_RUN:-1}}"
THRESHOLD="${THRESHOLD:-${PV_AUTOSCALER_THRESHOLD:-0.80}}"
FACTOR="${FACTOR:-${PV_AUTOSCALER_FACTOR:-1.5}}"
MIN_STEP="${MIN_STEP:-${PV_AUTOSCALER_MIN_STEP:-5Gi}}"
MAX_SIZE="${MAX_SIZE:-${PV_AUTOSCALER_MAX_SIZE:-100Gi}}"
COOLDOWN_MIN="${COOLDOWN_MIN:-${PV_AUTOSCALER_COOLDOWN_MIN:-60}}"
INCLUDE_NS="${PV_AUTOSCALER_NAMESPACES:-}"
EXCLUDE="${PV_AUTOSCALER_EXCLUDE:-}"
ALERT_NS="${ALERT_NAMESPACE:-monitoring}"
PROM_SVC="${PROM_SVC:-monitoring-kube-prometheus-prometheus}"

log()  { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
info() { echo "    $*"; }

command -v kubectl >/dev/null 2>&1 || { echo "[x] 需要 kubectl"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "[x] 需要 jq"; exit 2; }
kubectl cluster-info >/dev/null 2>&1 || { echo "[x] 无法连接集群"; exit 2; }

G=$((1024 * 1024 * 1024))

qty_to_bytes() {
  local q="$1"
  case "$q" in
    *Ti) echo $(( ${q%Ti} * 1024 * 1024 * 1024 * 1024 )) ;;
    *Gi) echo $(( ${q%Gi} * 1024 * 1024 * 1024 )) ;;
    *Mi) echo $(( ${q%Mi} * 1024 * 1024 )) ;;
    *Ki) echo $(( ${q%Ki} * 1024 )) ;;
    ""|*[!0-9]*) echo 0 ;;
    *) echo "$q" ;;
  esac
}

bytes_to_gi() { echo "$(( ($1 + G - 1) / G ))Gi"; }

# ---- Prometheus 查询（经 apiserver service proxy，最小权限，无需 curl）----
prom_query() {
  local q enc
  q="$1"
  enc=$(jq -rn --arg q "$q" '$q | @uri')
  kubectl -n "$ALERT_NS" get --raw --request-timeout=15s \
    "/api/v1/namespaces/${ALERT_NS}/services/http:${PROM_SVC}:9090/proxy/api/v1/query?query=${enc}" 2>/dev/null
}

log "读取卷用量（Prometheus ${ALERT_NS}/${PROM_SVC}）"
used_json="$(prom_query 'kubelet_volume_stats_used_bytes' || true)"
cap_json="$(prom_query 'kubelet_volume_stats_capacity_bytes' || true)"
[ -n "$used_json" ] && [ -n "$cap_json" ] || { warn "Prometheus 查询失败（检查 PROM_SVC/权限）；跳过本次"; exit 0; }

USAGE_TSV="$(jq -rn --slurpfile u <(printf '%s' "$used_json") --slurpfile c <(printf '%s' "$cap_json") '
  ($u[0].data.result | map({key: (.metric.namespace + "/" + .metric.persistentvolumeclaim), value: (.value[1]|tonumber)}) | from_entries) as $used
  | ($c[0].data.result | map({key: (.metric.namespace + "/" + .metric.persistentvolumeclaim), value: (.value[1]|tonumber)}) | from_entries) as $cap
  | $used | to_entries[] | select($cap[.key] != null and $cap[.key] > 0)
  | [.key, (.value|tostring), ($cap[.key]|tostring)] | join("\u001f")
' 2>/dev/null)" || true
[ -n "$USAGE_TSV" ] || { log "无卷用量数据"; exit 0; }

PVC_JSON="$(kubectl get pvc -A -o json)"
SC_JSON="$(kubectl get sc -o json)"

# SC -> allowVolumeExpansion
declare -A SC_EXPAND=()
while IFS=$'\t' read -r name exp; do
  [ -n "$name" ] && SC_EXPAND["$name"]="$exp"
done < <(jq -r '.items[] | [.metadata.name, (.allowVolumeExpansion // false)] | @tsv' <<<"$SC_JSON")

# ns/name -> 字段
declare -A PVC_SC PVC_REQ PVC_CAP PVC_DISABLED PVC_LAST PVC_MAX PVC_PHASE
while IFS=$'\x1f' read -r ns name sc req cap dis last max phase; do
  [ -n "$name" ] || continue
  k="$ns/$name"
  PVC_SC["$k"]="$sc"; PVC_REQ["$k"]="$req"; PVC_CAP["$k"]="$cap"
  PVC_DISABLED["$k"]="$dis"; PVC_LAST["$k"]="$last"; PVC_MAX["$k"]="$max"
  PVC_PHASE["$k"]="$phase"
done < <(jq -r '.items[] | [
  .metadata.namespace, .metadata.name,
  (.spec.storageClassName // ""),
  (.spec.resources.requests.storage // ""),
  (.status.capacity.storage // ""),
  (.metadata.annotations["auto-expand/disabled"] // ""),
  (.metadata.annotations["auto-expand/last-expanded"] // ""),
  (.metadata.annotations["auto-expand/max-size"] // ""),
  (.status.phase // "")
] | map(. // "") | join("\u001f")' <<<"$PVC_JSON")

now=$(date +%s)
expanded=0
skipped=0
changed=0

while IFS=$'\x1f' read -r key used cap; do
  [ -n "$key" ] || continue
  ns="${key%%/*}"; name="${key#*/}"

  # 白名单/黑名单
  if [ -n "$INCLUDE_NS" ] && [[ ",$INCLUDE_NS," != *",$ns,"* ]]; then continue; fi
  if [ -n "$EXCLUDE" ]; then
    case ",$EXCLUDE," in
      *",$ns,"*|*",$ns/$name,"*) info "skip $key（排除名单）"; skipped=$((skipped+1)); continue ;;
    esac
  fi
  [ -n "${PVC_SC[$key]:-}" ] || continue
  sc="${PVC_SC[$key]}"
  [ "${SC_EXPAND[$sc]:-false}" = "true" ] || continue
  [ "${PVC_DISABLED[$key]:-}" = "true" ] && { skipped=$((skipped+1)); continue; }
  if [ "${PVC_PHASE[$key]:-}" != "Bound" ]; then
    info "skip $key（phase=${PVC_PHASE[$key]:-Unknown}，未 Bound）"; skipped=$((skipped+1)); continue
  fi

  ratio=$(awk -v u="$used" -v c="$cap" 'BEGIN{printf "%.4f", u/c}')
  awk -v r="$ratio" -v t="$THRESHOLD" 'BEGIN{exit !(r>=t)}' || continue

  # 正在扩容中（requested > capacity）→ 交给告警，跳过
  req_b=$(qty_to_bytes "${PVC_REQ[$key]}")
  cap_b=$(qty_to_bytes "${PVC_CAP[$key]}"); [ "$cap_b" -gt 0 ] || cap_b="$req_b"
  if [ "$req_b" -gt "$cap_b" ]; then
    info "skip $key（扩容进行中 ${PVC_REQ[$key]} > ${PVC_CAP[$key]}）"; skipped=$((skipped+1)); continue
  fi

  # 冷却
  last="${PVC_LAST[$key]:-0}"; [ -n "$last" ] || last=0
  if [ "$last" -gt 0 ] && [ $(( now - last )) -lt $(( COOLDOWN_MIN * 60 )) ]; then
    info "skip $key（冷却中，上次 $(( (now - last) / 60 )) 分钟前）"; skipped=$((skipped+1)); continue
  fi

  cur="$cap_b"
  target=$(awk -v c="$cur" -v f="$FACTOR" -v s="$(qty_to_bytes "$MIN_STEP")" \
    'BEGIN{t=c*f; if(c+s>t)t=c+s; printf "%d", t}')
  target=$(( (target + G - 1) / G * G ))

  max_q="${PVC_MAX[$key]:-$MAX_SIZE}"; max_b=$(qty_to_bytes "$max_q")
  if [ "$max_b" -gt 0 ] && [ "$target" -gt "$max_b" ]; then target="$max_b"; fi
  if [ "$target" -le "$cur" ]; then
    info "skip $key（已达上限 ${max_q}）"; skipped=$((skipped+1)); continue
  fi

  tgt_q=$(bytes_to_gi "$target")
  pct=$(awk -v r="$ratio" 'BEGIN{printf "%.1f", r*100}')
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN $key: 用量 ${pct}%，建议 ${PVC_CAP[$key]:-?} -> ${tgt_q}（sc=${sc}）"
    kubectl -n "$ns" annotate pvc "$name" "auto-expand/recommendation=${tgt_q}" --overwrite >/dev/null
    changed=$((changed+1))
  else
    log "扩容 $key: ${PVC_CAP[$key]:-?} -> ${tgt_q}（用量 ${pct}%，sc=${sc}）"
    if kubectl -n "$ns" patch pvc "$name" --type merge \
      -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"${tgt_q}\"}}}}" >/dev/null; then
      kubectl -n "$ns" annotate pvc "$name" \
        "auto-expand/last-expanded=${now}" "auto-expand/recommendation-" >/dev/null
      expanded=$((expanded+1))
    else
      warn "扩容失败 $key -> ${tgt_q}（跳过）"
    fi
  fi
done <<<"$USAGE_TSV"

if [ "$DRY_RUN" = "1" ]; then
  log "完成（dry-run）：建议扩容 $changed 个，跳过 $skipped 个"
else
  log "完成：已扩容 $expanded 个，跳过 $skipped 个"
fi
