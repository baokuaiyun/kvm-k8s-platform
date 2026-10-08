# 云盘数据解决方案（宿主 ZFS + iSCSI，云盘/计算分离）

> 目标：在单机 KVM 上用**宿主 ZFS + iSCSI + democratic-csi** 模拟阿里云「云盘 + OSS」，
> 让**块存储与计算（VM）分离**、可快照、可在线扩容、可异地备份，并可平移到云盘 CSI。
>
> 关联：[`storage-plan.md`](storage-plan.md)、[`data-plane-management.md`](data-plane-management.md)、
> [`data-classification.md`](data-classification.md)、[`application-data.md`](application-data.md)、
> [`environment-differences.md`](environment-differences.md)、[`alicloud-deployment.md`](alicloud-deployment.md)。
>
> **drill 实测（已验收）**：`app-storage` 动态供给 PVC Bound；在线扩容 1→3Gi 数据无损；
> `VolumeSnapshot readyToUse=true`；`make verify-storage` 通过（`docs/implementation-status.md`）。

## 0. 定位

- **契约不变**：所有 PVC 引用 `STORAGE_CLASS=app-storage`，应用清单零改动。
- **后端可换**：drill=`host-zfs-iscsi`（本方案）；可选 `longhorn`；prod=`alicloud`（云盘 CSI）。
- **范围**：本文只设计**块/PV 层**；对象层（MinIO/OSS）作为备份出口，另有章节。

## 1. 分层与职责边界

| 层 | 介质 | 作用 | 谁管 |
|---|---|---|---|
| 计算 | VM 系统盘（qcow2）| 只管运行 | 集群 |
| **块/云盘** | 宿主 ZFS zvol → iSCSI → CSI | PG/Redis/Gitaly/registry/TSDB 落盘 | 平台（数据面）|
| 对象 | MinIO(docker)/OSS | barman WAL/PITR、Velero、GitLab 附件 | 平台（数据面）|

> 铁律：**云盘是块设备（单挂载、非共享、不做异地备份出口）**；异地一律写 S3（见 `data-plane-management.md` §八）。

## 2. 组件与数据流

```
宿主
├── ZFS pool(${ZFS_POOL}) ── dataset ${ZFS_POOL}/k8s ── zvol
│        └── iSCSI target(LIO)  portal ${NET_GATEWAY}:3260  IQN ${ISCSI_TARGET_IQN}
└── MinIO(docker)  :${HOST_MINIO_PORT}  对象/备份出口
        │  (iSCSI / S3)
集群
├── democratic-csi（controller 经 SSH 管理宿主 target；node 插件 iscsiadm 挂载）
├── StorageClass app-storage（provisioner=host-zfs-iscsi, allowVolumeExpansion=true, Retain）
└── VolumeSnapshotClass host-zfs-iscsi（ZFS 快照）
```

KVM 与阿里云对应：

| 阿里云 | 本方案 |
|---|---|
| ECS 系统盘 | VM qcow2 系统盘 |
| ESSD 云盘 | 宿主 ZFS zvol |
| 云盘 CSI | democratic-csi（host-zfs-iscsi）|
| 云盘快照 | ZFS snapshot / CSI VolumeSnapshot |
| 云盘加密 | ZFS native encryption（`ZFS_ENCRYPTION`）|
| 云盘扩容 | `zfs set volsize` + `resize2fs`（在线）|
| OSS | 宿主 MinIO |
| 跨 AZ | ❌ 单宿主无法模拟（靠副本/异地备份近似）|

## 3. ZFS 池与命名规范

> **前置**：宿主必须能加载 `zfs` 内核模块（`modprobe zfs`）。若当前内核无匹配
> `linux-headers`（如 6.12.95 无对应包），DKMS 无法构建模块，`make host-storage` 会**快速失败并给出提示**；
> 解决：安装匹配内核 headers（`apt-get install linux-headers-$(uname -r) && dkms autoinstall`）或
> 换用带 headers 的内核后重启；仅部署 MinIO/iSCSI 基础可设 `SKIP_ZFS=1`（不建池）。
> 另：宿主 docker 若受代理限制，`MINIO_IMAGE`/`MINIO_MC_IMAGE` 可换国内镜像或预加载。

- **池拓扑**：drill 默认文件 vdev（`HOST_ZFS_USE_FILE=1`，`/data/zfs-pool.img`），不碰 `/data` 文件系统；
  生产 `HOST_ZFS_USE_FILE=0` + 裸盘/mirror/raidz2（`HOST_ZFS_VDEV`）。
- **zvol 命名**：`${ZFS_POOL}/k8s/<pvc>`（由 democratic-csi 按 `datasetParentName` 生成）。
- **参数**：`compression=zstd`、`atime=off`、`xattr=sa`、zvol `volblocksize=16K`、`refreservation=0`（thin）。
- **数据集**：`${ZFS_POOL}/k8s`（zvol 父目录）、`${ZFS_POOL}/k8s/snapshots`（detached 快照）。
- **iSCSI**：target `${ISCSI_TARGET_IQN}`，portal `${NET_GATEWAY}:3260`，`namePrefix=csi-`。

## 4. 供给生命周期

1. PVC 创建 → democratic-csi controller 经 SSH 在宿主 `zfs create -V`，建 LUN，挂到 target。
2. Pod 调度 → node 插件 `iscsiadm` 登录 portal → 格式化/挂载 → 容器。
3. Pod 迁移（节点故障）→ node 插件 detach → 新节点重新 login/attach（块设备可从任意节点经 portal 访问）。
4. `reclaimPolicy: Retain` → 删 PVC 时 PV 保留。
5. **孤儿卷回收 SOP**：核对 PV 名与宿主 `zfs list`，确认无引用后再 `zfs destroy`。

## 5. 在线扩容（手工 + 自动）

- SC `allowVolumeExpansion: true`；流程：改 PVC size → CSI `ControllerExpandVolume` → `zfs set volsize` → node `resize2fs`。
- **只能扩不能缩**（ZFS zvol 不可缩小）→ 按需扩 + 上限约束。
- 演练：`make drill-expand-pvc`（建 1Gi→写数→扩 3Gi→校验无损）。
- **自动扩容控制器**（`scripts/auto-expand-pvc.sh` + `make auto-expand`）：
  - 周期扫描（默认 5m），读 Prometheus `kubelet_volume_stats_*`，对用量 > `PV_AUTOSCALER_THRESHOLD`（默认 80%）的 Bound PVC
    按 `max(×FACTOR, +MIN_STEP)` 计算目标并 `patch spec.resources.requests.storage`，由 CSI 完成在线扩容。
  - **默认 `PV_AUTOSCALER_DRY_RUN=1`**：只写 `auto-expand/recommendation` 注解并打印，不实际改动。
  - 安全：只增不减、`PV_AUTOSCALER_MAX_SIZE` 封顶、`auto-expand/max-size` 逐卷上限、
    `auto-expand/disabled=true` 排除、冷却 `PV_AUTOSCALER_COOLDOWN_MIN`、`concurrencyPolicy: Forbid`。
  - 运行：`make auto-expand`（部署 CronJob）；`make auto-expand-once DRY_RUN=0`（本机实扩一次）。
  - 注意：控制器会改 PVC `requests`，Helm/Git 管理的 PVC 需忽略该字段以免 GitOps 漂移；
    ext4 在 `FileSystemResizePending` 时可能需重启 Pod 才完成 fs 扩容，默认不自动重启，交由告警。

## 6. 快照

- ZFS 快照（瞬时、CoW），经 CSI `VolumeSnapshot` 暴露；`VolumeSnapshotClass=host-zfs-iscsi`。
- **数据库不裸快照**：CNPG 负责 checkpoint/quiesce 后再打 `volumeSnapshot`；文件型按需 fsfreeze。

## 7. 备份与异地（对齐数据分级）

| 级别 | 数据 | 本地 | 异地 |
|---|---|---|---|
| L0 | etcd | `backup-etcd.sh` | 异地目录 |
| L1 | platform-pg | ZFS 快照 + `ScheduledBackup(volumeSnapshot)` | barman→S3 宿主 MinIO（PITR）|
| L1 | Harbor registry blob | ZFS 快照 | Velero / ZFS send |
| L1 | Gitaly 仓库 | ZFS 快照 | GitLab `backup-utility`→对象 |
| L1 | GitLab 对象 | 对象多副本 | 宿主 MinIO |
| L2 | Prometheus/Loki | 快照（可选）| 可选 |
| L3 | Redis | 不备份 | — |

- 异地机制：`zfs send/recv`（增量，`HOST_ZFS_SEND_TARGET`）+ 对象存储（宿主 MinIO）。
- 备份矩阵：CNPG 02:00；GitLab 01:00；Velero 03:00；etcd 02:00（宿主 cron）。

## 8. 恢复与灾备

- 单卷：`zfs rollback` / `zfs clone` 再重建 PVC。
- 应用：CNPG PITR、Harbor dump+PV、GitLab `backup-utility`（`platform/backup/restore.sh`）。
- **删集群/重建时**：`make reset-cluster`（或 `make rebuild`）**只删 VM，宿主 ZFS zvol 与 MinIO 保留**；
  但 k8s 的 PV/PVC 随集群 etcd 一起消失，CSI 卷名默认含 PVC UID，**不能自动重挂**。
  因此实际复原路径是**从备份恢复**：重建集群后，
  1) `make rebuild` 拉起平台；2) 用 CNPG barman(PITR) / Velero / GitLab `backup-utility` 还原应用数据到新 PVC；
  3) 用 `bash scripts/list-orphan-volumes.sh` 列出宿主上残留的旧 zvol，人工核对后 `zfs destroy` 回收。
- 季度演练（`data-classification.md` §四）。

## 9. 安全

- 静态加密：`ZFS_ENCRYPTION=on` + `ZFS_ENCRYPTION_KEYFILE`（生产接 KMS）；drill 默认 off。
- 传输：iSCSI 走管理网隔离；生产可开双向 CHAP（`iscsi.chap`）。
- 访问：CSI 经 SSH 密钥（`HOST_CSI_SSH_KEY`）；凭据用 Sealed/External-Secrets。
- 多租户：zvol + 配额隔离；按需 per-tenant 加密。

## 10. 可观测与告警

- 宿主：`zpool status`、容量、scrub 时效；MinIO 桶用量。
- 集群：CSIDriver/Pod/PVC/snapshot 状态（`scripts/verify-storage.sh`）。
- 备份时效告警（`data-plane-management.md` §九）。
- **PV/PVC 告警**（`observability/alerts.yaml`）：`PVCNearlyFull(>85%)`、`PVCCriticalFull(>95%)`、
  `PVCPredictFull`（24h 内写满预测）、`PVCInodesNearlyFull`、`PVCResizeStuck`（扩容未生效）、`PersistentVolumeFailed`。
- **通知路由**：`make alerts` 渲染 `AlertmanagerConfig`（Webhook/邮件，参数见 `docs/parameters.md`）；
  `make monitoring` 已开启 `alertmanagerConfigSelector`，否则 CR 不被 Alertmanager 选中。

## 11. 多节点与 scale-out

- 每节点装 `open-iscsi`（`install-common.sh` 已装）；卷经 portal 从任意节点访问。
- 节点故障 → Pod 漂移 → 卷 detach/attach。
- **块卷无存储级副本**：副本靠应用层（CNPG `PG_INSTANCES≥3`）+ 异地备份；LINSTOR/Ceph 为备选（本方案不选）。

## 12. 迁移路径（Longhorn → host-zfs-iscsi）

1. 执行 `make host-storage` 与 `make csi-storage`（不动现网）。
2. 新 PVC 走 `app-storage`（已指向新后端）。
3. 存量数据用 Velero/应用原生迁移。
4. 验证后下线 Longhorn。回滚：保留 Longhorn 数据至观察期结束。

## 13. 与阿里云的平移

| 项 | drill | 阿里云 |
|---|---|---|
| 供给 | democratic-csi | `diskplugin.csi.alibabacloud.com` |
| 介质 | ZFS zvol | ESSD |
| 快照 | ZFS/CSI | 云盘快照 |
| 加密 | ZFS native | 云盘加密 |
| 扩容 | zvol resize | 云盘扩容 |
| 跨 AZ | ❌ | ✅ |

## 14. 命令速查

```bash
make host-storage        # 宿主 ZFS 池 + iSCSI + MinIO（幂等）
make csi-storage         # 安装 democratic-csi
make storage-class       # 应用 app-storage + VolumeSnapshotClass
make drill-expand-pvc    # 在线扩容演练
make auto-expand         # 部署 PV 自动扩容控制器（默认 dry-run）
make auto-expand-once DRY_RUN=0   # 本机实扩一次
make alerts              # 应用告警规则 + 渲染 AlertmanagerConfig
make verify-storage      # 存储验收（命令逐条回显，教程见 storage-verification.md）

# 删除 → 重建（保留宿主存储）
make reset-cluster       # 只删 VM，保留 ZFS/MinIO/缓存
make rebuild             # = reset-cluster + phase1 + mgmt-bootstrap
bash scripts/list-orphan-volumes.sh   # 核对宿主残留卷
```

宿主核对：
```bash
zpool status ${ZFS_POOL}; zfs list -r ${ZFS_POOL}
targetcli /iscsi ls; ss -lntp | grep 3260
docker ps --filter name=host-minio
```

## 15. 已知局限

- 单宿主单点，非真 HA（与云盘可用性差距本地无法消除）。
- ZFS 卷不可缩容；thin provisioning 需监控，防超卖。
- iSCSI 依赖网络与 initiator 稳定性；生产建议 multipath。
- democratic-csi 依赖对宿主的 SSH（密钥 `HOST_CSI_SSH_KEY`），需妥善保管。
