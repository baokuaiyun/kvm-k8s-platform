# 仓拓扑与跨仓契约（分仓骨架）

> 现状：**整合单仓**（本仓即为"平台仓"）。本文给出**生产/持续开发阶段的分仓拓扑**与
> **跨仓契约**，作为规划骨架；真正分仓在生产时按 [`repo-split.yaml`](../gitops/repo-split.yaml) 执行。
> 关联 [`implementation-matrix.md`](implementation-matrix.md)、[`cluster-types.md`](cluster-types.md)、
> [`gitops-fleet.md`](gitops-fleet.md)。

## 一、为什么分仓
- **生命周期/归属不同**：平台（低频、受控）vs 应用（高频、持续开发）。
- **权限与爆炸半径**：应用团队不触碰平台；CI/CD 边界清晰。
- **发布时间分化**：平台版本与应用版本解耦。
> 单一太大后，"持续开发"天然要在**独立 Git**里进行。

## 二、目标拓扑（对齐 D2：fleet / infra / apps）

| 仓 | 内容 | 归属 | 节奏 |
|---|---|---|---|
| **fleet** | 集群/fleet 期望态（`clusters/<c>`、`tenants/*` ResourceSet、runtime-info）+ 引导（kubeadm/kvm/storage + `terraform/`）+ Makefile/文档 | 平台团队 | 低频受控 |
| **infra** | 平台组件（CRD/控制器/平台服务：cilium/storage/cert-manager/harbor/gitlab/可观测…）| 平台团队 | 中频 |
| **apps** | 业务应用清单/Helm/overlays、应用侧 CI | 应用团队 | 高频持续 |

- drill 与 prod **同拓扑**，仅 env/config 差异；分仓为物理复制（结构一致）。
- 机器可读映射见 [`../gitops/repo-split.yaml`](../gitops/repo-split.yaml)；拆分工具 `scripts/repo-split.sh`（`make repo-split`）。
- 各仓独立 CI → **OCI 制品** → Flux 统一消费（Harbor+key-based cosign drill / OIDC prod）。

## 三、跨仓契约（必须固定）
| 契约 | 约定 |
|---|---|
| 制品命名/路径 | platform：`oci://harbor/baokuaiyun/<comp>:<tag>`；apps：`oci://harbor/baokuaiyun/<app>:<tag>`（scheme C） |
| 签名身份 | **每仓独立 cosign 主体/密钥**；Flux `verify` 按来源校验 |
| ResourceSet 输入 schema | `{ tenant, tag, environment, layer }` |
| 租户基线接口 | 平台出 namespace/quota/RBAC/NetworkPolicy；开发仓**只引用参数**，不复制 |
| 环境/版本 | 组件 `overlays/<env>`；tag：`latest`(drill) / `latest-stable` / `vX.Y.Z` |
| CI 边界 | 各仓 CI 各自打包 OCI + 签名；Flux 只消费验签 |
| 制品的集群类型 | 组件带 `type: [A|B]`；渲染按集群类型过滤 |

## 四、迁移触发与步骤
**触发**：持续开发启动 / 多团队 / 需权限隔离 / 发布节奏分化。

**步骤**（按 `repo-split.yaml`）：
1. 新建"开发仓"，迁入 `apps/*`（连同其 CI）。
2. 平台仓保留 `fleet/ layers/ components/{infra,platform} bootstrap/`。
3. 各仓配置独立 cosign 身份与 CI 出制品。
4. Flux `ResourceSet` 同时引用平台与应用制品（OCI URL 不变，消费方式不变）。
5. `GIT_MODE` 由 `later` 提前为实际值。

## 五、当前（整合期）如何"平滑"
- 用 **`CODEOWNERS`** 模拟属主边界（平台 vs 应用），分仓时按同一边界迁移。
- `gitops/repo-split.yaml` 声明 **路径 glob → 目标仓 → owner → 制品约定**，未来据此一键拆。
- 目录暂不物理拆分；`apps/` 占位已预留（见 `apps/README.md`）。
