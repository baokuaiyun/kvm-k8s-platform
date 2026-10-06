#!/usr/bin/env bash
# 由 stack（单元集合）生成 Flux ResourceSet（按组件渲染 OCIRepository+Kustomization）
#   单元=layer 或 预设 mode；并集去重；按 CLUSTER_TYPE 过滤
# 用法: bash bootstrap/render-stack.sh <units> [env] [type] [--apply]
set -euo pipefail
GITOPS_DIR="${GITOPS_DIR:-$(cd "$(dirname "$0")/../gitops" && pwd)}"
HARBOR_HOST="${HARBOR_HOST:-harbor.test.baokuaiyun.com}"
HARBOR_PROJECT="${HARBOR_PROJECT:-baokuaiyun}"
UNITS_ARG="${1:-${FLEET_MODES:-${FLEET_MODE:-all-in-one}}}"
ENVNAME="${2:-${FLEET_ENV:-drill}}"
CTYPE="${3:-${CLUSTER_TYPE:-all}}"
APPLY=0; for a in "$@"; do [ "$a" = "--apply" ] && APPLY=1; done

IFS=',' read -r -a UNITS <<< "$UNITS_ARG"
LNAME="$(printf '%s\n' "${UNITS[@]}" | sort | paste -sd'+' -)"
OUT="${GITOPS_DIR}/locks/stack-${LNAME}-${ENVNAME}-${CTYPE}.yaml"

# 收集组件（并集去重 + 类型过滤）
COMPS=(); declare -A SEEN=()
for u in "${UNITS[@]}"; do
  f=""
  for cand in "${GITOPS_DIR}/fleet/layers/${u}/components.yaml" "${GITOPS_DIR}/fleet/${u}/components.yaml"; do
    [ -f "$cand" ] && { f="$cand"; break; }
  done
  [ -n "$f" ] || { echo "[!] 单元 ${u} 无 components.yaml" >&2; continue; }
  while read -r c; do
    [ -z "$c" ] && continue; [ -n "${SEEN[$c]:-}" ] && continue; SEEN[$c]=1; COMPS+=("$c")
  done < <(awk '/^components:/{f=1;next} /^[a-zA-Z]/{f=0} f&&/^[[:space:]]*-/{gsub(/^[[:space:]]*-[[:space:]]*/,"");gsub(/[[:space:]]*$/,"");print}' "$f")
done

# 生成 inputs（含 type 过滤）
inputs=""
for c in "${COMPS[@]}"; do
  dir="$(find "${GITOPS_DIR}/components" -maxdepth 2 -type d -name "$c" | head -1)"
  [ -n "$dir" ] && [ -f "${dir}/component.yaml" ] || continue
  if [ "$CTYPE" != "all" ]; then
    tf="$(awk '/^type:/{gsub(/[][ ]/,"");sub(/^type:/,"");print}' "${dir}/component.yaml")"
    case ",$tf," in *",$CTYPE,"*) : ;; *) continue ;; esac
  fi
  # 仅纳入"真正的部署组件"（本地提供该环境 overlays）
  if [ ! -d "${dir}/overlays/${ENVNAME}" ]; then
    echo "[=] ${c} 无 overlays/${ENVNAME}（非部署组件），跳过" >&2; continue
  fi
  # 仅纳入已构建制品的组件（检测式；有 robot 凭据时）。用 oras（OCI artifact 不支持 skopeo inspect）
  if [ -n "${HARBOR_ROBOT_PASS:-}" ]; then
    RU="robot\$${HARBOR_PROJECT}+pushpull"
    if ! env no_proxy='*' NO_PROXY='*' http_proxy= https_proxy= \
         oras manifest fetch --insecure --username "${RU}" --password "${HARBOR_ROBOT_PASS}" \
         "${HARBOR_HOST}/${HARBOR_PROJECT}/${c}:latest" >/dev/null 2>&1; then
      echo "[=] ${c} 无 Harbor 制品，跳过（未构建）" >&2; continue
    fi
  fi
  inputs+="    - {component: \"${c}\", tag: \"latest\", environment: \"${ENVNAME}\"}
"
done

{
cat <<EOF
# 由 render-stack 生成：units=${LNAME} env=${ENVNAME} type=${CTYPE}
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: stack
  namespace: flux-system
  annotations:
    fluxcd.controlplane.io/reconcileEvery: "10m"
spec:
  inputs:
${inputs}  resources:
    - apiVersion: v1
      kind: Namespace
      metadata:
        name: << inputs.component >>
    - apiVersion: v1
      kind: ServiceAccount
      metadata: {name: flux, namespace: << inputs.component >>}
    - apiVersion: rbac.authorization.k8s.io/v1
      kind: Role
      metadata: {name: flux-admin, namespace: << inputs.component >>}
      rules: [{apiGroups: ["*"], resources: ["*"], verbs: ["*"]}]
    - apiVersion: rbac.authorization.k8s.io/v1
      kind: RoleBinding
      metadata: {name: flux-admin, namespace: << inputs.component >>}
      roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: flux-admin}
      subjects: [{kind: ServiceAccount, name: flux, namespace: << inputs.component >>}]
    - apiVersion: rbac.authorization.k8s.io/v1
      kind: ClusterRoleBinding
      metadata: {name: flux-<< inputs.component >>}
      roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin}
      subjects: [{kind: ServiceAccount, name: flux, namespace: << inputs.component >>}]
    - apiVersion: v1
      kind: Secret
      metadata:
        name: harbor-auth
        namespace: << inputs.component >>
        annotations: {fluxcd.controlplane.io/copyFrom: "flux-system/harbor-auth"}
      type: kubernetes.io/dockerconfigjson
    - apiVersion: v1
      kind: Secret
      metadata:
        name: cosign-pub
        namespace: << inputs.component >>
        annotations: {fluxcd.controlplane.io/copyFrom: "flux-system/cosign-pub"}
    - apiVersion: source.toolkit.fluxcd.io/v1
      kind: OCIRepository
      metadata: {name: component, namespace: << inputs.component >>}
      spec:
        interval: 5m
        insecure: true
        secretRef: {name: harbor-auth}
        url: "oci://${HARBOR_HOST}/${HARBOR_PROJECT}/<< inputs.component >>"
        ref: {tag: << inputs.tag >>}
        verify: {provider: cosign, secretRef: {name: cosign-pub}}
    - apiVersion: kustomize.toolkit.fluxcd.io/v1
      kind: Kustomization
      metadata: {name: component, namespace: << inputs.component >>}
      spec:
        targetNamespace: << inputs.component >>
        interval: 30m
        prune: true
        wait: true
        timeout: 5m
        sourceRef: {kind: OCIRepository, name: component}
        path: "./overlays/<< inputs.environment >>"
EOF
} > "$OUT"

ncomp="$(printf '%s' "$inputs" | grep -c 'component:' || true)"
echo "[+] 生成 ${OUT}（组件: ${ncomp}）"
if [ "$ncomp" = 0 ]; then
  echo "[=] 无部署组件（无 overlays/${ENVNAME} 或未构建），跳过 apply"
  [ "$APPLY" = 1 ] && kubectl -n flux-system delete resourceset stack --ignore-not-found >/dev/null 2>&1 || true
  exit 0
fi
if [ "$APPLY" = 1 ]; then
  kubectl apply -f "$OUT"
  echo "[+] 已 apply ResourceSet/stack"
fi
