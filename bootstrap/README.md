# bootstrap/（引导）

一次性把集群接入 **Flux Operator（Helm 安装，对齐 D2 官方）**：

1. **镜像入 Harbor（scheme C）**：
   - operator 镜像：`harbor.test.baokuaiyun.com/baokuaiyun/fluxcd/flux-operator:v0.61.0`
   - 控制器镜像：`source/kustomize/helm/notification-controller`、`source-watcher`（Flux 分布清单所需）
   - distribution manifests 制品：`harbor.test.baokuaiyun.com/baokuaiyun/flux-operator-manifests:latest`
2. **安装 Flux Operator（Helm chart，走 Harbor OCI）—— 已封装为一键目标**：
   ```bash
   make flux-operator      # 或 make gitops（含 fleet 模式 FluxInstance + tenants ResourceSet）
   # 内部: platform/flux/install.sh（幂等）
   #   - 镜像/chart 从 GHCR_MIRROR 拉取后入 Harbor
   #   - 注入 Harbor CA + harbor-auth/cosign-pub
   #   - helm upgrade --install ... --take-ownership（收编旧清单安装，勿删 install.yaml）
   # 变量: FLUX_OPERATOR_VERSION=0.61.0 GHCR_MIRROR=ghcr.dockerproxy.net FLEET_MODE=all-in-one
   ```
   详见 `platform/flux/{install.sh,values.yaml}`（镜像走 Harbor、注入 CA、复用平台 Gateway 暴露 UI）。
3. **应用 `gitops/fleet/<mode>/flux-instance.yaml`**（sync = Harbor OCI + cosign 验签）。
4. 之后一切变更走 Git/OCI，不再手工 bootstrap。

详见 `docs/gitops-fleet.md`。
