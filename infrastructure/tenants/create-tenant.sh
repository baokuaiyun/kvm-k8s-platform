#!/usr/bin/env bash
# 创建租户（Mode A: Namespace 隔离）
# 用法: bash create-tenant.sh <租户名> [cpu] [内存Gi]
# 例: bash create-tenant.sh team-a 2 4
set -euo pipefail

TENANT="${1:-}"
CPU="${2:-2}"
MEM_GI="${3:-4}"

[ -z "$TENANT" ] && { echo "用法: bash create-tenant.sh <租户名> [cpu] [内存Gi]"; exit 1; }

case "$TENANT" in
  team-*) NS="$TENANT" ;;
  *)      NS="team-${TENANT}" ;;
esac
BASELINE="$(dirname "$0")/../security/tenant-baseline.yaml"

echo "[+] 创建租户 namespace: ${NS}"

# 1. 创建 namespace
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# 2. 应用安全基线（替换 __NAMESPACE__ 占位符）
sed "s/__NAMESPACE__/${NS}/g" "$BASELINE" | kubectl apply -f -

# 3. 创建 RBAC（租户可管理 PG/Redis CRD）
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-admin
  namespace: ${NS}
rules:
- apiGroups: ["", "apps", "batch", "networking.k8s.io"]
  resources: ["*"]
  verbs: ["*"]
- apiGroups: ["postgresql.cnpg.io"]
  resources: ["clusters", "backups", "scheduledbackups", "poolers"]
  verbs: ["*"]
- apiGroups: ["redis.redis.opstreelabs.in"]
  resources: ["redis", "rediscluster"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-admin-binding
  namespace: ${NS}
subjects:
- kind: Group
  name: ${TENANT}-admins
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: tenant-admin
  apiGroup: rbac.authorization.k8s.io
EOF

# 4. 生成 ServiceAccount + kubeconfig token
kubectl -n "$NS" create serviceaccount tenant-admin --dry-run=client -o yaml | kubectl apply -f -

TOKEN=$(kubectl -n "$NS" create token tenant-admin --duration=8760h 2>/dev/null || echo "")
if [ -n "$TOKEN" ]; then
  echo "[+] 租户 kubeconfig token 已生成（有效期 1 年）"
  echo "    export TOKEN=${TOKEN}"
fi

echo "[+] 租户 ${TENANT} 创建完成 (namespace: ${NS}, CPU: ${CPU}, 内存: ${MEM_GI}Gi)"
