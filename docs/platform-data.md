# 共享平台数据层（platform-data）

> **本文是「数据平面」的实现分册（drill 形态 D：与应用同集群）。**
> 数据平面的定位、独立部署（形态 B，云无关）、跨集群消费与备份出口，见
> [`data-plane-management.md`](data-plane-management.md)。
>
> 全平台**一套 PostgreSQL 实例 + 一套 Redis**，各应用（Harbor / GitLab / Casdoor）
> 使用**独立数据库与角色**。由 `cloudnative-pg`（CNPG）管理 PG；Redis 因
> `redis-operator v0.17.0` 对 `RedisReplication` 的 panic bug，drill 用**普通 StatefulSet**
> （`platform/platform-data/redis.yaml`），`redis-replication.yaml` 保留待修复后启用。

## 一、拓扑

```
ns: platform-data
├── Cluster/platform-pg            # CNPG ≥ 1.25（Database CRD）
│     instances=${PG_INSTANCES}    # 随环境缩放
│     managed.roles: harbor / gitlab(superuser) / casdoor
│     backup.volumeSnapshot(SNAPSHOT_CLASS) + barman(OSS,PITR) + ScheduledBackup(每日)
├── Database/registry              # owner=harbor
├── Database/gitlabhq_production   # owner=gitlab
├── Database/casdoor               # owner=casdoor
└── Redis：drill=StatefulSet/platform-redis；目标=RedisReplication(哨兵/集群)（clusterSize=${REDIS_CLUSTER_SIZE}）

应用连接：
  PG   : platform-pg-rw.platform-data.svc.cluster.local:5432
  Redis: platform-redis.platform-data.svc.cluster.local:6379
```

## 二、为什么需要 CNPG ≥ 1.25

`Database` / `DatabaseRole` CRD 自 **v1.25** 引入。低于该版本无法声明式建多库，
只能 `bootstrap.initdb` 建单库或跑 Job。故 `variables.mk` 固定
`CNPG_VERSION=1.25.1`、chart `0.23.2`。

## 三、变量（`variables.mk`）

| 变量 | drill | prod | 说明 |
|---|---|---|---|
| `PG_INSTANCES` | 1 | 3 | CNPG 实例数（HA 需 ≥3 节点 + 反亲和） |
| `PG_SYNC_REPLICAS` | 0 | 1 | 同步复制从库数（0=异步，drill 单实例） |
| `REDIS_CLUSTER_SIZE` | 1 | 3 | RedisReplication 总 Pod 数（1 主 + N-1 从） |
| `LONGHORN_REPLICAS` | 2 | 3 | **必须同步上调，否则 CNPG HA 被单副本 PV 架空**（drill 2 节点需允许控制面调度） |
| `STORAGE_CLASS` | app-storage | app-storage | 规范 SC（drill=Longhorn / prod=云盘，见 `docs/storage-plan.md`） |
| `PG_BACKUP_BUCKET` / `S3_ENDPOINT` | 空 | OSS | 设置后启用 barman 异地归档/PITR |
| `PG_STORAGE_SIZE` / `REDIS_STORAGE_SIZE` | 20Gi / 5Gi | — | PVC 大小 |
| `PG_HARBOR_PASS` / `PG_GITLAB_PASS` / `PG_CASDOOR_PASS` / `REDIS_PASS` | changeme-* | 放 `acr.env` | 各角色/Redis 密码 |

## 四、部署

```bash
make operators        # 先装 CNPG + redis-operator
make platform-data    # = bash platform/platform-data/deploy.sh
```

`deploy.sh` 会：渲染占位 → 建命名空间 → 建角色凭据 Secret（含跨 ns 复制）→
apply Cluster → 等 Ready → apply Database/RedisReplication/ScheduledBackup。

> 单实例时自动删除 `postgresql.synchronous` 段（同步复制无意义）。

## 五、应用侧对接

| 应用 | PG | Redis |
|---|---|---|
| Harbor | `database.type=external`（`harbor-values.yaml`） | `redis.type=external` |
| GitLab | `global.psql.*` + `postgresql.install=false` | `global.redis.*` + `redis.install=false` |
| Casdoor | `app.conf` datasource 指向 `platform-pg-rw` | 不用 |

## 六、GitOps 化

`Cluster` / `Database` / `RedisReplication` / `ScheduledBackup` 均可作为普通清单进
Flux。唯一环境差异是 `instances` / `synchronous` / `clusterSize`，建议在 GitOps 仓库用
Kustomize overlay（`overlays/drill`、`overlays/prod`）承载；密码用 Sealed-Secrets 或
External Secrets，避免明文。

## 七、已知取舍与风险

- **Redis 共享**：Harbor 用 DB 0/1/2/5 且偏 `noeviction`，GitLab 改 DB 3；共享策略折中为
  `maxmemory-policy noeviction`（GitLab cache 不驱逐，内存会增长）。生产可拆分为两个 Redis。
- **单 PG 爆炸半径**：共享实例故障影响全部应用。用 `instances≥3` + 同步复制 +
  `ScheduledBackup` + Longhorn 3 副本缓解。
- **GitLab 扩展**：`gitlab` 角色开 `superuser`，以便迁移时创建 `pg_trgm` / `btree_gist`。
  如需最小权限，改为预建扩展 + 普通角色。
- **跨 ns 凭据**：`managed.roles` 的 Secret 在 `platform-data`，应用 ns 不能直接引用。
  GitLab 以 Secret 消费 → `deploy.sh` 复制到 `gitlab` ns；Harbor/Casdoor 的密码由
  values/ConfigMap 直接注入，无需复制。
- **VolumeSnapshot**：备份依赖 `SNAPSHOT_CLASS` 对应的 CSI `VolumeSnapshotClass`；k3d 等无快照
  CRD 的环境改用 `barmanObjectStore`（对象存储，配置 `PG_BACKUP_BUCKET`/`S3_ENDPOINT` 后启用）。
- **异地容灾**：仅本地快照不够，生产必须启用 barman(OSS) + Longhorn backupTarget + Velero，
  见 `docs/application-data.md` 与 `docs/storage-plan.md`。
