# apps/（开发仓占位：应用与持续开发）

> 现状：本目录为**占位**，预留"开发仓"边界。平台仓管底座与交付机制；应用（持续开发）放这里，
> 生产时迁至**独立 Git 仓**（见 `docs/repo-topology.md`、`repo-split.yaml`）。

## 约定（应用侧）
- 每个应用一个目录：`apps/<app>/`，含 `base/` + `overlays/{drill,prod,enterprise}/`。
- CI 将应用打包为 OCI 制品：`oci://harbor.baokuaiyun.com/baokuaiyun/<app>:<tag>` 并 cosign 签名。
- 通过平台提供的 **ResourceSet 契约**接入：`{ tenant, tag, environment, layer }`。
- **不复制**平台租户基线（namespace/quota/RBAC/NetPol）——只引用参数。

## 归属
- owner：`@app-teams`（见 `CODEOWNERS`）。
- 分仓触发：持续开发启动 / 多团队 / 权限隔离。
