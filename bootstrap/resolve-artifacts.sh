#!/usr/bin/env bash
# 按 fleet 模式解析所需制品，生成 locks/<mode>-<env>-<type>.lock
# 规则（A+B）：
#   B：组件 component.yaml 里显式 images/artifacts 优先；
#   A：若组件未显式声明但给了 chart，则 helm template 提取镜像并按 scheme C 推到 Harbor 目标。
# 用法: bash bootstrap/resolve-artifacts.sh <mode> [env]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-all-in-one}"
ENVNAME="${2:-drill}"
CTYPE="${CLUSTER_TYPE:-all}"
HARBOR_HOST="${HARBOR_HOST:-harbor.test.baokuaiyun.com}"
HARBOR_PROJECT="${HARBOR_PROJECT:-baokuaiyun}"
CHART_DIR="${HELM_CHARTS_DIR:-/data/kvm/charts}"
OUT_DIR="${ROOT}/locks"
OUT="${OUT_DIR}/${MODE}-${ENVNAME}-${CTYPE}.lock"

[ -f "${ROOT}/fleet/${MODE}/components.yaml" ] || { echo "[!] 无 fleet/${MODE}/components.yaml"; exit 1; }
mkdir -p "$OUT_DIR"

# scheme C：去 registry 域，剩余段用 - 拼；核心 basename
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

# 读取 fleet/<mode>/components.yaml 的 components 列表
mapfile -t COMPS < <(awk '/^components:/{f=1;next} /^[a-zA-Z]/{f=0} f&&/^[[:space:]]*-/{gsub(/^[[:space:]]*-[[:space:]]*/,"");gsub(/[[:space:]]*$/,"");print}' "${ROOT}/fleet/${MODE}/components.yaml")

tmp="$(mktemp)"
echo "# mode=${MODE} env=${ENVNAME} generated=$(date -Iseconds)" > "$tmp"
echo "# format: <src> <harbor-target>" >> "$tmp"

for c in "${COMPS[@]}"; do
  dir="$(find "${ROOT}/components" -maxdepth 2 -type d -name "$c" | head -1)"
  [ -n "$dir" ] || { echo "[=] 组件 ${c} 无目录，跳过"; continue; }
  cy="${dir}/component.yaml"
  [ -f "$cy" ] || { echo "[=] ${c} 无 component.yaml，跳过"; continue; }

  # 按集群类型过滤（A=管理/开发者  B=生产/业务  all=合一）
  if [ "$CTYPE" != "all" ]; then
    ctype_field="$(awk '/^type:/{gsub(/[][ ]/,"");sub(/^type:/,"");print}' "$cy")"
    if [ -n "$ctype_field" ]; then
      case ",$ctype_field," in
        *",$CTYPE,"*) : ;;
        *) echo "[=] ${c} 不属集群类型 ${CTYPE}，跳过" >&2; continue ;;
      esac
    fi
  fi

  # B：显式 images / artifacts
  lines="$(awk '
    /^images:/{f=1;next}
    /^artifacts:/{f=1;next}
    /^[a-zA-Z]/{f=0}
    f&&/^[[:space:]]*-/{sub(/^[[:space:]]*-[[:space:]]*/,"");print}
  ' "$cy")"

  if [ -z "$lines" ]; then
    # A：helm template 提取
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
    echo "[=] ${c}: 无镜像声明且无法解析" >> /dev/stderr
  fi
done

# 去重 + 排序
{ grep '^#' "$tmp"; grep -v '^#' "$tmp" | sort -u; } > "$OUT"
rm -f "$tmp"
echo "[+] 生成 ${OUT}（$(grep -vc '^#' "$OUT") 条制品）"
