# 状态账本（单一进度源）

> 唯一进度来源。所有"已做/在做/待做"在此登记，字段：
> **平面 | 角色 | 现状 | 形态(D=同集群 / B=独立数据集群) | 可移植 | 依赖 | 下一步**。
> 关联总纲 [`implementation-matrix.md`](implementation-matrix.md)。

## 已完成（drill，形态 D，均为"可移植接口/实现"）

| 项 | 平面 | 角色 | 形态 | 可移植 | 说明 |
|---|---|---|---|---|---|
| KVM + 5 节点 HA + Cilium/Longhorn/cert-manager/kube-vip | 集群 | workload | D | ✅ | 单/多节点契约一致 |
| kgateway + 自签通配证书 | 集群 | workload | D | ✅ | 监听名 `https` |
| Harbor 单项目 + scheme C + 节点 containerd | 工具链 | toolchain | D | ✅ | 镜像源单一 |
| 镜像管道 + Chart OCI（11 charts） | 工具链 | toolchain | D | ✅ | 需宿主信任自签 CA |
| GitLab route C（Operator+CNG CE 19.4.1） | 工具链 | toolchain | D | ⚠️ | 网关 sectionName=https 等定制 |
| Casdoor IdP（可访问、OIDC discovery） | 工具链 | toolchain | D | ✅ | OIDC 应用回调已配 |
| platform-data（CNPG 三库 + Redis） | 数据 | data | D | ✅ | Redis 用 StatefulSet（operator bug） |
| 安全基线（Mode A + PSA + Quota + CiliumNetPol） | 租户 | tenant | D | ✅ | team-a/team-b |
| 可观测（GitOps 组件 `monitoring`）：kube-prometheus-stack + Grafana 入口 | 工具链 | toolchain | D | ✅ | 镜像/chart 走 Harbor，Flux 收敛 |
| 日志 Loki + Grafana Alloy（替代 Promtail）+ Blackbox 探测 | 工具链 | toolchain | D | ✅ | Loki single-binary + Alloy DaemonSet |
| 供应链/密钥：Kyverno + Sealed-Secrets + cosign | 工具链 | toolchain | D | ✅ | verifyImages 因离线 TUF 降 Audit |
| 备份：CNPG barman→S3(MinIO) + ScheduledBackup + 恢复演练 | 数据 | data | D | ✅ | S3 出口可换 OSS |
| Velero + S3(MinIO) + node-agent | 数据 | data | D | ✅ | 备份 platform-data 成功 |
| etcd 定时备份 + 宿主 cron | 数据 | data | D | ✅ | 45MB 快照 |
| 应用 pg_dump（Harbor/Casdoor） | 数据 | data | D | ✅ | 改 TCP 规避 peer auth |
| Flux Operator（**Helm 安装**，对齐 D2）+ OCI + cosign | 工具链 | toolchain | D | ✅ | Helm release `flux-operator` 0.61.0（`make flux-operator` 一键）；FluxInstance Ready；ResourceSet 渲染 cert-manager/monitoring；key-based 验签（SourceVerified=True） |
| 制品按需导入（fleet 驱动，检测式增量） | 工具链 | toolchain | D | ✅ | `components/*/component.yaml` + `fleet/<mode>/components.yaml` → `locks/<mode>-<env>.lock` → `make sync-artifacts`（检测式，幂等）；all-in-one/drill 新增2/跳过57/失败0 |
| 两平面边界 + 引导顺序文档 | — | — | — | ✅ | `docs/bootstrap-order.md`、`docs/data-source.md`；profiles 增 TOOLCHAIN_MODE/ENABLE_FLUX/DATA_SOURCE/GIT_MODE |
| 引导脚本（mgmt 自启 / member 消费） | 引导面 | — | — | ✅ | `bootstrap/mgmt/*`（preflight/import-images/up-core/up-data/up-harbor/up-flux/bootstrap）+ `bootstrap/member/*` + `bootstrap/lib.sh`；`make mgmt-bootstrap`/`member-bootstrap`；preflight 通过（脚本语法全部校验） |
| 集群类型划分（管理/开发者 vs 生产/业务） | — | — | — | ✅ | `docs/cluster-types.md`：两类各自递进 + 横切基线（安全/可观测/GitOps）；CI 属 A 侧，不进生产 |
| 分仓骨架（拓扑 + 跨仓契约，生产时执行） | — | — | — | ✅ | `docs/repo-topology.md` + `gitops/repo-split.yaml`（机器可读 glob→仓→owner→制品）+ `CODEOWNERS`（模拟边界）+ `apps/README.md` 占位 |
| 制品解析 lock 命名修齐 | 工具链 | — | — | ✅ | lock=`<mode>-<env>-<type>.lock`；resolve/sync/verify-bootstrap 已对齐；`make verify-bootstrap` 通过（73 条） |
| GitOps 期望态独立到 `gitops/` + 参数说明 | 工具链 | toolchain | — | ✅ | fleet/components/tenants/roles/planes/profiles/repo-split → `gitops/`；新增 `gitops/{README,settings}.md`、`docs/parameters.md`；`locks` 移至 `gitops/locks`（gitignored）；Makefile/bootstrap/CODEOWNERS/docs 引用同步；解析/验收通过 |
| fleet 叠加(stack)与单独(standalone) | 工具链 | toolchain | — | ✅ | `gitops/fleet/layers/*` + `clusters/<c>/stack.yaml`；`FLEET_MODES` 并集去重+类型过滤；lock=`<units>-<env>-<type>.lock`；`ENABLE_FLUX=false` → `bootstrap/member/standalone.sh`；实测 core+data=31 / core+gitlab(A)=39 / 同步跳过 |
| stack→ResourceSet 真实渲染 + 组件制品 | 工具链 | toolchain | — | ✅ | `bootstrap/render-stack.sh`（按 stack 渲染 OCIRepository(verify)+Kustomization）；`bootstrap/build-component.sh`（组件目录→OCI+签名）；`make {build-component,render-stack}`；`demo` 全链路验证（SourceVerified=True、ConfigMap 落地） |
| 真实组件纳管（cert-manager 接管） | 工具链 | toolchain | — | ✅ | `gitops/components/infra/cert-manager/{base,overlays/drill}`（OCIRepository(chart)+HelmRelease releaseName=cert-manager）；渲染器加 ClusterRoleBinding(cluster-admin)；HelmRelease Ready、证书正常 |
| GitLab CI（组件自动出制品） | 工具链 | toolchain | — | ✅ | `.gitlab-ci.yml` + `bootstrap/ci-build-components.sh`（按 diff 构建+签名）；`ci/tools.Dockerfile` + `ci/build-tools.sh`（工具镜像）；待注册 Runner |
| 单节点起步（1CP+0W，去污点）+ 独立 `NODE_*` 规格 | 集群 | workload | D | ✅ | `variables.mk`（`WK_INIT_COUNT=0`、`NODE_VCPU/RAM/DISK`）；`init-control-plane.sh` 自动去污点；`make scale-out` 从单节点补齐 worker |
| 云盘/计算分离存储（宿主 ZFS+iSCSI+democratic-csi）+ 宿主 MinIO | 数据 | data | D | ✅ | `make host-storage`/`csi-storage`/`storage-class`；`storage/host-zfs-iscsi/*`；**实测**：动态供给 Bound、在线扩容 1→3Gi 数据无损、VolumeSnapshot `readyToUse=true`、`verify-storage` 通过；[`cloud-disk-data-solution.md`](cloud-disk-data-solution.md) |
| 删除→重建（配置化删 VM + 一键 rebuild + 重启自动收尾） | 集群 | workload | D | ✅ | `make reset-cluster`/`rebuild`/`rebuild-core`；`kvm/scripts/destroy-all.sh`（配置化）；`kvm/scripts/post-reboot-finish.sh` + `make post-reboot-install`（重启后自动 `modprobe zfs → host-storage → csi-storage → storage-class → verify-storage`）|
| 驱动可替换 StorageClass（Kustomize base+patch）+ fleet 去 longhorn | 数据/工具链 | data/toolchain | D | ✅ | `storage/base`（契约）+ `storage/{host-zfs-iscsi,longhorn,alicloud}` patch；`apply.sh` 走 `kubectl apply -k`；fleet 用通用 `storage` 组件，`resolve/render` 按 `STORAGE_BACKEND` 展开为 `storage-<backend>`；组件 `storage-host-zfs-iscsi`/`storage-longhorn` |
| D2 runtime-info + `postBuild.substitute` + tenants/clusters | 工具链 | toolchain | D | ✅ | `gitops/runtime-info.yaml`、`gitops/clusters/all-in-one/{flux-system/flux-instance.yaml,runtime-info.yaml,tenants.yaml}`、`gitops/tenants/{policies,infra,apps}.yaml`（`${ARTIFACT_TAG}`/`${ENVIRONMENT}` 由 runtime-info 注入） |
| 验收证据层（Proof） | — | — | — | ✅ | `scripts/evidence.sh` + `make evidence` → `evidence/<env>/<ts>/report.{json,md}`（命令/输出/退出码/git commit/制品 lock sha256）；`docs/evidence-and-acceptance.md` |
| 基础设施平面（Terraform 引导 Flux） | 基础设施 | — | — | ✅ | `terraform/envs/drill`（`flux-operator-bootstrap` 模块；kubernetes/helm provider）；`make tf-init/tf-validate/tf-plan/tf-apply/tf-fmt`；`validate`/`plan` 通过；[`../terraform/README.md`](../terraform/README.md) |
| 三分仓拓扑（fleet/infra/apps）+ 拆分工具 | — | — | — | ✅ | `gitops/repo-split.yaml`（v2 拓扑）+ `scripts/repo-split.sh` + `make repo-split`（生成 filter-repo 拆分脚本）；`CODEOWNERS`、`docs/repo-topology.md` |
| drill 重建为单节点 + 数据面/Harbor 起 | 数据/工具链 | data/toolchain | D | ✅ | 单节点 cp-1：`make operators`（CNPG 1.25.1 + redis-operator）→ `make platform-data`（platform-pg 三库 + Redis，PVC 走 app-storage）→ `make harbor`（外置 PG/Redis；core `Pong`）；`make verify-data` 通过 |
| 删除→重建（配置化删 VM + 一键 rebuild） | 集群 | workload | D | ✅ | `kvm/scripts/destroy-all.sh`（读 `CP_NAMES/WK_NAMES`，`KEEP_NETWORK`/`PURGE_HOST_STORAGE`）；`create-vm.sh` 幂等；`make reset-cluster`/`clean`/`clean-all`/`rebuild`/`rebuild-core`/`purge-host-storage`；`scripts/list-orphan-volumes.sh` |
| PV 云盘自动预警 + 自动扩容（host-zfs-iscsi/alicloud） | 数据 | data | D | ✅ | `observability/alerts.yaml`（`PVCPredictFull`/`PVCResizeStuck`/inode/PV Failed）；`scripts/auto-expand-pvc.sh` + `make auto-expand`（CronJob，默认 dry-run）；`observability/apply-alerts.sh` 渲染 `AlertmanagerConfig`；参数见 [`parameters.md`](parameters.md) |
| 告警通知多渠道（企微/钉钉/Slack/邮件/webhook）+ 运维参数导入 | 工具链 | toolchain | D | ✅ | `observability/apply-alerts.sh`（5 渠道、severity 路由、多渠并存、`ops.env`/`ALERT_ENV_FILE` 导入）；`make alerts`/`alerts-print`/`alert-adapter`；[`alert-notification.md`](alert-notification.md) |
| 计算图层（规格/节点池/超分/弹性/配额/GPU 文档 + 验收） | 集群 | workload | D | ✅ | 新增 [`compute-architecture.md`](compute-architecture.md)/[`compute-verification.md`](compute-verification.md)（集群平面横切）；`make verify-compute`（只读 8 项）+ `make compute-drill`（压测自清理）；参数 `COMPUTE_*`/`RESERVE_*`/`OVERCOMMIT_*`/`TENANT_QUOTA_*`；`make compute-node-pools`、`make metrics-server`；计算告警（限流/超分/配额/不可调度）|

## 待办

| 项 | 平面 | 角色 | 依赖 | 下一步 |
|---|---|---|---|---|
| Casdoor OIDC 切换（Harbor/GitLab/k8s） | 工具链/租户 | toolchain | 映射表(已备) | 切换 + 回滚演练（见 identity-mapping.md） |
| Flux 纳管全部组件（组件目录→OCI+签名流水线） | 工具链 | toolchain | Flux Operator(已通) | 用 CI 产出组件制品替换手工制品 |
| GitLab Runner（CI） | 工具链 | toolchain | GitLab | 注册 runner |
| OTel / kured / descheduler / VPA | 工具链 | toolchain | — | 装 agent |
| Snapshotter CRD + VolumeSnapshotClass | 数据 | data | — | 补本地快照（barman 已可替代） |
| Crossplane 数据供给抽象 + 金标 profile | 数据 | data | 身份/隔离 | `DatabaseClaim/RedisClaim` |
| 独立数据集群 B + 跨集群消费 | 数据 | data | 备份接口(已有) | ClusterMesh / LB+DNS |
| 工具链外置化 | 工具链 | mgmt | B | 管理集群 + proxy cache |
| Mode C(vCluster) / Mode B(Backstage+Crossplane) | 租户 | tenant | GitOps/身份 | 逐档交付 |
| 生产 profile（A 托管云 / OSS / 云盘） | 数据/集群 | — | B | prod.env |
| 节点池落地（`data`/`toolchain`/`gpu` 专用池） | 集群 | workload | compute 文档 | 按池打标/污点并迁移工作负载（`make compute-node-pools`）|
| metrics-server + HPA/VPA/descheduler/Cluster-Autoscaler | 集群/工具链 | toolchain | 镜像（Tier2 已有）| 装 agent；HPA/VPA 用 `COMPUTE_ENABLE_*` 开 |
| 异构/GPU 直通 + device plugin | 集群 | workload | GPU 硬件 | KVM VFIO / 云 GPU + `COMPUTE_ENABLE_GPU=1` |

## 本轮环境改动（drill）
- 新增**计算图层**：`docs/compute-architecture.md`/`compute-verification.md`；`make verify-compute`（只读）+ `make compute-drill`（压测）；参数 `COMPUTE_*`/`RESERVE_*`/`OVERCOMMIT_*`/`TENANT_QUOTA_*`；`make compute-node-pools`、`make metrics-server`；计算告警四则。
- 起步改为**单节点**（`WK_INIT_COUNT=0`，cp-1 用 `NODE_*` 8C/16G/120G），init 自动去 control-plane 污点。
- 存储改为**宿主 ZFS + iSCSI + democratic-csi**（云盘/计算分离）；Longhorn 降为可选后端；SC 默认 `app-storage`。
- 对象/备份层改为**宿主 MinIO（docker）**（模拟 OSS）。
- 新增在线扩容演练 `make drill-expand-pvc`。
- 新增 PV 自动扩容控制器 `make auto-expand`（默认 dry-run，只写 `auto-expand/recommendation`）与告警通知 `make alerts`（AlertmanagerConfig 参数化）。
- 宿主信任 Harbor 自签 CA（`helm push` OCI）。
- 备份桶：`pg-backups` / `velero` / `longhorn-backups` / `gitlab-object`（宿主 MinIO）。
