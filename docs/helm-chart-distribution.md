# Helm Chart 分发：Codeup Git →（阶段 3）Harbor/GitLab 制品

> 结论先说：
> - **ACR 个人版**不支持 OCI Helm；
> - **云效制品仓库**也不支持 Helm 仓库（OpenAPI 支持类型仅 GENERIC/DOCKER/MAVEN/NPM/NUGET）；
> - 引导期用 **云效 Codeup Git** 托管 chart；集群起来后再迁到 **Harbor OCI / GitLab 制品**。

## 一、分发通道对比

| 通道 | 说明 | 阶段 |
|---|---|---|
| **A. Codeup Git（引导期，推荐）** | `git clone` 本地目录 → `helm install ./charts/x` / `helm package` | Phase 0/1 |
| **B. 本地 vendor** | `.tgz` 存宿主机 `HELM_CHARTS_DIR`，离线安装 | 任意 |
| **C. Harbor OCI Helm** | `helm push oci://harbor.../k8s-library`，Harbor 原生支持 | Phase 3 |
| **D. GitLab Package Registry(Helm)** | GitLab 自带 Helm 仓库 | Phase 3 |

## 二、方案 A：Codeup Git（当前默认）

### 2.1 仓库
在云效 **Codeup** 的 **`baokuaiyun` 分组**下建仓库 `helm-charts`：
`https://codeup.aliyun.com/68b10df1e3894fcaacb7b8db/baokuaiyun/helm-charts.git`

> 组织里已有 `tekton/helm-charts` 可参考/复用；按“分组统一 baokuaiyun”建议新建于 `baokuaiyun` 分组。

### 2.2 变量（`acr.env`）
```bash
HELM_GIT_URL=https://codeup.aliyun.com/<orgId>/baokuaiyun/helm-charts.git
HELM_GIT_USER=<云效账号邮箱>
HELM_GIT_TOKEN=pt-xxxxxxxx          # 个人访问令牌
HELM_GIT_REF=main
HELM_GIT_DIR=/data/kvm/helm-charts
HELM_CHARTS_DIR=/data/kvm/charts    # helm package 产物
```

### 2.3 拉取 / 安装
```bash
make charts-pull      # = git clone 到 HELM_GIT_DIR，再 helm package 到 HELM_CHARTS_DIR
# 若仓库尚空/不存在，脚本会提示并回退上游拉取
make charts-push-git  # 把本地 HELM_CHARTS_DIR 的 tgz 推回 Codeup Git
```

`Makefile` 的 `cni/storage/cert` 会自动优先用 `HELM_CHARTS_DIR/*.tgz`。

### 2.4 chart 结构约定
仓库里每个 chart 一个目录（含 `Chart.yaml`），`charts-pull` 会 `find Chart.yaml` 后逐个 `helm package`。示例：
```
helm-charts/
├── cilium/
├── longhorn/
└── cert-manager/
```

## 三、方案 B：本地 vendor（离线）

```bash
make charts-pull                 # 若上游可达，也可 helm pull 上游
ls $(HELM_CHARTS_DIR)/*.tgz
# 或手动: helm pull <repo>/<chart> --version <v> -d $(HELM_CHARTS_DIR)
```
`cni/storage/cert` 检测到本地 tgz 即离线安装，无需 chart 仓库。

## 四、阶段 3 演进

### Harbor OCI Helm（推荐，统一制品）
```bash
helm registry login harbor.${DOMAIN} -u <robot> -p <token>
helm push $(HELM_CHARTS_DIR)/cilium-1.16.0.tgz oci://harbor.${DOMAIN}/k8s-library
helm install cilium oci://harbor.${DOMAIN}/k8s-library/cilium --version 1.16.0
```
镜像 + OCI chart 都在 Harbor，单一来源。

### GitLab Package Registry(Helm)
```bash
helm repo add gitlab https://gitlab.${DOMAIN}/api/v4/projects/<id>/packages/helm/stable --username <user> --password <token>
helm cm-push $(HELM_CHARTS_DIR)/cilium-1.16.0.tgz gitlab
```

## 五、变量表

| 变量 | 说明 |
|---|---|
| `HELM_GIT_URL/USER/TOKEN/REF/DIR` | Codeup Git 源（引导期） |
| `HELM_CHARTS_DIR` | 本地 tgz 目录（Makefile 优先消费） |
| `HELM_REPO_*` | 旧（云效制品仓库），保留占位 |
| `HELM_CILIUM/LONGHORN/CERTMGR` | 自动解析本地 tgz 或上游查询 |

## 六、验证

```bash
make yunxiao-repos TYPE=codeup     # 列 Codeup 代码库（确认 helm-charts）
make charts-pull                   # 应生成 $(HELM_CHARTS_DIR)/*.tgz
helm show chart $(HELM_CHARTS_DIR)/cilium-1.16.0.tgz
```

## 七、FAQ

- **云效制品仓库能推 Helm 吗？** 不能（无 HELM 类型）。用 Codeup Git 或 Harbor OCI。
- **git clone 401？** 检查 `HELM_GIT_USER`（需 URL 编码邮箱）与 `HELM_GIT_TOKEN`。
- **仓库为空？** 先按 §2.4 结构推入 chart，或让脚本回退上游。
- **镜像怎么办？** 见 [`acr-image-sync.md`](acr-image-sync.md)；chart 的 values 已用 `__IMAGE_REPOSITORY__` 指向本域镜像。
- **统一登录？** 见 [`identity-sso-casdoor.md`](identity-sso-casdoor.md)。
