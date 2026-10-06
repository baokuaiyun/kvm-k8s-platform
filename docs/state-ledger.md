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
| 监控 kube-prometheus-stack + 告警 + Grafana 入口 | 工具链 | toolchain | D | ✅ | 镜像走 Harbor |
| 日志 Loki + Promtail + Blackbox | 工具链 | toolchain | D | ✅ | Loki single-binary |
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

## 本轮环境改动（drill）
- worker 磁盘 50G→90G、内存 4G→6G；Harbor registry 卷扩到 30G；SC 默认 `app-storage`。
- 宿主信任 Harbor 自签 CA（`helm push` OCI）。
- 新增备份出口（MinIO 桶 `pg-backups`/`velero`/`longhorn-backups`）。
