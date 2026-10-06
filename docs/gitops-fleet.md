# GitOps Fleet（Flux Operator + OCI，D2 适配版）

> 目标：**集群模板化 + 快速升级/回滚**。采用 D2 参考架构的核心模式
> （Flux Operator + OCI Artifact + ResourceSet + cosign 验签），但适配本项目的
> **Harbor 单一源、离线、四平面/角色**模型。
> 关联：[`implementation-matrix.md`](implementation-matrix.md)、[`state-ledger.md`](state-ledger.md)、
> [`identity-mapping.md`](identity-mapping.md)、上游 `controlplaneio-fluxcd/d2-fleet`。

## 一、模型：单仓 + 组件优先 + 薄模式层

- **组件（components）只定义一次**（DRY），含 `base + overlays`（drill/prod/enterprise）。
- **集群模式（fleet modes）只做选择与参数**：`FluxInstance` + `ResourceSet inputs`。
- **绝不**为每个模式复制组件。

### 集群模式（定为 4 个）
| 模式 | 角色组合 | 用途 |
|---|---|---|
| `all-in-one` | workload+toolchain+data+tenant | drill / CDM-1-2 / 小客户 |
| `mgmt` | toolchain+data | 管理集群（Harbor/GitLab/身份/监控/数据） |
| `biz` | workload+tenant | 业务集群 |
| `data` | data | 独立数据集群(B) |

> 规模 S/M/L 与 CDM 档位用 `environment`/overlay 表达，**不新增模式**。

## 二、仓库结构

```
repo/
├── bootstrap/                 # 引导（kubeadm/terraform 适配）
├── fleet/                     # 每集群模式：薄 FluxInstance
│   ├── all-in-one/
│   ├── mgmt/
│   ├── biz/
│   └── data/
├── components/                # 共享组件（DRY）
│   ├── infra/    # cilium, longhorn, cert-manager, kgateway, monitoring, kyverno, sealed-secrets, velero
│   ├── platform/ # harbor, gitlab(+runner), casdoor, external-secrets
│   ├── data/     # cnpg, redis, object-store, crossplane
│   └── apps/     # 平台/演示应用
├── tenants/                   # 租户 ResourceSet（Mode A/B/C）
└── profiles/                  # 规模/环境变量（drill/prod/enterprise）
```

## 二.1 叠加（stack）与单独（standalone）

**同一套机制**：`stack` = "单元集合"，集合大小 1 = 单独，>1 = 叠加。

- **layer**（`gitops/fleet/layers/<layer>/components.yaml`）：可组合 bundle。
  `core / data / platform / observability / gitlab`（可增删）。
- **集群叠加栈**（`gitops/fleet/clusters/<cluster>/stack.yaml`）：声明 `type/env/stack[]/overrides`。
- **解析/导入**：`FLEET_MODES=core,data`（逗号=叠加；单个=单独）→ **并集+去重+类型过滤** →
  `gitops/locks/<units排序+连接>-<env>-<type>.lock`。
  ```bash
  make resolve-artifacts FLEET_MODES=core,data FLEET_ENV=drill CLUSTER_TYPE=all
  make sync-artifacts    FLEET_MODES=core,data FLEET_ENV=drill CLUSTER_TYPE=all
  make resolve-artifacts FLEET_MODE=all-in-one            # 单独（预设）
  ```
- **单独集群（不用 Flux）**：`ENABLE_FLUX=false` → `bootstrap/member/standalone.sh`（脚本/Operator 管理）。
- `all-in-one` 保留为"全部层"的预设（≈叠加所有 layer）。

### stack → ResourceSet（真实渲染，已实现）
- `bootstrap/render-stack.sh <units> <env> <type> [--apply]`：按 stack 组件集生成 `ResourceSet/stack`，
  为每个组件渲染：Namespace、`flux` SA+RBAC、`harbor-auth`/`cosign-pub` 复制、`OCIRepository`(insecure+verify cosign)、`Kustomization`(path `./overlays/<env>`)。
- **仅纳入"部署组件"**（本地有 `overlays/<env>`）且**制品已构建**（`oras` 检测）；无则跳过。
- `bootstrap/build-component.sh <plane>/<name> [tag] --push --sign`：把组件目录 `base/ + overlays/` 打包为 OCI 制品 + cosign 签名。
- 命令：
  ```bash
  make build-component C=apps/demo SIGN=--sign      # 打包组件制品
  make render-stack FLEET_MODES=demo                # 生成并 apply ResourceSet/stack
  make gitops FLEET_MODE=all-in-one                 # FluxInstance + stack 渲染
  ```
- 示例组件 `gitops/components/apps/demo`（安全验证全链路：stack→ResourceSet→OCIRepository(验签)→Kustomization→ConfigMap）。

### 真实组件纳管（示例：cert-manager，已接管）
- 组件补 `base/`（Flux `OCIRepository`(Harbor chart) + `HelmRelease`）+ `overlays/<env>/`。
- HelmRelease `releaseName` 与现有 release 对齐 → **Flux 接管**（如 `cert-manager`）。
- 多租户下 HelmRelease 需集群级权限 → 渲染器为组件的 `flux` SA 加 **ClusterRoleBinding(cluster-admin)**。
- 结果：`HelmRelease/cert-manager` Ready、证书正常；`gitops/components/infra/cert-manager`。

### CI（GitLab）：组件改动 → 自动出制品
- `.gitlab-ci.yml`：push 命中 `gitops/components/**` 时，用 `BUILD_IMAGE`（含 git/tar/oras/cosign）跑 `bootstrap/ci-build-components.sh`。
- 脚本按 diff 找出改动的组件目录 → `build-component --push --sign`。
- 构建工具镜像：`bash ci/build-tools.sh`（`ci/tools.Dockerfile` + skopeo 推 Harbor）。
- 需在 GitLab 配置 CI 变量：`HARBOR_*`、`COSIGN_KEY_B64`、`COSIGN_PASSWORD`；并注册 Runner。

## 三、交付流（Git → CI → OCI → Flux）

```
Git(本仓 components/*) ──CI(GitLab Runner)──▶ OCI Artifact: oci://harbor/baokuaiyun/<component>:<tag>
                                                 └ cosign 签名(key-based)
fleet/<mode>/FluxInstance ── sync ──▶ OCI Artifact(集群期望态)
        └ ResourceSet inputs{tenant, tag, environment}
              → OCIRepository(verify: cosign) + Kustomization(path ./overlays/<env>)
```

### FluxInstance（每集群模式，节选）
```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata: {name: flux, namespace: flux-system}
spec:
  distribution:
    version: "2.x"
    registry: harbor.test.baokuaiyun.com/baokuaiyun/fluxcd   # 控制器镜像（Harbor）
    artifact: oci://harbor.test.baokuaiyun.com/baokuaiyun/flux-operator-manifests:latest
  components: [source-controller, kustomize-controller, helm-controller, notification-controller]
  cluster:
    type: kubernetes
    size: small            # drill
    multitenant: true
    tenantDefaultServiceAccount: flux
    networkPolicy: true
    domain: cluster.local
  sync:
    kind: OCIRepository
    url: oci://harbor.test.baokuaiyun.com/baokuaiyun/fleet
    ref: latest            # drill；prod 用 latest-stable
    path: fleet/all-in-one
    pullSecret: harbor-auth
  kustomize:
    patches:
      - target: {kind: OCIRepository, name: flux-system}
        patch: |
          - op: add
            path: /spec/verify
            value:
              provider: cosign
              secretRef: {name: cosign-pub}   # key-based（离线）
```

### ResourceSet（组件模板，节选）
```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata: {name: infra, namespace: flux-system}
spec:
  inputs:
    - {tenant: cert-manager, tag: "${ARTIFACT_TAG}", environment: "${ENVIRONMENT}"}
    - {tenant: monitoring,   tag: "${ARTIFACT_TAG}", environment: "${ENVIRONMENT}"}
  resources:
    - apiVersion: source.toolkit.fluxcd.io/v1
      kind: OCIRepository
      metadata: {name: infra, namespace: "<< inputs.tenant >>"}
      spec:
        url: "oci://harbor.test.baokuaiyun.com/baokuaiyun/<< inputs.tenant >>"
        ref: {tag: "<< inputs.tag >>"}
        verify: {provider: cosign, secretRef: {name: cosign-pub}}
    - apiVersion: kustomize.toolkit.fluxcd.io/v1
      kind: Kustomization
      metadata: {name: infra-controllers, namespace: "<< inputs.tenant >>"}
      spec:
        sourceRef: {kind: OCIRepository, name: infra}
        path: "./controllers/<< inputs.environment >>"
        prune: true
```

## 四、升级 / 回滚（"快速升级"）
- **Flux 自身**：改 `FluxInstance.spec.distribution.version` → Flux Operator 自升级。
- **组件**：drill 用 tag `latest`；prod 用 `latest-stable` 指针。
  - 晋升：把组件 OCI 打 `vX.Y.Z` 再把 `latest-stable` 指向它。
  - 回滚：`flux tag oci://harbor/baokuaiyun/<component>:vX.Y.Z --tag latest-stable`。
- **集群模式**：改 `fleet/<mode>` 的 `FluxInstance`（提交 Git）即收敛。

## 五、与 D2 的差异（适配点）
| D2 原版 | 本项目 |
|---|---|
| GHCR | **Harbor**（单一源） |
| cosign keyless(GitHub OIDC) | **key-based cosign**（离线）；生产可换 GitLab OIDC |
| 三仓（fleet/infra/apps） | **单仓**（组件优先 + 薄模式；CODEOWNERS/CI paths 模拟隔离） |
| Terraform 引导 | kubeadm/Makefile 引导 |
| 云集群 | KVM drill / 云 prod 同契约 |

## 六、安全/隔离
- 组件 OCI 全部 **cosign 验签**（Flux `verify`）；infra 组件 SA 绑定 cluster-admin 需与 **Kyverno/PSA** 协调。
- Flux `multitenant: true` + per-tenant SA；租户组件不得越权。
- CI 产出制品经 **Trivy 扫描 + cosign 签名**后才可被 prod `latest-stable` 采用。

## 六.1 安装与查看 Flux Operator（对齐 D2 官方：Helm）
- **安装方式**：**Helm**（chart `controlplaneio-fluxcd/charts/flux-operator` 0.61.0 ↔ 镜像 v0.61.0），
  chart 经镜像源拉取后推入 Harbor，`helm upgrade --install ... -f platform/flux/values.yaml`；
  若既有清单安装，用 **`--take-ownership`** 就地收编。
- **命名空间**：`flux-system`（不是 `flux-operator`）。Helm release 名 `flux-operator`。
- **Operator**：`deployment/flux-operator`（Helm 管理；镜像 `harbor.../baokuaiyun/fluxcd/flux-operator:v0.61.0`）。
- **控制器**：`source-controller / kustomize-controller / helm-controller / notification-controller`（由 FluxInstance 铺出）。
- **Web UI**：`https://flux.test.baokuaiyun.com`（chart `web.httpRoute` → `svc/flux-operator:9080`）；
  chart `web.networkPolicy` 放行 9080 入站。
- 命令：
  ```bash
  helm -n flux-system list
  kubectl -n flux-system get deploy,pods
  kubectl get fluxinstance,resourceset,fluxreport -A
  ```

## 七、落地步骤（已有一键目标）
```bash
make flux-operator     # 安装/升级 Flux Operator（Helm；chart+镜像走 Harbor；--take-ownership）
make gitops            # = flux-operator + apply fleet/<mode>/flux-instance.yaml + tenants/infra.yaml
# 变量: FLUX_OPERATOR_VERSION=0.61.0 GHCR_MIRROR=ghcr.dockerproxy.net FLEET_MODE=all-in-one
```
实现：`platform/flux/install.sh`（幂等）+ `platform/flux/values.yaml`。
剩余：
1. CI（GitLab Runner）把 `components/<x>` 打包为 OCI 到 Harbor + cosign 签名（替代手工）。
2. 先纳管 `cert-manager`、`monitoring` 作 `ResourceSet` 样板，再扩展。
3. 扩展 `mgmt/biz/data` 模式；`latest-stable` 晋升/回滚演练。
