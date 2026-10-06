#!/usr/bin/env bash
# 部署共享平台数据：CNPG PostgreSQL（多库）+ RedisReplication
# 渲染 __占位__ -> 变量后 kubectl apply，并创建角色/应用命名空间凭据
# 用法: platform/platform-data/deploy.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
RENDER="/tmp/platform-data-render"

: "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY 未设置（见 variables.mk/acr.env）}"
NS="${PLATFORM_DATA_NS:-platform-data}"
: "${PG_INSTANCES:=1}"
: "${PG_SYNC_REPLICAS:=0}"
: "${REDIS_CLUSTER_SIZE:=1}"
: "${PG_STORAGE_SIZE:=20Gi}"
: "${REDIS_STORAGE_SIZE:=5Gi}"
: "${STORAGE_CLASS:=app-storage}"
: "${SNAPSHOT_CLASS:=longhorn}"
# 异地对象存储（barman）：留空则不做异地归档（drill 默认）
: "${PG_BACKUP_BUCKET:=}"
: "${S3_ENDPOINT:=}"
: "${PG_HARBOR_PASS:?PG_HARBOR_PASS 未设置}"
: "${PG_GITLAB_PASS:?PG_GITLAB_PASS 未设置}"
: "${PG_CASDOOR_PASS:?PG_CASDOOR_PASS 未设置}"
: "${REDIS_PASS:?REDIS_PASS 未设置}"

command -v kubectl >/dev/null 2>&1 || { echo "[!] 需要 kubectl"; exit 1; }

echo "[+] 渲染清单 (ns=${NS} pg_instances=${PG_INSTANCES} sync=${PG_SYNC_REPLICAS} redis_size=${REDIS_CLUSTER_SIZE})"
rm -rf "$RENDER"; mkdir -p "$RENDER"
for f in "$DIR"/*.yaml; do
  sed -e "s|__IMAGE_REPOSITORY__|${IMAGE_REPOSITORY}|g" \
      -e "s|__PLATFORM_DATA_NS__|${NS}|g" \
      -e "s|__PG_INSTANCES__|${PG_INSTANCES}|g" \
      -e "s|__PG_SYNC_REPLICAS__|${PG_SYNC_REPLICAS}|g" \
      -e "s|__REDIS_CLUSTER_SIZE__|${REDIS_CLUSTER_SIZE}|g" \
      -e "s|__PG_STORAGE_SIZE__|${PG_STORAGE_SIZE}|g" \
      -e "s|__REDIS_STORAGE_SIZE__|${REDIS_STORAGE_SIZE}|g" \
      -e "s|__STORAGE_CLASS__|${STORAGE_CLASS}|g" \
      -e "s|__SNAPSHOT_CLASS__|${SNAPSHOT_CLASS}|g" \
      -e "s|__PG_BACKUP_BUCKET__|${PG_BACKUP_BUCKET}|g" \
      -e "s|__S3_ENDPOINT__|${S3_ENDPOINT}|g" \
      "$f" > "$RENDER/$(basename "$f")"
done

# 单实例时同步复制无意义，删除 synchronous 段
if [ "${PG_SYNC_REPLICAS}" -lt 1 ]; then
  sed -i '/# __SYNC_BEGIN__/,/# __SYNC_END__/d' "$RENDER/postgres-cluster.yaml"
else
  sed -i '/# __SYNC_BEGIN__/d; /# __SYNC_END__/d' "$RENDER/postgres-cluster.yaml"
fi

# 未配置对象存储时移除 barman 异地归档段（drill）
if [ -z "${PG_BACKUP_BUCKET}" ]; then
  echo "[=] 未配置 PG_BACKUP_BUCKET，跳过 barman 异地归档（仅本地快照）"
  sed -i '/# __BARMAN_BEGIN__/,/# __BARMAN_END__/d' "$RENDER/postgres-cluster.yaml"
else
  sed -i '/# __BARMAN_BEGIN__/d; /# __BARMAN_END__/d' "$RENDER/postgres-cluster.yaml"
fi

echo "[+] 创建命名空间..."
kubectl create ns "$NS"        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create ns harbor       --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create ns gitlab       --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create ns casdoor      --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# 幂等创建 Secret
upsert_secret() {
  local ns=$1 name=$2; shift 2
  kubectl -n "$ns" create secret generic "$name" "$@" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "    secret ${ns}/${name}"
}

echo "[+] 创建角色凭据 (CNPG managed.roles 需要 username/password 两个 key)..."
upsert_secret "$NS" harbor-pg-cred  --from-literal=username=harbor  --from-literal=password="$PG_HARBOR_PASS"
upsert_secret "$NS" gitlab-pg-cred  --from-literal=username=gitlab  --from-literal=password="$PG_GITLAB_PASS"
upsert_secret "$NS" casdoor-pg-cred --from-literal=username=casdoor --from-literal=password="$PG_CASDOOR_PASS"
upsert_secret "$NS" platform-redis-cred --from-literal=password="$REDIS_PASS"

# 异地对象存储凭据（仅生产配置了 PG_BACKUP_BUCKET 时创建）
if [ -n "${PG_BACKUP_BUCKET}" ]; then
  : "${S3_ACCESS_KEY:?PG_BACKUP_BUCKET 已设置但缺 S3_ACCESS_KEY（见 acr.env）}"
  : "${S3_SECRET_KEY:?PG_BACKUP_BUCKET 已设置但缺 S3_SECRET_KEY（见 acr.env）}"
  upsert_secret "$NS" platform-pg-backup-cred \
    --from-literal=ACCESS_KEY_ID="$S3_ACCESS_KEY" \
    --from-literal=SECRET_ACCESS_KEY="$S3_SECRET_KEY"
fi

# GitLab chart 以 Secret 方式消费（跨 ns 不能引用，故复制到 gitlab ns）
# Harbor/Casdoor 的密码由各自的 values/configmap 直接注入，无需复制
echo "[+] 创建应用命名空间凭据（gitlab ns）..."
upsert_secret gitlab gitlab-pg-cred    --from-literal=password="$PG_GITLAB_PASS"
upsert_secret gitlab gitlab-redis-cred --from-literal=password="$REDIS_PASS"

echo "[+] 应用 PG Cluster..."
kubectl apply -f "$RENDER/postgres-cluster.yaml"

echo "[+] 等待 platform-pg ready（首次拉镜像/建库可能较久）..."
kubectl -n "$NS" wait --for=condition=Ready cluster/platform-pg --timeout=600s || \
  { echo "[!] cluster 未在超时内 Ready，请检查 kubectl -n $NS get cluster,pods"; }

echo "[+] 创建独立数据库 (Database CR)..."
kubectl apply -f "$RENDER/databases.yaml"

echo "[+] 应用 Redis（普通 StatefulSet；redis-operator 对 RedisReplication 有 panic bug）..."
kubectl apply -f "$RENDER/redis.yaml"

echo "[+] 应用定时备份（缺 VolumeSnapshot CRD 时忽略）..."
kubectl apply -f "$RENDER/scheduled-backup.yaml" || echo "[!] ScheduledBackup 跳过（缺 VolumeSnapshot CRD）"

echo ""
echo "[+] 完成。查看:"
echo "    kubectl -n $NS get cluster,database,redisreplication,scheduledbackup"
echo "    PG  端点: platform-pg-rw.${NS}.svc.cluster.local:5432"
echo "    Redis 端点: platform-redis.${NS}.svc.cluster.local:6379"
