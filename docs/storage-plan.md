# 存储规划（StorageClass / PV / 云盘）

> 目标：所有有状态工作负载使用**统一的规范 StorageClass `app-storage`**，
> 后端可随环境切换（drill=Longhorn / prod=阿里云云盘 ESSD），应用清单零改动。

## 一、为什么需要它

早期版本把 `storageClass: longhorn` 硬编码在各清单里，导致：

- 无法切换到云盘（生产 ECS）；
- 副本数、回收策略、扩容能力没有显式契约，靠 chart 默认值，容易误删丢数据；
- 备份目标、快照类没有统一约定。

现在统一为「一个 SC 名称 + 环境后端 + 环境备份目标」。

## 二、契约

| 项 | drill（本机 KVM） | prod（阿里云 ECS） |
|---|---|---|
| `STORAGE_BACKEND` | `longhorn` | `alicloud` |
| StorageClass 名 | `app-storage` | `app-storage` |
| Provisioner | `driver.longhorn.io` | `diskplugin.csi.alibabacloud.com` |
| 副本 | 2（`LONGHORN_REPLICAS`） | 由云盘保障；建议多 AZ |
| `reclaimPolicy` | `Retain` | `Retain` |
| `allowVolumeExpansion` | `true` | `true` |
| `volumeBindingMode` | `Immediate` | `WaitForFirstConsumer` |
| 快照类 `SNAPSHOT_CLASS` | `longhorn` | `alicloud-disk` |
| 异地备份目标 | 宿主机 NFS 目录 | 阿里云 OSS |

> `app-storage` 在两种后端下**同名**，因此 Harbor/GitLab/PG/Redis/Crossplane
> 全部引用它即可，切换环境只改 `storage/apply.sh` 应用哪份 SC。

## 三、目录与用法

```
storage/
├── apply.sh                    # 渲染并 apply SC + 备份凭据
├── longhorn/storageclass.yaml  # app-storage -> driver.longhorn.io
├── longhorn/values-overlay.yaml# Longhorn 生产化（副本/backupTarget/控制面调度/定期快照）
└── alicloud/storageclass.yaml  # app-storage -> diskplugin.csi.alibabacloud.com
```

```bash
# drill
make storage            # 安装 Longhorn（自动叠加 values-overlay）
make storage-class      # 应用 app-storage
# 生产切云盘（需先装阿里云云盘 CSI）
make storage-class STORAGE_BACKEND=alicloud
```

## 四、关键变量（`variables.mk`）

| 变量 | drill 默认 | prod 建议 | 说明 |
|---|---|---|---|
| `STORAGE_BACKEND` | `longhorn` | `alicloud` | 后端选择 |
| `STORAGE_CLASS` | `app-storage` | `app-storage` | 规范 SC 名 |
| `SNAPSHOT_CLASS` | `longhorn` | `alicloud-disk` | CNPG 快照类 |
| `LONGHORN_REPLICAS` | `2` | `3` | **必须 ≤ 可调度节点数** |
| `LONGHORN_ALLOW_CONTROL_PLANE` | `true` | `false` | drill 仅 2 节点，2 副本需上控制面 |
| `BACKUP_TARGET` | `nfs://<host>:/data/backups/longhorn` | `s3://<bucket>@oss-<region>.aliyuncs.com/` | Longhorn 异地目标 |

## 五、为何 drill 必须允许控制面参与存储

drill 起步为 **1 CP + 1 W = 2 节点**。Longhorn 只在**可调度节点**上放置副本，
控制面默认带 `NoSchedule` 污点，若不放开，可调度节点只有 1 个，副本会被压到 1，
**2 副本目标落空**。因此 overlay 打开 `allowSchedulingOnControlPlane: true`。
生产 ≥3 存储节点时应关掉（`LONGHORN_ALLOW_CONTROL_PLANE=false`）并保持副本 3。

## 六、备份目标与三级保护

1. **PVC 副本**：Longhorn 2/3 副本 / 云盘多副本（抗单点故障）。
2. **本地快照**：Longhorn `recurringJobs.daily-snapshot`（快速回滚）。
3. **异地备份**：`backupTarget`（NFS/OSS）+ CNPG `barmanObjectStore` + Velero。

凭据：S3/OSS 用 `storage/apply.sh` 创建 `longhorn-system/longhorn-backup-cred`；
`LONGHORN_ACCESS_KEY/SECRET_KEY` 放 `acr.env`。

## 七、验收

```bash
make verify-storage     # SC/快照类/副本/backupTarget/PVC/备份时效
```

详见 `docs/application-data.md`（数据分级与 RPO/RTO）、`docs/data-classification.md`。
