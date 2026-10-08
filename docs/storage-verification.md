# 存储验证（Storage Verification）

> 目标：把 [`storage-plan.md`](storage-plan.md) 的存储契约、[`cloud-disk-data-solution.md`](cloud-disk-data-solution.md) 的云盘/计算分离方案，变成**可执行、可复现、可入库**的核对。
> 风格与 `make verify-network` 一致：**退出码即结论**；**主要命令逐条回显**，方便讲学与证据留痕。
> 关联 [`storage-plan.md`](storage-plan.md)、[`cloud-disk-data-solution.md`](cloud-disk-data-solution.md)、[`evidence-and-acceptance.md`](evidence-and-acceptance.md)、[`parameters.md`](parameters.md)。

## 一、一键验证

```bash
make verify-storage                       # 全部 6 项（ENV=drill）
make verify-storage STORAGE_BACKEND=longhorn   # 切后端分支
KUBECTL_VERIFY_ECHO=0 make verify-storage      # 静默模式（不回显命令，只留结论）
```

- 退出码：`0`=通过（可含 WARN），`1`=存在 FAIL，`2`=前置缺失（无 kubectl / 集群不可达）。
- 默认**逐条回显**实际执行的 `kubectl`/`velero` 命令（`  $ ...` 前缀），便于讲学讲解每一步依据。
- 已纳入 `make verify`（全量验收）与 `make evidence`（证据包，check 名 `storage_verify`）。

## 二、检查分区（6 项）

| # | 分区 | 关键检查 | 关联命令 |
|---|---|---|---|
| 1 | StorageClass | 存在性、`provisioner`、`reclaimPolicy=Retain`、`allowVolumeExpansion`、默认 SC | `kubectl get sc` |
| 2 | 快照类 | `VolumeSnapshotClass` 是否存在（CNPG 快照备份前提） | `kubectl get volumesnapshotclass` |
| 3 | 存储后端 | `CSIDriver` / `democratic-csi` Pod / driver Secret；或 Longhorn DS / backupTarget | `kubectl get csidriver`、`kubectl -n democratic-csi get pods` |
| 4 | PVC 状态 | 全部 PVC 是否 `Bound` | `kubectl get pvc -A` |
| 5 | 备份时效 | CNPG `Backup` 完成项、Velero 备份列表 | `kubectl get backup -A`、`velero backup get` |
| 6 | 云盘使用情况 | PVC 申请/容量、实际使用率（Prometheus）、宿主 ZFS 池/卷用量 | `kubectl get pvc -A`、`zpool list`、`zfs list` |

## 三、逐项：命令 / 期望 / 排障

### 1. StorageClass（`app-storage`）

```bash
kubectl get sc app-storage -o wide
kubectl get sc app-storage -o jsonpath='{.provisioner}{" "}{.reclaimPolicy}{" "}{.allowVolumeExpansion}'
kubectl get sc     # 看默认类注解 storageclass.kubernetes.io/is-default-class
```

- **期望**：`app-storage` 存在；`reclaimPolicy=Retain`；`allowVolumeExpansion=true`。
- **排障**：不存在 → `make storage-class`；reclaim 非 Retain → 改 `storage/` 模板后重放；不允许扩容 → 自动扩容（`make auto-expand`）前提不满足。

### 2. 快照类（`SNAPSHOT_CLASS`）

```bash
kubectl get volumesnapshotclass host-zfs-iscsi
```

- **期望**：`host-zfs-iscsi`（drill）存在，CNPG `volumeSnapshot` 备份可用。
- **排障**：不存在 → `make storage-class`（同时应用 SC 与快照类）。

### 3. 存储后端（drill=`host-zfs-iscsi`）

**3a. democratic-csi（drill 默认）**

```bash
kubectl get csidriver host-zfs-iscsi
kubectl -n democratic-csi get pods -l app.kubernetes.io/name=democratic-csi
kubectl -n democratic-csi get secret democratic-csi-driver-config
```

- **期望**：`CSIDriver` 存在、`democratic-csi` Pod Running、driver Secret 存在。
- **排障**：`CSIDriver` 缺失 → `make csi-storage`；Pod 非 Running → `kubectl -n democratic-csi describe pod ...`（多为 SSH 到宿主/凭据/portal 问题）。
- **宿主侧**（CSI 通过 SSH 操纵宿主 ZFS/iSCSI，集群内看不到）：见第六节。

**3b. Longhorn（可选后端）**

```bash
kubectl -n longhorn-system get ds longhorn-manager
kubectl -n longhorn-system get setting backup-target -o jsonpath='{.value}'
kubectl -n longhorn-system get setting default-replica-count -o jsonpath='{.value}'
```

- **期望**：`longhorn-manager` DS 全 ready；`backup-target` 已配置（否则无异地备份）。
- **排障**：未安装 → `make storage-longhorn`；backupTarget 空 → 配宿主 MinIO/OSS 并写 setting。

### 4. PVC 状态

```bash
kubectl get pvc -A
kubectl get pvc -A -o wide          # 看 SC / Volume
kubectl describe pvc -n <ns> <name>
```

- **期望**：所有 PVC `Bound`（`Terminating` 不计入失败）。
- **排障**：`Pending` → 看 `describe` 事件；常见为 SC 不存在、CSI 未就绪、容量不足、WaitForFirstConsumer 未调度。

### 5. 备份时效

```bash
kubectl get backup -A                # CNPG Backup，期望有 completed
velero backup get                    # 期望有近期备份；未装 CLI 见 scripts/velero-install.sh
```

- **期望**：CNPG 有已完成 `Backup`；Velero 有近期备份。
- **排障**：无 completed → 查 `kubectl describe backup -n <ns> <name>`、barman 对象存储连通性；Velero → `velero backup describe <name>`、`velero backup logs <name>`。

### 6. 云盘使用情况

**6a. 集群侧：PVC 申请/容量**

```bash
kubectl get pvc -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SC:.spec.storageClassName,REQ:.spec.resources.requests.storage,CAP:.status.capacity.storage'
```

- **期望**：各 PVC `REQ`=申请值、`CAP`=实际容量（在线扩容后 CAP 会增长到 REQ）。

**6b. 实际使用率（Prometheus）**

```bash
# 经 apiserver service proxy 查（无需暴露 Prometheus）
kubectl -n monitoring get --raw \
  "/api/v1/namespaces/monitoring/services/http:monitoring-kube-prometheus-prometheus:9090/proxy/api/v1/query?query=kubelet_volume_stats_used_bytes%20/%20kubelet_volume_stats_capacity_bytes"
```

- **期望**：各 PVC 使用率 <85%；≥85% 触发告警 `PVCNearlyFull`，≥95% 触发 `PVCCriticalFull`。
- **排障**：无数据 → 监控未就绪（见 `make monitoring`）；使用率高 → 扩容（`make auto-expand-once DRY_RUN=0`）或清理。

**6c. 宿主 ZFS 云盘层（drill）**

```bash
zpool list tank
zfs list -o name,used,avail,refer,quota -r tank/k8s
```

- **期望**：`CAP`（池已用）<80%；数据集 `tank/k8s` 下每个 zvol 对应一个 PV（`pvc-<uuid>`），`USED` 即该云盘实际占用。
- **排障**：池缺失 → `make host-storage`；池 ≥80% → 扩容 vdev（`HOST_ZFS_VDEV`/镜像）或清理；残留 zvol → `bash scripts/list-orphan-volumes.sh` 核对后 `zfs destroy`。

> prod（阿里云）无宿主 ZFS：`[=] 无 zpool`，用量见云盘控制台或 `kubelet_volume_stats_*` 指标。

## 四、drill 与 prod 差异

| 检查 | drill（KVM / ZFS+iSCSI） | prod（阿里云） |
|---|---|---|
| 供给 | democratic-csi | `diskplugin.csi.alibabacloud.com` |
| 介质 | ZFS zvol | ESSD 云盘 |
| 快照类 | `host-zfs-iscsi` | `alicloud-disk` |
| 快照 | ZFS/CSI | 云盘快照 |
| 加密 | ZFS native（`ZFS_ENCRYPTION`） | 云盘加密 |
| 扩容 | zvol resize | 云盘扩容 |
| 跨 AZ | ❌ | ✅ |
| 宿主核对 | 需 `zpool/targetcli` | 无宿主，走云控制台 |

> `make verify-storage STORAGE_BACKEND=alicloud` 会走"跳过后端细节"分支；云盘侧的供给/快照由 CCM/CSI 负责，核对以 `kubectl get sc/pvc/volumesnapshot` 为准。

## 五、证据入库

```bash
make evidence CHECKS="storage_verify"     # 或并入默认证据包
# 产出: evidence/<env>/<ts>/{report.json,report.md,storage_verify.log}
```

`report.json` 记录本项退出码与日志尾部；因命令已逐条回显，`storage_verify.log` 天然包含「命令 + 输出 + 退出码」，可直接作为验收证据。

## 七、宿主核对速查（drill）

集群内检查无法覆盖宿主 ZFS/iSCSI/MinIO，需在宿主执行：

```bash
zpool status ${ZFS_POOL}; zfs list -r ${ZFS_POOL}
targetcli /iscsi ls; ss -lntp | grep 3260
docker ps --filter name=host-minio
```

`make verify-storage` 在第 3 节会以 `[提示]` 提醒上述宿主核对项。

## 八、常见故障定位表

| 现象（脚本输出） | 可能原因 | 处置 |
|---|---|---|
| `StorageClass app-storage 不存在` | 未应用契约 | `make storage-class` |
| `reclaimPolicy=Delete（应为 Retain）` | SC 模板被改 | 改回 `Retain` 后重放 |
| `allowVolumeExpansion=false` | 未开扩容 | 开启后 `make auto-expand` 才生效 |
| `CSIDriver host-zfs-iscsi 不存在` | 未装 CSI | `make csi-storage` |
| `democratic-csi 无 Running Pod` | SSH/凭据/portal 异常 | 查 Pod 日志 + 宿主 iSCSI |
| `n/N 个 PVC 非 Bound` | SC/CSI/容量/调度 | `kubectl describe pvc` |
| `无已完成的 CNPG Backup` | barman 目标不可达 | 查 `describe backup`、对象存储 |
| `未安装 velero CLI` | 无 CLI | `bash scripts/velero-install.sh` |
| `backup-target 未配置` | Longhorn 无异地 | 配 MinIO/OSS backupTarget |
| `ZFS 池 tank 已用 N%（≥80%）` | 宿主池容量紧张 | 扩容 vdev 或清理（`list-orphan-volumes.sh`） |
| `无卷用量数据（监控未采集到）` | Prometheus 未就绪 | `make monitoring`；或看 `kubelet_volume_stats_*` |
