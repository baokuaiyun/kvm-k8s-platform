#!/usr/bin/env bash
# 按 fleet 单元（单 mode/layer=单独；多单元=叠加）解析所需制品
#   单元来源: 参数 <units> (逗号分隔) 或 env FLEET_MODES / FLEET_MODE；默认 all-in-one
#   单元解析: 先找 gitops/fleet/layers/<u>/components.yaml，再找 gitops/fleet/<u>/components.yaml
#   叠加 = 各单元组件并集去重；再按 CLUSTER_TYPE 过滤
#   生成: gitops/locks/<units排序+连接>-<env>-<type>.lock
# 规则（A+B）：B=组件显式 images/artifacts；A=helm template 提取并按 scheme C 生成 Harbor 目标。
set -euo pipefail

GITOPS_DIR="${GITOPS_DIR:-$(cd "$(dirname "$0")/../gitops" && pwd)}"
UNITS_ARG="${1:-${FLEET_MODES:-${FLEET_MODE:-all-in-one}}}"
ENVNAME="${2:-drill}"
CTYPE="${CLUSTER_TYPE:-all}"
HARBOR_HOST="${HARBOR_HOST:-harbor.test.baokuaiyun.com}"
HARBOR_PROJECT="${HARBOR_PROJECT:-baokuaiyun}"
CHART_DIR="${HELM_CHARTS_DIR:-/data/kvm/charts}"

# 单元列表 + 稳定 lock 名
IFS=',' read -r -a UNITS <<< "$UNITS_ARG"
LNAME="$(printf '%s\n' "${UNITS[@]}" | sort | paste -sd'+' -)"
OUT_DIR="${GITOPS_DIR}/locks"
OUT="${OUT_DIR}/${LNAME}-${ENVNAME}-${CTYPE}.lock"
mkdir -p "$OUT_DIR"

scheme_c() {
  local ref="$1" path="$1" first
  first="${path%%/*}"
  if [ "$first" != "$path" ] && [[ "$first" == *.* ]]; then path="${path#*/}"; fi
  case "$ref" in
    registry.k8s.io/*) echo "${ref##*/}" ;;
    ghcr.io/kube-vip/kube-vip*) echo kube-vip ;;
    *) echo "$path" | tr '/' '-' ;;
  esac
}

# 逻辑组件名 → 具体目录/制品名（存储驱动可替换：storage -> storage-<STORAGE_BACKEND>）
resolve_component() {
  case "$1" in
    storage) echo "storage-${STORAGE_BACKEND:-host-zfs-iscsi}" ;;
    *) echo "$1" ;;
  esac
}

# 收集组件（并集去重，保持首次出现顺序）
COMPS=(); declare -A SEEN=()
for u in "${UNITS[@]}"; do
  f=""
  for cand in "${GITOPS_DIR}/fleet/layers/${u}/components.yaml" "${GITOPS_DIR}/fleet/${u}/components.yaml"; do
    [ -f "$cand" ] && { f="$cand"; break; }
  done
  [ -n "$f" ] || { echo "[!] 单元 ${u} 无 components.yaml，跳过" >&2; continue; }
  while read -r c; do
    [ -z "$c" ] && continue
    [ -n "${SEEN[$c]:-}" ] && continue
    SEEN[$c]=1; COMPS+=("$c")
  done < <(awk '/^components:/{f=1;next} /^[a-zA-Z]/{f=0} f&&/^[[:space:]]*-/{gsub(/^[[:space:]]*-[[:space:]]*/,"");gsub(/[[:space:]]*$/,"");print}' "$f")
done

tmp="$(mktemp)"
echo "# units=${LNAME} env=${ENVNAME} type=${CTYPE} generated=$(date -Iseconds)" > "$tmp"
echo "# format: <src> <harbor-target>" >> "$tmp"

for c in "${COMPS[@]}"; do
  rc="$(resolve_component "$c")"
  dir="$(find "${GITOPS_DIR}/components" -maxdepth 2 -type d -name "$rc" | head -1)"
  [ -n "$dir" ] || { echo "[=] 组件 ${c}(${rc}) 无目录，跳过" >&2; continue; }
  cy="${dir}/component.yaml"
  [ -f "$cy" ] || { echo "[=] ${c} 无 component.yaml，跳过" >&2; continue; }

  if [ "$CTYPE" != "all" ]; then
    ctype_field="$(awk '/^type:/{gsub(/[][ ]/,"");sub(/^type:/,"");print}' "$cy")"
    if [ -n "$ctype_field" ]; then
      case ",$ctype_field," in
        *",$CTYPE,"*) : ;;
        *) echo "[=] ${c} 不属集群类型 ${CTYPE}，跳过" >&2; continue ;;
      esac
    fi
  fi

  lines="$(awk '
    /^images:/{f=1;next}
    /^artifacts:/{f=1;next}
    /^[a-zA-Z]/{f=0}
    f&&/^[[:space:]]*-/{sub(/^[[:space:]]*-[[:space:]]*/,"");print}
  ' "$cy")"

  if [ -z "$lines" ]; then
    chart="$(awk '/^chart:/{print $2}' "$cy")"
    if [ -n "$chart" ] && [ -f "${CHART_DIR}/${chart}" ]; then
      echo "[A] ${c}: helm template 提取镜像 (${chart})" >&2
      lines="$(helm template "$c" "${CHART_DIR}/${chart}" 2>/dev/null \
        | grep -oE 'image: "?[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+' \
        | sed -E 's/image: "?//' | sort -u \
        | while read -r src; do
            repo="${src%%:*}"; tag="${src##*:}"
            printf '%s %s\n' "$src" "${HARBOR_HOST}/${HARBOR_PROJECT}/$(scheme_c "$repo"):${tag}"
          done)" || true
    fi
  fi

  if [ -n "$lines" ]; then
    echo "$lines" | awk 'NF>=2{print $1"\t"$2}' >> "$tmp"
  else
    echo "[=] ${c}: 无镜像声明且无法解析" >&2
  fi
done

{ grep '^#' "$tmp" || true; grep -v '^#' "$tmp" | sort -u || true; } > "$OUT"
rm -f "$tmp"
echo "[+] 单元[${LNAME}] 生成 ${OUT}（$(grep -vc '^#' "$OUT") 条制品）"
