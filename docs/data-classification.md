# 数据分级与备份策略

> 所有持久化数据按「可再生性」分级，级别决定备份方式、RPO/RTO 与保留期。

## 一、分级定义

| 级别 | 定义 | 处理要求 |
|---|---|---|
| **L0 集群状态** | 无此数据集群无法自举 | 异地快照 + 定期恢复演练 |
| **L1 不可再生** | 丢失不可恢复、业务中断 | 一致性备份 + 异地 + PITR，严格保留 |
| **L2 可重建** | 可通过重新采集/下载再生 | 可选备份，重点控制容量 |
| **L3 缓存** | 丢失仅影响性能/会话 | 不强制备份 |

## 二、逐项分级

| 数据 | 级别 | 存放 | 备份方式 | RPO | RTO | 保留 |
|---|---|---|---|---|---|---|
| etcd | L0 | CP 本地盘 | `scripts/backup-etcd.sh`（本地+异地） | 24h | 1h | 本地 7d / 异地 30d |
| platform-pg（registry/gitlabhq_production/casdoor） | L1 | PVC | CNPG 快照 + barman(OSS) PITR | ≤1h | 4h | 本地 7d / 异地 30d |
| Harbor registry 镜像 blob | L1 | PVC | Longhorn backupTarget / Velero + Harbor DB dump | 24h | 8h | 异地 30d |
| GitLab Gitaly Git 仓库 | L1 | PVC | `backup-utility` + PV 备份 | 24h | 8h | 30d |
| GitLab 对象存储(LFS/uploads/artifacts) | L1 | OSS/MinIO | 对象存储自身多副本 + 跨区复制 | 0（已冗余） | - | 30d |
| Casdoor 用户/组织/证书 | L1 | PG | 随 PG dump | ≤1h | 4h | 30d |
| Prometheus TSDB | L2 | PVC | 可选 | - | - | 15d（retention） |
| Loki 日志 | L2 | PVC | 可选 | - | - | 按容量 |
| Trivy 漏洞库 | L2 | PVC | 不备份（自动更新） | - | - | - |
| Redis（Harbor/GitLab） | L3 | PVC | 不备份 / 轻量 RDB | - | - | - |
| 清单/GitOps 配置 | L1 | Git | Git 天然冗余 | 0 | - | 永久 |
| cert-manager 私钥 | L1 | Secret | 随 etcd | 24h | 1h | 30d |

## 三、规则

- **L1 必须异地**：不能只有同集群内快照（集群整体故障=全丢）。
- **一致性优先**：Harbor/GitLab 需「DB + blob/仓库同一时点」，用应用原生工具（`harbor-backup`/`backup-utility`），
  其余资源交 Velero，即「两者结合」。
- **保留期分层**：本地 `BACKUP_RETENTION_DAYS`(7) / 异地 `OFFSITE_RETENTION_DAYS`(30)，
  按合规要求调整。
- **删除保护**：SC `reclaimPolicy: Retain` + CNPG `databaseReclaimPolicy: retain`，
  防误删联动删数据。

## 四、恢复演练

至少每季度执行一次，记录在案：

```bash
make app-restore APP=pg
make app-restore APP=harbor
make app-restore APP=gitlab
bash scripts/restore-etcd.sh <snapshot.db>
```

演练要求：能在**独立命名空间/临时集群**还原并验证数据完整性后再动生产。
