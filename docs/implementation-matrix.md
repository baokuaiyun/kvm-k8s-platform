# 实施矩阵（主入口）：四平面 × 集群定位 × CDM 阶梯 × 规模

> 本文是**实施总纲**。其余文档是它的分册/命令详解：
> 数据平面 → [`data-plane-management.md`](data-plane-management.md)；
> 完成定义 → [`plane-dod.md`](plane-dod.md)；
> 命令与坑 → [`implementation-playbook.md`](implementation-playbook.md)；
> 当前落地情况 → [`implementation-status.md`](implementation-status.md)。

## 0. 一句话模型
平台按 **四个平面** 建设，安装时给每个集群选定 **定位（role）**，按 **CDM 客户交付成熟度阶梯** 逐档交付，
并用 **规模档位（S/M/L）** 调节每层的强度。**所有层彻底解耦**：核心清单可在任意合规 K8s 上运行，云能力只是可选适配器。

---

## 1. 四平面定义

| 平面 | 职责 | 承载形态 | 生命周期 | 不可逆契约 | DoD（详见 plane-dod） |
|---|---|---|---|---|---|
| **数据平面** | PG / Redis / 对象存储 / KMS / 备份存储 | A 托管云 ｜ **B 独立数据集群（生产首选）** ｜ C 专用节点池 ｜ D 同集群(drill) | **宠物**：DR 第一、谨慎变更 | 端点与命名、库/角色模型、扩展清单、备份接口、数据分级 | 新应用"只填端点"接入；PITR/恢复演练通过 |
| **工具链·管理平面** | Harbor、GitLab/Runner、镜像管道、Casdoor、可观测、备份编排、(策略/密钥) | 可外置共享（管理集群）或内嵌 | 半宠物 | 镜像 scheme C、单项目/robot、身份映射、Chart OCI 命名 | 新集群能"消费外部工具链"零改造；CI/CD 可用 |
| **集群平面** | 集群底座、CNI/CSI、Gateway、节点池 | 单节点→多节点→多集群 | **牲畜** | 网段/VIP、内网域名、Gateway 监听名、SC 名 | 单节点与多节点**同契约**，可平滑 scale-out |
| **租户平面** | Mode A/B/C、隔离、配额、RBAC、自助 | 建在集群面之上 | 牲畜 | 租户命名/隔离模型、身份→RBAC 映射 | 租户自助开通 + 隔离验收 |

> 启动顺序：**数据平面 → 工具链平面 → 集群平面 → 租户平面**（工具链自己也要数据；B 形态需先建数据集群）。

---

> 集群**类型**（管理/开发者平台 vs 生产/业务）与递进关系见 [`cluster-types.md`](cluster-types.md)：
> 两类各自递进，安全/可观测/GitOps 为共有横切基线；CI 属管理/开发者平台侧，不进生产集群。

## 2. 集群定位（Role）模型

| Role | 对应平面 | 典型内容 | 可组合 |
|---|---|---|---|
| `data` | 数据平面 | CNPG / Redis / 对象存储 Operator / 备份(PITR) / 供给抽象 | ✅ |
| `toolchain` | 工具链·管理平面 | Harbor / GitLab / Runner / 镜像管道 / Casdoor / 可观测 / 策略·密钥 | ✅ |
| `workload` | 集群平面 | CNI / CSI / Gateway / 节点池 / 底座 | ✅ |
| `tenant` | 租户平面 | Mode A/B/C / 配额 / RBAC / 自助 | ✅ |
| `all-in-one` | 全部 | drill / CDM-1/2 起步、小客户 | 简化 |

- 组合示例：`mgmt = data+toolchain`；`biz = workload+tenant`；`all-in-one` 仅演练/起步。
- **安装时决定定位**：`CLUSTER_ROLE=data`（或 `PLANES=data,toolchain`），按 role 套用对应平面 bundle；角色可**幂等追加**。

---

## 3. 解耦原则（核心设计约束）

**5 条解耦轴**
1. 平面解耦：数据/工具链/集群/租户独立部署与生命周期。
2. 环境解耦：drill/prod/enterprise 用 profile（变量+overlay），核心清单不变。
3. Provider 解耦：存储/对象/网络/密钥/镜像源走"接口+适配器"。
4. 生命周期解耦：数据（宠物）vs 计算（牲畜）。
5. 厂商/云解耦：云特性只出现在 `overlays/` 或 adapter，核心清单零云依赖。

**6 个稳定接口（契约）与适配器**（避免过度抽象，只抽象这 6 个）

| 接口 | 契约 | 适配器示例 |
|---|---|---|
| 数据接入 | 端点 + 凭据 + 库/角色模型 | CNPG / 云 RDS |
| 备份出口 | **S3 兼容** endpoint+bucket+cred | MinIO / OSS / 任意 S3 |
| 存储 | SC 名 `app-storage` | Longhorn / 云盘 CSI |
| 暴露/发现 | stable DNS / global Service | Cilium ClusterMesh / LB+DNS |
| 供给 | `DatabaseClaim/RedisClaim` | Crossplane（CNPG / 云 Provider） |
| 身份 | Casdoor 组 → RBAC 映射 | Casdoor |

> 规则：**核心清单必须能在"任意合规 K8s + 任意 S3 + 任意 CSI"上运行**；云能力是可选优化。

---

## 4. CDM 客户交付成熟度阶梯（工具链独立成档）

| CDM | 客户拿到的 | 主要平面 | CI/CD 落点 |
|---|---|---|---|
| 1 单节点集群 | 可扩展底座（**是 K8s 集群，非 compose**） | 集群 | — |
| 2 工具链/管理面 | Harbor+GitLab/Runner+镜像管道 | 工具链(+数据) | **CI 首次交付** |
| 3 多节点生产集群 | CDM-1 的 scale-out | 集群 | — |
| 4 单集群多租户 | Mode A + 可观测 + 备份 | 租户(+工具链) | **CD 首次交付(GitOps)** |
| 5 RBAC 安全集群 | 策略准入/网络策略/审计 | 租户 | 强化（策略/签名/审批） |
| 6 安全全隔离 | Mode C（vCluster/独立控制面） | 租户 | 每租户独立流水线 |
| 7 开发者生态 | Backstage + Crossplane + 模板/runner 池 | 租户 | 产品化 |
| 8 开发者平台 | 身份/自助/计费/黄金路径收敛 | 全平面 | 黄金路径 |

> 安全拆两半：**安全精髓（PSA/隔离/配额/签名/密钥）在 CDM-2 就进入 L0/L1 基座**（不可逆）；
> **面向客户的安全档位** 在 CDM-5/6 成型。

---

## 5. 规模档位（S/M/L）

| 平面 | S（共享） | M（专用） | L（强隔离） |
|---|---|---|---|
| 数据 | 共享实例 + 独立库/角色 | 每应用/租户独立 CNPG 集群(HA) | 独立数据集群 / 托管实例 |
| 集群 | 单节点 | 3CP 多节点跨 AZ | 多集群 |
| 租户 | namespace | ns + 专用配额/节点池 | vCluster / 独立控制面 |
| 工具链 | 内嵌 | 内嵌 + 数据外置 | 独立管理集群 + 每集群 proxy cache |

---

## 6. 矩阵：Role × Plane（每格"入口条件 / 交付物 / 验收"）

> 下表示意骨架；完整逐格清单随各分册补充。

| Role \ Plane | 数据平面 | 工具链平面 | 集群平面 | 租户平面 |
|---|---|---|---|---|
| `workload` | 消费端点 | 消费 Harbor | **交付**：CNI/CSI/Gateway/节点池；验收：单节点↔多节点同契约 | 提供宿主 |
| `toolchain` | 消费数据端点 | **交付**：Harbor/GitLab/Runner/镜像管道/身份/可观测；验收：新集群零改造消费 | 消费底座 | — |
| `data` | **交付**：CNPG/Redis/对象存储/备份/供给抽象；验收：PITR + 恢复演练 | 为工具链提供数据 | 可独立部署(云无关) | — |
| `tenant` | 消费(按 profile) | 消费(镜像/CI/身份) | 消费底座 | **交付**：Mode A/B/C + 配额 + RBAC；验收：隔离 + 自助 |

---

## 7. 不可逆契约清单（构建前必须锁定）

1. 命名与隔离模型：镜像 scheme C、Harbor 单项目、租户命名、A/B/C 抽象。
2. 网络与入口：网段、VIP、`kube-api` 内网域名、Gateway 监听名（`https`）、通配证书策略。
3. 存储契约：SC 名 `app-storage`、`Retain`、扩容、快照类名。
4. 身份模型：Casdoor 组织/组 → 各系统 RBAC 映射表。
5. 数据层接口：库/角色/扩展/备份接口，按"可切专用集群"设计。
6. 备份接口：PITR(barman/S3) 与快照(Snapshotter) 的开关与命名。

---

## 8. 与现状映射（详见 implementation-status.md）

| 平面 | 已完成 | 差距 |
|---|---|---|
| 数据 | CNPG 三库 / Redis(StatefulSet) / MinIO | 同集群(D)、无 PITR/Snapshotter、无供给抽象 |
| 工具链 | Harbor / 镜像管道 / Chart OCI / GitLab / 可观测 | Runner、Casdoor OIDC、策略·密钥、外置化 |
| 集群 | 5 节点 HA、SC 契约 | 单/多节点同契约未显式验证、节点池/多集群 |
| 租户 | Mode A | Mode B/C、GitOps、自助 |

---

## 9. 交付优先级（P0→P3）
1. **P0**：数据面接口（Snapshotter + CNPG barman/PITR）｜身份映射 + Casdoor OIDC｜供应链/密钥（Kyverno/ESO/cosign）｜Velero。
2. **P1**：Flux GitOps（CD）+ CI Runner（CI）。
3. **P1**：可观测补齐（OTel、SLO 告警）。
4. **P2**：数据平面独立集群(B) + 跨集群消费（ClusterMesh/LB+DNS）+ 工具链外置。
5. **P3**：Mode C → Mode B（Backstage/Crossplane）→ 黄金路径。
