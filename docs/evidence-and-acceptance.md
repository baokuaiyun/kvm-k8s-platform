# 验收与证据（Definition of Done → Proof）

> 目的：把"**证明**"作为一等公民。每个平面的 DoD 不只是"装完"，而是**可复现、可追溯的验收证据**。
> 关联：[`plane-dod.md`](plane-dod.md)、[`implementation-status.md`](implementation-status.md)、
> [`state-ledger.md`](state-ledger.md)、[`environment-differences.md`](environment-differences.md)。

## 一、原则

1. **验收即代码**：每个平面一条 `make verify-<plane>`，可重复执行、退出码即结论。
2. **同构证明**：同一套验收在 `drill` 与 `prod` **各跑一次**，证据对比体现"仅 env/config 差异"。
3. **针对制品摘要**：证据记录 git commit + 制品 lock `sha256`（+ 镜像 digest），验收对象可追溯。
4. **证据入库**：`make evidence` 产出 `evidence/<env>/<ts>/`（report.json/md + 原始日志）。

## 二、证据模型

一条证据 = **命令 + 输出 + 退出码 + 环境 + git commit + 时间（+ 制品摘要）**。

```bash
make evidence                 # ENV=drill，默认检查集
make evidence ENV=prod        # 生产环境同套检查
make evidence CHECKS="nodes storage_verify"
```

产物：

| 文件 | 内容 |
|---|---|
| `report.json` | env / timestamp / git_commit / git_dirty_files / k8s_server_version / domain / storage_backend / artifact_lock_sha256 / summary / results[] |
| `report.md` | 人读摘要（pass/fail 表）|
| `<check>.log` | 各检查原始输出 |

默认检查集：`nodes`、`storage_class`、`csi`、`snapshot_class`、`storage_verify`、`helm`。

## 三、与 DoD 的关系

[`plane-dod.md`](plane-dod.md) 要求"功能 + 可靠性 + 安全 + 可观测 + 文档 + **验收命令通过**"。
本文补上**证据产出**：

- 集群平面：`make evidence`（nodes/sc/单→多契约）。
- 数据平面：`make evidence CHECKS="... data_verify"`（端点可达 + PITR/恢复演练 + 备份时效）。
- 工具链平面：Harbor/GitLab/身份/可观测的检查。
- 租户平面：隔离用例 + 自助开通 + 配额/PSA。

## 四、DR / 演练证据

以下演练也纳入证据（DoD"演练过"）：

```bash
make drill-expand-pvc                 # 云盘在线扩容 1→3Gi 数据无损
bash scripts/restore-etcd.sh <snap>   # etcd 恢复
make app-restore APP=pg               # CNPG PITR 恢复
```

## 五、用途

- **交付证明**：给评审/客户的"证明"（git commit + 制品摘要 + 逐项结果）。
- **回归**：变更后重跑，证据对比即回归报告。
- **同构核验**：drill 与 prod 的 `report.json` 对比。

## 六、现状

- 已实现：`scripts/evidence.sh` + `make evidence`；`verify-storage` 等命令。
- 待补（见 `plane-dod.md` 标"拟"的）：`verify-data`/`verify-tenant` 等；prod 环境证据。
