# 应用数据说明与规划

> 本文回答四个问题：**各应用持有什么数据？放在哪？怎么保？怎么恢复？**
> 分级与 RPO/RTO 见 `docs/data-classification.md`；存储契约见 `docs/storage-plan.md`。

## 一、总览

```
共享数据层 platform-data
├── platform-pg (CNPG)   registry / gitlabhq_production / casdoor
└── platform-redis       Harbor job 队列 + GitLab cache + 会话

应用
├── Harbor   镜像 blob(harbor-registry PVC) + jobservice + trivy + PG(registry)
├── GitLab   Gitaly 仓库(PVC) + 对象存储 LFS/uploads/artifacts + PG(gitlabhq_production)
├── Casdoor  用户/组织/证书 (PG casdoor)
└── 可观测   Prometheus TSDB + Loki 日志
```

## 二、逐应用说明

### 1. platform-pg（PostgreSQL / CNPG）

- **数据**：`registry`(Harbor 元数据)、`gitlabhq_production`(GitLab 元数据)、`casdoor`(用户/证书)。
- **位置**：`Cluster/platform-pg`，PVC `__PG_STORAGE_SIZE__`（默认 20Gi），SC `app-storage`。
- **备份**：
  - 本地：`ScheduledBackup`（每日 02:00，`volumeSnapshot`，`SNAPSHOT_CLASS`）。
  - 异地：`barmanObjectStore` 指向 OSS（`PG_BACKUP_BUCKET`/`S3_ENDPOINT`），支持 PITR。
  - 未配置对象存储时自动跳过 barman（drill 默认）。
- **恢复**：基于对象存储 PITR（`bootstrap.recovery`）或从快照克隆新 Cluster。
- **配置**：`PG_INSTANCES` / `PG_SYNC_REPLICAS`（prod ≥3/1）、`PG_STORAGE_SIZE`。

### 2. platform-redis

- **数据**：Harbor job 队列（DB0/1/2/5）、GitLab cache（DB3）、会话。
- **位置**：StatefulSet `platform-redis`，PVC `__REDIS_STORAGE_SIZE__`（默认 5Gi）。
- **分级 L3**：允许丢失，不强制备份；`maxmemory-policy noeviction`（见 `docs/platform-data.md`）。
- **注意**：共享实例内存会增长，生产建议拆分或改用 RedisReplication。

### 3. Harbor

- **数据**：
  | 数据 | 位置 | 级别 |
  |---|---|---|
  | 镜像 blob | PVC `harbor-registry`（`HARBOR_REGISTRY_SIZE`，默认 50Gi） | L1 |
  | jobservice 日志 | PVC `harbor-jobservice`（5Gi） | L2 |
  | Trivy 漏洞库 | PVC `harbor-trivy`（10Gi） | L2 |
  | 项目/用户/标签等元数据 | PG `registry` | L1 |
- **备份**（两者结合）：
  1. 元数据：`platform/backup/backup.sh harbor` → `pg_dump registry`。
  2. 镜像 blob：Longhorn `backupTarget` 或 Velero（PV 级）**异地**。
- **恢复**：先停写 → 还原 `registry` dump → 还原 registry PVC → 恢复副本。见 `restore.sh harbor`。
- **配置**：`HARBOR_REGISTRY_SIZE` / `HARBOR_JOBSERVICE_SIZE` / `HARBOR_TRIVY_SIZE`。

### 4. GitLab

- **数据**：
  | 数据 | 位置 | 级别 |
  |---|---|---|
  | Git 仓库 | Gitaly PVC（`GITALY_SIZE`，默认 50Gi） | L1 |
  | LFS / uploads / artifacts / packages / CI 日志 | 对象存储（OSS 或独立 MinIO） | L1 |
  | 用户/项目/issue/MR 等元数据 | PG `gitlabhq_production` | L1 |
  | Registry | 已关闭（`registry.enabled=false`） | - |
- **对象存储选型**（`GITLAB_OBJECT_STORE`）：
  - `oss`（生产）：阿里云 OSS，关闭内置 MinIO，凭据 Secret `gitlab-object-storage`
    （由 `platform/gitlab/objectstore-secret.sh` 生成）。
  - `minio`（drill）：集群内独立 MinIO，PVC `GITLAB_OBJECT_SIZE`。
- **备份**：`backup-utility`（toolbox）做 PG + Gitaly + 对象存储一致性备份，
  产物按 `gitlab.toolbox.backups.objectStorage` 落对象存储；每日 01:00 由 chart cron 触发。
- **恢复**：`backup-utility --restore -t <timestamp>`。见 `restore.sh gitlab`。
- **配置**：`GITALY_SIZE` / `GITLAB_OBJECT_SIZE` / `GITLAB_OBJECT_STORE` / `GITLAB_OSS_BUCKET`。

### 5. Casdoor

- **数据**：用户、组织、应用、证书、provider 配置 —— 全部在 PG `casdoor`。
- **位置**：无独立 PVC；`app.conf` 指向 `platform-pg-rw`。
- **备份**：随 PG（`backup.sh casdoor` 额外 `pg_dump`）。
- **恢复**：还原 `casdoor` 库即可。见 `restore.sh casdoor`。
- **注意**：生产请固定 `CASDOOR_VERSION`，避免 `latest` 跨版本改表。

### 6. 可观测性

- **数据**：Prometheus TSDB（`PROMETHEUS_SIZE`，默认 20Gi，retention `PROMETHEUS_RETENTION`）、
  Loki 日志（`LOKI_SIZE`，默认 20Gi）、Grafana（`GRAFANA_SIZE`，默认 5Gi）。
- **级别 L2**：可重建；已配置持久化（此前为 emptyDir，重启即丢）与容量告警。

## 三、备份编排与命令

```bash
make app-backup              # CNPG Backup + Harbor dump + GitLab backup + Casdoor dump
make app-backup APP=gitlab   # 也可: bash platform/backup/backup.sh gitlab
make app-restore APP=harbor  # 打印/执行恢复 runbook
make verify-storage          # 校验 SC/副本/backupTarget/备份时效
```

备份矩阵（时间）：CNPG 每日 02:00；GitLab 每日 01:00；Longhorn 快照 01:00 / 异地 02:00；
Velero 每日 03:00；etcd 每日 02:00（宿主 cron）。

## 四、待办 / 依赖

- [ ] 生产创建 OSS bucket：PG barman、Velero、GitLab 对象存储、Longhorn backupTarget。
- [ ] drill 在宿主机搭 NFS 导出 `/data/backups/longhorn` 并挂载为 `BACKUP_TARGET`。
- [ ] Velero 需一个 S3 兼容端点（drill 用 NFS 上的 MinIO，prod 用 OSS）。
- [ ] 按 `docs/secret-management.md` 将明文凭据迁移到 Sealed-Secrets/External-Secrets。
