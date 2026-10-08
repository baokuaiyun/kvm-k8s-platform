# 实施状态总览（Implemented vs Pending）

> 实施**总纲**见 [`implementation-matrix.md`](implementation-matrix.md)（四平面 × 集群定位 × CDM × 规模）；
> 数据平面见 [`data-plane-management.md`](data-plane-management.md)；完成定义见 [`plane-dod.md`](plane-dod.md)。
>
> 对照总纲与各专题文档，记录**当前演练集群实际落地情况**。
> 环境：单机 KVM，5 节点（3CP+2W），全部镜像走本域 Harbor（项目 `baokuaiyun`，scheme C）。

## 一、环境基线调整（与本手册默认不同处）

| 项 | 调整 | 原因 |
|---|---|---|
| worker 磁盘 | 50G → 90G | Longhorn/PG/Harbor 卷容量不足 |
| worker 内存 | 4G → 6G | CNG + 监控栈内存不足（`virsh setmaxmem/setmem --config`，需关机） |
| Longhorn 副本 | 卷降为 `numberOfReplicas=1`（容量受限） | 仅 2 存储节点 + 50G 盘 |
| 默认 StorageClass | `app-storage` 由 **Kustomize**（`storage/base` + `storage/<backend>` patch）管理，drill 后端 `host-zfs-iscsi` | 契约集中在 base；换驱动只改 `STORAGE_BACKEND` |
| Harbor 卷 | 扩到 30G；registry FS 在线扩容 | 推送大量镜像后写满 |
| Harbor 自签 CA | 装入宿主机信任（`/usr/local/share/ca-certificates/harbor-test-ca.crt`） | `helm push OCI` 校验 TLS |
| gitlab/grafana DNS | libvirt dnsmasq `host-record` + 宿主 `/etc/hosts` | 入口域名解析 |
| 起步形态/存储 | **单节点起步**（`WK_INIT_COUNT=0`，cp-1 去污点）+ **宿主 ZFS+iSCSI 云盘方案**（`STORAGE_BACKEND=host-zfs-iscsi`，Longhorn 降为可选）| 云盘/计算分离、删集群可重现，见 `docs/cloud-disk-data-solution.md` |

## 二、已实现且验证

| 阶段 | 项 | 验证方式 |
|---|---|---|
| 1 | KVM/VM/kubeadm 5 节点 HA | `kubectl get nodes` 5 Ready；etcd 3 成员 |
| 1 | **单节点起步**（`WK_INIT_COUNT=0`，cp-1 自动去污点，`NODE_*` 规格） | `kubectl get nodes` 1 Ready；`describe node` 无 control-plane 污点 |
| 1 | **云盘/计算分离存储**（宿主 ZFS+iSCSI+democratic-csi；`app-storage`） | PVC Bound；在线扩容 1→3Gi 数据无损；`VolumeSnapshot readyToUse=true`；`make verify-storage` 通过 |
| 1 | Cilium / cert-manager / kube-vip（存储改用 host-zfs-iscsi，Longhorn 降为可选） | Pod Running |
| 1 | kgateway + 自签通配证书 `*.test.baokuaiyun.com` | Gateway PROGRAMMED；Harbor 443 可达 |
| 1 | 镜像管道（Harbor 单项目/robot/scheme C/containerd 指向 Harbor） | 节点 `crictl pull` 成功 |
| 3 | platform-data（CNPG `platform-pg` 三库 + Redis；单节点，PVC 走 `app-storage`） | Cluster/Database Ready；`make verify-data` 通过 |
| 3 | Harbor（外置 PG/Redis；clusterIP 起，core `Pong`） | helm 状态 deployed；Pod Running（对外网关 `kgateway` 待镜像预载）|
| 3 | GitLab route C（Operator 3.4.1 + CNG CE 19.4.1） | CR Running；登录页 200 |
| 3 | Casdoor IdP | Pod 健康；网关访问 200 |
| 2 | 安全基线（Mode A 租户 + PSA + Quota/LimitRange + CiliumNetworkPolicy） | `team-a/team-b` 就绪；privileged Pod 被拒 |
| 2 | 监控栈 kube-prometheus-stack（Prometheus/Grafana/Alertmanager/operator/kube-state/node-exporter） | Pod Running；PVC 用 `app-storage` |
| 2 | Grafana 入口 | `https://grafana.test.baokuaiyun.com/login` 200 |
| 2 | 告警规则 | `cluster-alerts` PrometheusRule 已应用（含计算四则：限流/超分/配额/不可调度） |
| 2 | **计算图层验收**（节点/超分/调度/配额/弹性/节点池/GPU/告警） | `make verify-compute`（只读 8 项，命令逐条回显）；`make compute-drill`（压测，临时 ns 自清理）；详见 [`compute-verification.md`](compute-verification.md) |
| 2 | 日志 Loki（single-binary）+ Promtail | Loki 收到日志（labels 含 namespace/pod）；promtail 5/5 |
| 2 | Blackbox Exporter | Pod Running |
| 3 | Harbor OCI Helm chart | `helm push`/`helm show chart oci://...` 成功（11 charts） |
| 3 | Harbor OCI chart 分发 | `registry/push-charts-to-harbor.sh` |
| 4 | etcd 定时备份 | `scripts/backup-etcd.sh` 生成 45MB 快照；宿主 cron 每日 02:00 |
| 4 | 应用级 pg_dump 备份（Harbor registry / Casdoor） | 产物非空（TCP 连接，修正 peer auth） |

## 三、已实现但有局限

- **Harbor/Casdoor/GitLab 共用 platform-data**：CNPG 单实例、Redis 单副本（drill）。
- **Longhorn 卷单副本**、`backupTarget` 指向本地 NFS（`nfs://192.168.124.1:/data/backups/longhorn`）但**未配置 recurringJobs、NFS 导出未建**。
- **CNPG 备份**：`volumeSnapshot` 需 Snapshotter CRD，集群**无 VolumeSnapshotClass**；barman(OSS) 未配置 → PG 快照/异地备份未跑通（用 `pg_dump` 兜底）。
- **GitLab toolbox `backup-utility`**：对象存储备份桶未配置，未做全量一致性备份演练。
- **Casdoor OIDC 对接**：Casdoor 服务可用，但到 Harbor/GitLab 的 OIDC 应用与登录尚未配置（见待办）。
- **GitLab SSH**：经 NodePort（未走 LB/VIP:22）；Container Registry 关闭。

## 四、待办（尚未实现/未验证）

| 阶段 | 项 | 说明 |
|---|---|---|
| 2 | OTel Collector / Fluent Bit | 可选 agent，未装 |
| 2 | kured / descheduler / VPA+Goldilocks / Popeye / Pluto | 运维 agent，未装 |
| 3 | Flux CD GitOps | 未 bootstrap（需 Git 仓库） |
| 3 | Casdoor OIDC → Harbor/GitLab(/ArgoCD/Backstage) | 需在 Casdoor 建应用取 client 凭据后配置 |
| 3 | Harbor Proxy Cache / CoreDNS rewrite | 未配置 |
| 3 | ArgoCD / Backstage | 未安装 |
| 3 | 多租户 Mode B (Crossplane+Backstage) | `infrastructure/crossplane/*` 未 apply |
| 3 | 多租户 Mode C (vCluster) | 未安装 |
| 4 | Velero（集群资源+PV 备份） | `scripts/velero-install.sh` 未执行（需 S3 端点） |
| 4 | CNPG barman(OSS) + ScheduledBackup | 需对象存储与 Snapshotter |
| 4 | kubeadm 升级 SOP 演练 | 未演练 |
| 4 | 证书续期告警 | 未配置 PrometheusRule |
| — | 生产文档（阿里云/域名迁移/ACR 旧路径） | 演练不适用 |

## 五、与文档的已知漂移（待修正）

- `implementation-playbook.md` 仍写 `k8s-library`、GitLab chart 8.2.0、`make platform`；实际为 scheme C + GitLab route C 10.4.1。
- `storage-plan.md` 契约 SC 为 `app-storage`；既有 PVC 仍 `longhorn`。
- `platform-data.md` 写 `RedisReplication`；实际为 StatefulSet `platform-redis`（redis-operator 已装未用）。
- `image-pipeline.md` 称 skopeo 对 registry.gitlab.com 失败；实测可用。
- `registry/images/tier2-platform.txt` GitLab 版本 v17.2.0（实际 19.4.1，另见 `gitlab-cng.txt`）。
- `kvm/br-prod.xml` 需 `network-refresh` 才使新增 dns 记录在 dnsmasq 生效（演练用 `virsh net-update`/hosts 兜底）。

## 六、复现命令速查

```bash
# 安全基线
bash infrastructure/tenants/create-tenant.sh team-a
# 监控
helm upgrade --install monitoring /data/kvm/charts/kube-prometheus-stack-*.tgz -n monitoring -f platform/monitoring/kube-prometheus-stack-values.yaml
helm upgrade --install loki /data/kvm/charts/loki-*.tgz -n monitoring -f platform/monitoring/loki-values.yaml
helm upgrade --install promtail /data/kvm/charts/promtail-*.tgz -n monitoring -f platform/monitoring/promtail-values.yaml
helm upgrade --install blackbox /data/kvm/charts/prometheus-blackbox-exporter-*.tgz -n monitoring --set image.registry=harbor.test.baokuaiyun.com/baokuaiyun --set image.repository=prometheus-blackbox-exporter --set image.tag=v0.28.0
# 备份
bash scripts/backup-etcd.sh 192.168.124.10
PG_HARBOR_PASS=<..> bash platform/backup/backup.sh harbor
# OCI charts
for f in /data/kvm/charts/*.tgz; do helm push "$f" oci://harbor.test.baokuaiyun.com/baokuaiyun --insecure-skip-tls-verify --username 'robot$baokuaiyun+pushpull' --password "$HARBOR_ROBOT_PASS"; done
```
