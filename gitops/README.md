# gitops/ —— Flux 期望态与配置（未来可独立成库）

> 本目录是**GitOps 期望态/配置**的独立目录，与 `docs/`、`Makefile`、引导脚本（`bootstrap/`）分离。
> 未来可整体拆为**独立的 gitops 库**（自包含：只依赖外部 Harbor/Git 端点，不引用本仓其它文件）。

## 目录
```
gitops/
├── fleet/        # clusters/<cluster>/{flux-instance,stack}、layers/<layer>/
├── components/    # <plane>/<name>/component.yaml（组件声明：type/images/artifacts）
├── tenants/       # 租户 ResourceSet
├── roles/         # 集群定位骨架
├── planes/        # 平面 bundle 骨架
├── profiles/      # 环境/规模变量（drill/prod/enterprise）
├── repo-split.yaml# 分仓骨架（未来拆分依据）
└── settings.md    # 参数精简说明（完整见 docs/parameters.md）
```

## 用法
```bash
# 解析某模式制品 -> gitops/locks/<mode>-<env>-<type>.lock
make resolve-artifacts FLEET_MODE=all-in-one FLEET_ENV=drill CLUSTER_TYPE=all
# 检测式按需导入 Harbor（+签名）
make sync-artifacts    FLEET_MODE=all-in-one FLEET_ENV=drill CLUSTER_TYPE=all
# 安装 Flux + 接入模式
make gitops FLEET_MODE=all-in-one
```

## 边界
- **本目录（gitops/）**：Flux 期望态（fleet/components/tenants/layers）与配置（profiles）。
- **bootstrap/**：引导面命令式脚本（引导集群核心/数据/Harbor/Flux），**留平台仓**，避免跨仓耦合。
- **apps/**：应用/持续开发（未来独立"开发仓"）。
- 详见 [`../docs/repo-topology.md`](../docs/repo-topology.md) 与 [`../docs/gitops-fleet.md`](../docs/gitops-fleet.md)。

## 未来独立成库
- `gitops/` 自包含，可直接提升为独立仓库；CI 打包为 OCI 制品（如 `oci://harbor/baokuaiyun/fleet`），Flux 消费。
- 拆分按 [`repo-split.yaml`](repo-split.yaml) 执行。
