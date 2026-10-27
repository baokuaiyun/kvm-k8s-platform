# llm-governance —— LLM 治理城市（GitOps）

本组件创建**独立的治理城市 `gov`**，由城市内的 orders+formulas 完成 LLM 治理开发，
**不在任何交互会话中执行**。变更全部经 Flux（GitOps）落地。

## 组成
- `base/gascity.yaml`：`GasCity` CR（namespace `gc-gov`，cityName `gov`）。
  - provider：`codebuddy`（直连）+ `opencode-platform`（经 LiteLLM 网关，逻辑模型名）。
  - **`spec.packs`（operator 能力选装）**：core / bd / gascity roles / llmgov，渲染为 city.toml
    `[imports.*]`，启动时 `gc import install` 落 `packs.lock`。这是本次 gc-operator 新增的能力：
    能力按 pack 声明式加载，新增工作流 = 新 pack + CR 加一条，无需改 operator/镜像。
  - rig：`llm-governance`（prefix `llmgov`）。
  - workspace：指向治理 pack 仓库，检出到 `/city/workspaces/llm-governance/...`；
    `sources[].git.secretRef` 支持私有库（Secret 提供 `ssh-privatekey` 或 `username`/`password`）。
  - `rigWorkspaceBindings`：把 rig 绑到该工作区。
- `overlays/{drill,prod,enterprise}`：环境化资源/存储。

## 依赖：增强版 gc-operator
本组件使用以下 gc-operator 增强（`/root/gc-operator`，镜像 `gascity/operator:packs-gov`）：
- `spec.packs[]` → `city.toml [imports.*]`；
- `workspaces[].sources[].git.secretRef` → clone 凭证注入；
- controller entrypoint 启动前 `gc import install`（与 Helm chart 同步，保持 parity）。
CRD 已重新生成（`config/crd/bases/...gascities.yaml`）。上线需先升级 operator 到含这些改动的镜像/CRD。

## 治理 pack（rig 工作区仓库）
仓库根须为 gascity pack：`pack.toml` + `orders/` + `formulas/` + `agents/`。
当前脚手架位于本机 `/root/llm-governance-pack`（校验 `gc lint .` 通过），
需推送到 `gascity.yaml` 中 `workspaces[].sources[].git.url` 指定的仓库。

## 三层治理（由 pack 的 orders/formulas 驱动）
1. 自定义模型目录 —— `model-catalog` formula。
2. 平台模型自动切换 —— `gateway-fallbacks` formula（网关别名/降级/熔断）。
3. 收费治理 —— `budget-governance` formula（team/key 预算、限流、计费、告警）。
另：`audit` order 每日巡检（默认关闭）。

## 操作TODO（上线前）
- [ ] 创建并推送治理 pack 仓库；把 `base/gascity.yaml` 的 `url` 改成实际地址并固定 `revision`。
- [ ] 部署 LiteLLM 网关组件（`component: platform/litellm`，见治理第 2/3 层 PR）。
- [ ] 确认 `providers.open...`/`opencode-platform` 的 base_url/api_key 由网关 Secret 注入。
- [ ] 网关就绪后，在 `gov` 城市里 `gc order run model-catalog|gateway-fallbacks|budget-governance`
      驱动三个治理 PR；合并后开启 `orders/audit.toml`。
- [ ] 灰度：先只让 `gov` 城市接网关，再迁移其它城市。

## 校验
```
kubectl kustomize gitops/components/agent/llm-governance/overlays/drill
kubectl kustomize ... | kubectl apply --dry-run=client -f -
```
