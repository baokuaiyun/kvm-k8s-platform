# 可观测 · 运维处置手册（Runbooks）

> 每条 critical/warning 告警都应有对应 Runbook；告警注解 `runbook_url` 指向本文对应锚点。
> 架构见 [`observability.md`](observability.md)。锚点 = 章节小写（如 `#nodedown`）。

通用排查顺序：**告警 → 定位对象（namespace/pod/node/PVC）→ 看指标/日志 → 处置 → 记录**。

```bash
kubectl -n monitoring port-forward svc/monitoring-prometheus 9090 &   # 指标
kubectl -n monitoring port-forward svc/loki 3100 &                    # 日志
# Grafana Explore 查 Loki：{namespace="x", app="y"}
```

## NodeDown
- **现象/影响**：`up == 0` 持续 5m；该节点工作负载受影响。
- **排查**：`kubectl get node <n>`、`ssh <n> ` 上看 kubelet/containerd；`kubectl describe node <n>`（Conditions/资源压力）。
- **处置**：恢复节点（重启 kubelet/containerd 或主机）；确认 Pod 是否被驱逐/重调度；必要时 `cordon`。
- **升级**：单节点集群（drill）节点不可用=整体不可用，立即升级。

## HighCPUUsage
- **现象**：节点 CPU>85% 持续 10m。
- **排查**：`kubectl top nodes/pods --sort-by=cpu`；确认是否业务高峰/异常进程。
- **处置**：迁移/限流热点负载；兜底扩容；若误报调阈值。

## HighMemoryUsage
- **现象**：节点内存>90% 持续 10m。
- **排查**：`kubectl top pods --sort-by=memory`；是否内存泄漏/OOM 前兆。
- **处置**：重启/迁移异常 Pod；扩容节点；检查 limits。

## CPUThrottlingHigh
- **现象**：容器 CPU 被 CFS 限流 >50% 持续 15m。
- **排查**：`kubectl -n <ns> top pod <p>`；确认 `limits.cpu` 是否过紧或负载是否突增。
- **处置**：上调 CPU `limits`/降载；或移除过紧 limit（requests 保底）；见 [`compute-architecture.md`](compute-architecture.md) 调度与 QoS。

## NodeAllocatableOvercommit
- **现象**：节点 CPU `requests`/`allocatable` >2x 持续 15m。
- **排查**：`kubectl describe node <n> | grep -A6 "Allocated resources"`。
- **处置**：下调 requests 或加节点；CPU 可压缩但争抢会抬升延迟。

## NodeMemoryOvercommit
- **现象**：节点内存 `requests`/`allocatable` >1.5x 持续 15m。
- **排查**：`kubectl top pods --sort-by=memory`；找准内存大户。
- **处置**：**优先**加内存/降 requests（内存不可压缩，超分易 OOM）；必要时迁移负载。

## QuotaNearFull
- **现象**：命名空间某资源配额使用 >90%。
- **排查**：`kubectl -n <ns> get resourcequota <q> -o yaml`（used/hard）。
- **处置**：清理无用负载或上调配额（`TENANT_QUOTA_*` / create-tenant.sh 参数）。

## UnschedulablePods
- **现象**：Pod 因不可调度长时间 Pending（`kube_pod_status_unschedulable>0`）。
- **排查**：`kubectl describe pod <p>`（资源不足/亲和/污点/PVC）。
- **处置**：释放容量、改调度约束或扩节点（`make scale-out` / 云 Autoscaler）。

## PodCrashLooping
- **现象**：1h 内容器重启>5。
- **排查**：`kubectl -n <ns> logs <pod> --previous`；`describe pod`（Events/探针/资源）。
- **处置**：修配置/镜像/依赖；必要时回滚版本。

## PodPending
- **现象**：Pod Pending>15m。
- **排查**：`kubectl describe pod`（调度失败原因：资源不足/亲和/污点/PVC）。
- **处置**：释放资源、调整调度约束、修复 PVC/StorageClass。

## CertificateExpiring
- **现象**：证书 7d 内到期。
- **排查**：`kubectl get certificate -A`；`kubectl -n <ns> describe certificate <c>`。
- **处置**：确认 cert-manager 正常与签发者可用；手动 renew 或修复 DNS-01；见 [`access-gateway.md`](access-gateway.md)。

## PVCNearlyFull
- **现象**：PVC 使用率>85%。
- **排查**：`kubectl -n <ns> get pvc`；定位写入方。
- **处置**：清理或扩容 PVC（见 [`cloud-disk-data-solution.md`](cloud-disk-data-solution.md) 自动扩容）。

## PVCCriticalFull
- **现象**：PVC>95%，即将写满。
- **处置**：**立即**扩容或清理；避免写满导致服务不可用/数据损坏。

## PVCPredictFull
- **现象**：按 6h 线性外推 24h 内写满。
- **处置**：提前扩容/清理；核对增长来源。

## PVCInodesNearlyFull
- **现象**：inode 使用率>85%（文件数密集，如 registry/gitaly）。
- **处置**：清理小文件/旧数据；扩容卷。

## PVCResizeStuck
- **现象**：`requested > capacity` 持续 30m（resizer 卡住）。
- **排查**：`kubectl describe pvc`；CSI resizer 状态。
- **处置**：按需重启 Pod 完成 fs resize；检查 CSI 控制器。

## PersistentVolumeFailed
- **现象**：PV 进入 Failed。
- **排查**：底层存储（democratic-csi/ZFS/iSCSI）健康。
- **处置**：修复底层卷；必要时重建 PV/PVC（注意数据）。

## LonghornVolumeDegraded
- **现象**：卷副本不足（`robustness == 2`）。
- **排查**：`kubectl -n longhorn-system get volumes.longhorn.io`；节点/磁盘状态。
- **处置**：恢复故障节点或磁盘；等待 replica 重建。

## LonghornVolumeFaulted
- **现象**：卷故障（`robustness == 3`），数据有风险。
- **排查**：底层副本/节点/磁盘是否全部不可用。
- **处置**：**优先保数据**，恢复可用副本后再操作。
- 迁移/恢复参考 [`longhorn-engine-image-migration.md`](longhorn-engine-image-migration.md)。

## LonghornNodeStorageHigh
- **现象**：Longhorn 节点存储>80%。
- **处置**：清理/迁移副本；扩容磁盘。

## LonghornBackupTargetUnreachable
- **现象**：备份目标（S3/MinIO）不可达，异地备份中断。
- **排查**：`kubectl -n longhorn-system get backupTarget`；网络/凭据/对象存储。
- **处置**：恢复连通与凭据；补跑备份。

## VeleroBackupFailure
- **现象**：6h 内有失败的备份。
- **排查**：`kubectl -n velero logs deploy/velero`；对象存储连通与 schedule。
- **处置**：修复存储/权限；手动触发一次备份验证。

## VeleroBackupStale
- **现象**：>48h 无成功备份，存在数据保护缺口。
- **排查/处置**：同 `VeleroBackupFailure`；确认 schedule 在运行并及时补备。

## CNPGBackupStale
- **现象**：CNPG 集群 >48h 无可用备份。
- **排查**：`kubectl -n <ns> get cluster,backup`；对象存储与 `ScheduledBackup`。
- **处置**：修复对象存储/凭据；手动 backup。

## Grafana 无法访问（通用）
- **排查**：`kubectl -n monitoring get pod,svc | grep grafana`；HTTPRoute `ResolvedRefs`；DNS（`getent hosts grafana.test.baokuaiyun.com` → 入口 VIP）。
- **处置**：必要时 `restart` Grafana；确认 `root_url` 配置；DNS 用 `make ingress-dns`。

## Loki 无日志 / 查询为空（通用）
- **排查**：Alloy Pod 是否 Running；`kubectl -n monitoring logs <alloy>`；Loki `/loki/api/v1/labels`。
- **处置**：修复 Alloy（配置/RBAC/网络）；确认应用在输出日志。

## Alloy 崩溃（通用）
- **排查**：`kubectl -n monitoring logs <alloy>`（River 语法错误最常见）。
- **处置**：修 `alloy.configMap.content`；重建组件、Flux 收敛。

## 告警未投递（通用）
- **排查**：`kubectl -n monitoring get alertmanagerconfig platform-alerting`；Alertmanager UI/Config；receiver URL 可达。
- **处置**：修 receiver/Secret；见 [`alert-notification.md`](alert-notification.md)。