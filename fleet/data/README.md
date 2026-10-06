# 集群模式：data

- 该模式仅声明 **FluxInstance（薄）** + 启用的 `ResourceSet`，不内联组件实现。
- 组件来自 `components/`（OCI 制品），参数经 `inputs{tag, environment}` 传入。
- 参考 `fleet/all-in-one/flux-instance.yaml`，按模式调整 `cluster.{size,roles}` 与启用组件。

对应四平面角色：见 `docs/implementation-matrix.md`。
- mgmt = toolchain + data
- biz  = workload + tenant
- data = data（独立数据集群 B）
