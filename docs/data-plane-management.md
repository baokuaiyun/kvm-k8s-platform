# 数据平面管理分册（独立数据集群 B，云无关）

> 定位：数据平面是四平面之一，可**独立部署为一个专用 Kubernetes 集群（形态 B）**，
> 与工具链/业务集群**生命周期完全解耦**。数据平面**云无关**：任何 K8s + 任何 CSI + 任何 S3 都可承载，
> 云能力只是可替换的适配器。
>
> 关联：[`implementation-matrix.md`](implementation-matrix.md)、[`plane-dod.md`](plane-dod.md)、
> [`platform-data.md`](platform-data.md)、[`data-classification.md`](data-classification.md)、[`storage-plan.md`](storage-plan.md)。

## 一、承载形态与为什么选 B

| 形态 | 谁承载 | 自建集群 | 适用 |
|---|---|---|---|
| A 托管云 | 云厂商 RDS/Redis/OSS/KMS | 否 | 允许公有云、省运维 |
| **B 独立数据集群** | **一套专用 K8s（CNPG/Redis/对象存储）** | **是** | **私有化/信创/多集群/统一治理（生产首选）** |
| C 共享集群专用节点池 | 业务集群内 DB 专用节点 | 否 | 中小规模 |
| D 同集群同池 | 业务集群普通节点 | 否 | 仅演练 |

**B 的价值**：数据"宠物"与计算"牲畜"生命周期隔离；一处治理、多集群消费；云无关、可迁移。

## 二、管理总览（谁管什么）

| 维度 | 平台（数据面 owner） | 租户/应用 |
|---|---|---|
| 引擎与实例 | 部署/升级/扩缩/故障切换 | 不接触 |
| 备份/DR/恢复 | 策略、执行、演练 | 提出 RPO/RTO |
| 连接与凭据 | 端点、TLS、账号下发/轮换 | 消费 secret |
| Schema/数据 | 不干预（除迁移工具） | 建表/迁移/优化 |
| 合规审计 | 审计日志、加密、基线 | 使用 |

**控制循环**：全部 **Operator + GitOps** 驱动，人只改 Git，不 `kubectl edit` 数据资源。

## 三、编排与供给（Provisioning）

- **运行组件**（部署在 `data` 集群）：CloudNativePG Operator、Redis 方案（见下）、对象存储（MinIO Operator 或外部 S3）、备份组件（barman 由 CNPG 内置）。
- **供给抽象**：Crossplane `DatabaseClaim` / `RedisClaim`（金标 profile S/M/L），租户只选 profile，平台决定落到 A/B/C/D。
- **自助路径**：Backstage 模板 → Crossplane Composite → CNPG/云 RDS（带审批与配额）。
- **命名/账号规范**：`<app>` 库 + `<app>` 角色 + `*-cred` Secret（跨 ns 复制）；扩展（`pg_trgm`/`btree_gist`）在 profile 预声明。

## 四、金标 Profile

| Profile | 引擎 | 隔离 | HA | 备份 | 用途 |
|---|---|---|---|---|---|
| `db-s` | 共享 CNPG 实例 | 独立库/角色 | 单实例 | 快照 + pg_dump | 小客户/内部 |
| `db-m` | 专用 CNPG 集群 | 独占 | 3 实例 + 同步复制 | PITR(barman→S3) | 生产默认 |
| `db-l` | 专用数据集群 / 托管实例 | 独占 | 多 AZ | 跨区 PITR + 审计 | 合规/第三方 |

## 五、生命周期管理

```
create → configure/extensions → scale(读副本/存储) → upgrade → backup/PITR → decommission
```

- **PG**：CNPG 负责主从/切换/滚动升级；小版本=改 `imageName` 滚动；大版本=逻辑复制或 `pg_upgrade`（演练）。
- **Redis**：当前 `redis-operator v0.17.0` 对 `RedisReplication` 有 panic bug，drill 用普通 StatefulSet（`platform/platform-data/redis.yaml`）；**M/L 档需定夺**：升级/更换 operator，或改用 Bitnami Redis（哨兵/集群），并纳入 GitOps。
- **对象存储**：drill=MinIO；prod=任意 S3（OSS/自建），生命周期/跨区由存储侧策略管。
- **变更治理**：库结构变更走租户迁移工具（Flyway / rails migrate），平台不手工 DDL。

## 六、接入与凭据

- 端点：`platform-pg-rw.<ns>.svc` / `platform-redis.<ns>.svc`（集群内）；跨集群见 §七。
- 凭据：**External-Secrets + KMS**（生产）/ Sealed-Secrets（过渡）；定期轮换；应用经 Secret 注入，不硬编码。
- 连接弹性：M/L 档加 **PgBouncer Pooler**（CNPG `Pooler`）控制连接数。

## 七、跨集群消费（核心）

**分层：网络底座 + 服务暴露 + 安全**
1. **网络底座**：VPC Peering / PrivateLink（云，可选）；自建则同网段/专线。
2. **服务暴露（首选）**：**Cilium ClusterMesh**（复用现有 Cilium）→ **global Service** 提供跨集群稳定端点。
3. **强隔离降级**：数据集群**内部 LB（云 LB / kube-vip LB）+ 私有 DNS + mTLS + 源 CIDR 白名单**，**不打通 Pod 网**。
4. **安全**：CNPG 自带 mTLS；Cilium NetworkPolicy 仅放行消费集群；`pgAudit` 审计。

> 消费集群只认「**端点 + 凭据 + S3**」三样，永不接触云 API。

## 八、备份与災備（备份出口 = 对象存储，不是云盘）

**三层存储，勿混淆：**

| 层 | 介质 | 作用 |
|---|---|---|
| 数据盘(at-rest) | 云盘 ESSD / PVC(Longhorn) | PG/Redis 数据落盘 |
| 本地快照 | 云盘快照 / Longhorn snapshot | 快速回滚 |
| **异地备份出口** | **对象存储 S3（MinIO/OSS/任意 S3）或异地 NFS** | barman WAL/PITR、Velero、Longhorn backupTarget |

- 云盘是块设备（单挂载、非共享、不跨区）→ **不适合做异地备份出口**。
- 数据集群在云上时：PG 数据落 ESSD 可以，但 **WAL/PITR 与备份必须写到 S3**。
- 接口：`Cluster.spec.backup.barmanObjectStore`（destinationPath/endpointURL/s3Credentials）+ `ScheduledBackup`。
- 策略：L0/L1 异地 + 季度恢复演练；时效纳入告警。

## 九、可观测（数据面专属）

- CNPG 内置 exporter（PodMonitor→Prometheus）；Redis 用 `redis_exporter`。
- 关键告警：复制延迟、连接数、磁盘/存储、**备份时效**、failover 事件、慢查询。

## 十、安全与合规

- in-transit TLS（CNPG 内置证书）、静态加密（云盘/OSS 加密）、最小权限角色、`pgAudit`、密钥经 KMS。
- 数据资源也受 NetworkPolicy/Quota/PDB 约束；审计日志集中采集。

## 十一、容量与成本

- 存储自动扩容（`allowVolumeExpansion`）、按 profile 设 requests/limits、按租户出账（容量/连接数）。
- 备份保留期分层（本地 7d / 异地 30d，见 data-classification）。

## 十二、RACI

| 事项 | 平台(数据面) | 租户 | 工具链面 |
|---|---|---|---|
| 引擎/升级/切换 | A/R | I | I |
| 备份/恢复 | A/R | C(RPO/RTO) | C |
| 账号/凭据下发 | A/R | C | I |
| Schema/迁移 | C | A/R | I |
| 观测/告警 | A/R | I | C(集中) |

## 十三、现状 → 目标（迁移路径）

| 项 | 现状(drill, D) | 目标(B) |
|---|---|---|
| 承载 | 与工具链同集群 | 独立 `data` 集群 |
| PG | CNPG 单实例 | `db-m`（3 实例 + 同步复制） |
| Redis | StatefulSet 单副本 | 哨兵/集群，纳入 GitOps |
| 备份出口 | 无（仅 pg_dump） | S3(barman PITR) + 快照 + Velero |
| 供给 | 手工 CR | Crossplane Claim + 金标 profile |
| 消费 | 同集群 Service | ClusterMesh global Service / LB+DNS |

**迁移建议顺序**：先补备份/PITR 接口 → 引入 Crossplane 供给抽象 → 拆出独立 `data` 集群并接入 ClusterMesh → 业务集群改为消费外部端点。
