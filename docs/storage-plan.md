# 存储规划（StorageClass / PV / 云盘）

> 目标：所有有状态工作负载使用**统一的规范 StorageClass `app-storage`**，
> 后端可随环境切换（drill=宿主 ZFS+iSCSI 云盘模拟 / prod=阿里云云盘 ESSD），应用清单零改动。
>
> drill 的云盘/计算分离与数据方案详见 [`cloud-disk-data-solution.md`](cloud-disk-data-solution.md)。
> Longhorn 已降为**可选后端**（`STORAGE_BACKEND=longhorn`）。

## 一、为什么需要它

早期版本把 `storageClass: longhorn` 硬编码在各清单里，导致：

- 无法切换到云盘（生产 ECS）；
- 副本数、回收策略、扩容能力没有显式契约，靠 chart 默认值，容易误删丢数据；
- 备份目标、快照类没有统一约定。

现在统一为「一个 SC 名称 + 环境后端 + 环境备份目标」。

## 二、契约

| 项 | drill（本机 KVM） | prod（阿里云 ECS） |
|---|---|---|
| `STORAGE_BACKEND` | `host-zfs-iscsi`（可选 `longhorn`）| `alicloud` |
| StorageClass 名 | `app-storage` | `app-storage` |
| Provisioner | `host-zfs-iscsi`（democratic-csi）| `diskplugin.csi.alibabacloud.com` |
| 介质 | 宿主 ZFS zvol（iSCSI）| ESSD 云盘 |
| 副本 | 块卷无存储级副本（靠应用 HA + 异地）| 云盘多副本；建议多 AZ |
| `reclaimPolicy` | `Retain` | `Retain` |
| `allowVolumeExpansion` | `true` | `true` |
| `volumeBindingMode` | `Immediate` | `WaitForFirstConsumer` |
| 快照类 `SNAPSHOT_CLASS` | `host-zfs-iscsi` | `alicloud-disk` |
| 异地备份目标 | 宿主 ZFS send/recv + MinIO(S3) | 阿里云 OSS |

> `app-storage` 在两种后端下**同名**，因此 Harbor/GitLab/PG/Redis/Crossplane
> 全部引用它即可，切换环境只改 `storage/apply.sh` 应用哪份 SC。

## 三、目录与用法

```
storage/
├── apply.sh                          # kubectl apply -k storage/<backend>（+ 备份凭据）
├── base/storageclass.yaml            # 契约公共字段（app-storage/Retain/扩容/默认类）
├── host-zfs-iscsi/                   # app-storage -> democratic-csi（drill 默认）
│   ├── kustomization.yaml + storageclass-patch.yaml
│   ├── volumesnapshotclass.yaml
│   └── values.yaml.tmpl / deploy-csi.sh / preload-images.sh
├── longhorn/                         # [可选后端] app-storage -> driver.longhorn.io
│   ├── kustomization.yaml + storageclass-patch.yaml
│   └── values-overlay.yaml
└── alicloud/                         # app-storage -> diskplugin.csi.alibabacloud.com
    └── kustomization.yaml + storageclass-patch.yaml
```

```bash
# drill（云盘模拟，默认）
make host-storage       # 宿主 ZFS 池 + iSCSI + MinIO
make csi-storage        # 安装 democratic-csi
make storage-class      # 应用 app-storage + VolumeSnapshotClass（Kustomize）
# 换驱动只改 STORAGE_BACKEND（契约不变）
make storage-longhorn && make storage-class STORAGE_BACKEND=longhorn
make storage-class STORAGE_BACKEND=alicloud
```

## 四、关键变量（`variables.mk`）

| 变量 | drill 默认 | prod 建议 | 说明 |
|---|---|---|---|
| `STORAGE_BACKEND` | `host-zfs-iscsi` | `alicloud` | 后端选择（可选 `longhorn`）|
| `STORAGE_CLASS` | `app-storage` | `app-storage` | 规范 SC 名 |
| `SNAPSHOT_CLASS` | `host-zfs-iscsi` | `alicloud-disk` | CNPG 快照类 |
| `ZFS_POOL` / `HOST_ZFS_VDEV` | `tank` / 文件 vdev | — | 宿主云盘池 |
| `ISCSI_TARGET_IQN` | `iqn.2026-01.com.baokuaiyun:k8s` | — | iSCSI target |
| `HOST_MINIO_ENDPOINT` | `http://192.168.124.1:9000` | OSS | 对象/备份出口 |
| `LONGHORN_REPLICAS` | `2` | `3` | [可选] Longhorn 副本 ≤ 可调度节点数 |
| `LONGHORN_ALLOW_CONTROL_PLANE` | `true` | `false` | [可选] drill 仅 2 节点时需上控制面 |
| `BACKUP_TARGET` | `nfs://<host>:/data/backups/longhorn` | OSS | [可选] Longhorn 异地目标 |

## 五、云盘方案为何是「与计算分离」

drill 用**宿主 ZFS + iSCSI**：块设备在宿主，VM 只做计算，删除/重建集群不影响宿主数据，
最贴近阿里云「云盘 + ECS」。Longhorn 是**集群内**存储，删除集群数据即丢，故降为可选后端。
详见 [`cloud-disk-data-solution.md`](cloud-disk-data-solution.md)。

> 若选用 `longhorn`（可选）：drill 起步为单节点，`LONGHORN_REPLICAS` 必须 ≤ 可调度节点数；
> 单节点时 Longhorn 副本只能为 1，故默认改用宿主云盘方案。

## 六、备份目标与三级保护

1. **数据盘**：宿主 ZFS zvol（云盘方案）/ Longhorn（可选）/ 云盘（prod）。
2. **本地快照**：ZFS snapshot（云盘方案）/ Longhorn `recurringJobs`（可选）。
3. **异地备份**：对象存储（宿主 MinIO / OSS）+ CNPG `barmanObjectStore` + Velero。

凭据：对象存储凭据放 `acr.env`（`MINIO_ROOT_*` / `S3_ACCESS_KEY` 等）。

## 七、验收

```bash
make verify-storage     # SC/快照类/副本/backupTarget/PVC/备份时效/云盘用量（命令逐条回显）
make auto-expand-once   # PV 自动扩容扫描（默认 dry-run 只报告）
make alerts             # 应用 PV/存储告警 + AlertmanagerConfig
```

> 逐项命令/期望/排障见 [`storage-verification.md`](storage-verification.md)。
> 自动扩容与告警参数见 [`parameters.md`](parameters.md)；`allowVolumeExpansion=true` 是自动扩容前提。

详见 `docs/application-data.md`（数据分级与 RPO/RTO）、`docs/data-classification.md`。
