# 平面 Bundle 骨架（planes/）

> 说明：本目录为**骨架/模板**，尚未接入 Makefile。目标是把四平面清单按"可安装 bundle"收拢，
> 使集群可按 `CLUSTER_ROLE` 选择要套用的平面。规划见
> [`docs/implementation-matrix.md`](../docs/implementation-matrix.md)。

```
planes/
├── data/         # 数据平面：CNPG / Redis / 对象存储 / 备份 / 供给抽象
├── toolchain/    # 工具链：Harbor / GitLab / Runner / 镜像管道 / Casdoor / 可观测 / 策略·密钥
├── workload/     # 集群平面：CNI / CSI / Gateway / 节点池
└── tenant/       # 租户平面：Mode A/B/C / 配额 / RBAC / 自助
```

## 与现有目录的关系
初期不搬动现有目录，仅用**软引用/文档**表达归属（见 `roles/README.md` 映射表）。
待 Makefile 引入 `CLUSTER_ROLE`/`PLANES` 后，再把各平面清单逐步迁入本目录。

## Bundle 约定（规划）
- 每个 `planes/<plane>/` 含 `install.sh`（幂等）与 `README.md`。
- 通过 `__占位__` + variables/profiles 渲染，保持环境无关。
- 平面之间只通过**稳定接口**（见 implementation-matrix §3）交互，不直接依赖彼此内部资源。
