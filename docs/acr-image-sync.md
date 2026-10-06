# ACR 镜像同步（源）→ 本域镜像 → 本域初始化集群

> 核心原则：**在 `kubeadm init` 之前，宿主机先把镜像准备好并重命名成本域镜像，导入各节点；再以本域镜像仓库名初始化集群。**
> ACR 只是宿主机侧的**下载源**；集群运行时用的是本域镜像名。

## 一、为什么这样做

- 国内直连 `registry.k8s.io` / `quay.io` / `ghcr.io` 不稳定，`kubeadm init` 拉镜像易超时。
- 生产环境不适合在宿主机跑 Harbor（不可长期依赖），故**不预置 Harbor**。
- 于是：宿主机从 ACR 拉 → 重命名成本域名 → 预载进节点 containerd → init 命中本地（不回源）。
- Harbor 上线后（阶段 3），把**同名**本域镜像推入 Harbor，影子 tag 变真名，后续重启/扩容/GC 才能正常拉取。

```
ACR(源) ──skopeo──> 宿主机 tar(本域名) ──scp/ctr──> 各节点 containerd(k8s.io)
                                                        │
                                          kubeadm init --image-repository=<本域>
```

## 二、命名规则

- 本域前缀：`IMAGE_REPOSITORY = $(HARBOR_HOST)/$(HARBOR_PROJECT)`
  - 演练：`harbor.test.baokuaiyun.com/k8s-library`
  - 生产：`harbor.baokuaiyun.com/k8s-library`
- **核心（kubeadm 用，压平为 basename）**：
  `kube-apiserver`、`kube-controller-manager`、`kube-scheduler`、`kube-proxy`、`coredns`、`etcd`、`pause`
  > 注意 kubeadm 会把 coredns 压平为 `<repo>/coredns`，**不是** `<repo>/coredns/coredns`。
- **平台 / Helm（全路径 `/` 换 `.`）**：`quay.io/cilium/cilium` → `<本域>/quay.cilium.cilium:v1.16.0`
- kube-vip：`<本域>/kube-vip:v0.8.7`（并改写静态 Pod 清单镜像）

## 三、变量与凭据

`variables.mk`（可被 `acr.env` / 环境变量覆盖，禁止硬编码）：

| 变量 | 说明 |
|---|---|
| `ACR_REGISTRY` | ACR 地址（默认 `crpi-adznwq8xa40ei174.cn-hangzhou.personal.cr.aliyuncs.com`） |
| `ACR_NAMESPACE` | ACR 仓库命名空间（默认 `baokuaiyun`） |
| `ACR_AUTH_MODE` | `password` / `ak` / `none` |
| `ACR_USER` / `ACR_PASS` | ACR 用户名/密码（放 `acr.env`，不提交） |
| `ACR_SOURCE` | `auto`（先 ACR，缺失回退上游）/ `acr` / `upstream` |
| `IMAGE_REPOSITORY` | 本域前缀 |
| `IMAGE_CACHE_DIR` | 宿主机 tar 缓存目录（默认 `/data/kvm/images/registry`） |

凭据文件：

```bash
cp acr.env.example acr.env   # acr.env 已在 .gitignore
vim acr.env                  # 填真实 ACR_USER / ACR_PASS
```

`ACR_AUTH_MODE` 说明：

| 模式 | 命令作用 |
|---|---|
| `password` | `skopeo --src-creds "$ACR_USER:$ACR_PASS"` / `docker login` |
| `ak` | 复用 `ALIYUN_ACCESS_KEY/SECRET_KEY` |
| `none` | 公共源，不带凭据 |

## 四、镜像分层（Tier）

| Tier | 内容 | 说明 |
|---|---|---|
| **Tier0** | k8s 核心 + pause + **kube-vip** + **Cilium** | 不齐集群起不来 |
| **Tier1** | Longhorn + cert-manager | 阶段 1 的 storage/cert 验收 |
| **Tier2** | 监控 / 可观测 / Operator / 工具 | 阶段 2/3，按需 |

清单文件：`registry/images/`（格式 `<源> <本域仓库后缀> <Tier> [<ACR源后缀>]`）。

## 五、执行流程（Phase 0，必须在 init 前完成）

```bash
# 0. 准备凭据
cp acr.env.example acr.env && vim acr.env

# 1. 宿主机：从 ACR/上游拉取 + 重命名 + 导出 tar（默认 Tier0,Tier1）
make acr-prepare
#    自定义: make acr-prepare TIERS=Tier0,Tier1,Tier2
#    强制重拉: make acr-prepare FORCE=1
#    产物: $(IMAGE_CACHE_DIR)/*.tar 与 manifest.tsv

# 2. 分发导入各节点 containerd（起步节点）
make image-load

# 3. 预检（缺一即失败，阻止 init）
make image-preflight

# 4. 部署 kube-vip + 初始化控制面（本域 image-repository）
make kube-vip
make k8s-init

# 5. 加入 worker
make k8s-join
```

`make phase1` 已内置上述顺序：
`init → vm-create → acr-prepare → k8s-common → image-load → image-preflight → kube-vip → k8s-init → k8s-join → cni → storage → cert`

## 六、Helm chart 镜像（与镜像同一逻辑）

> 注意：**ACR 个人版不支持 OCI Helm**（chart 本身不能推 ACR）。
> chart 模板的分发走 **云效制品仓库 / 本地 vendor** → 见 [`helm-chart-distribution.md`](helm-chart-distribution.md)。
> 本节只讲 chart 里**容器镜像**如何进本域。

chart 的镜像写在模板里，需**用 values 覆盖成本域名**，再走同一套「下载→重命名→预载」：

1. 提取 chart 镜像清单并追加到 `registry/images/`：
   ```bash
   make helm-images RELEASE=cilium CHART=cilium/cilium
   ```
2. 覆盖 values（本仓库已提供，`__IMAGE_REPOSITORY__` 由 Makefile 用 `sed` 注入）：
   - `kubernetes/configs/cilium-values.yaml`
   - `kubernetes/configs/longhorn-values.yaml`
   - `kubernetes/configs/cert-manager-values.yaml`
   - `kubernetes/configs/redis-operator-values.yaml`（阶段 3 · `make operators`）
   - `kubernetes/configs/cloudnative-pg-values.yaml`（阶段 3 · `make operators`）
   - `kubernetes/configs/harbor-values.yaml`（阶段 3 · `make platform`，外部 PG/Redis）
   - `kubernetes/configs/gitlab-values.yaml`（阶段 3 · `make platform`，外部 PG/Redis）
3. 重新 `make acr-prepare TIERS=Tier0,Tier1,Tier2 && make image-load && make image-preflight`。

> Operator 的**运行时镜像**（Redis / PostgreSQL 实例）不在 chart 里，由 CR 的
> `spec.*.image` / `spec.imageName` 指定，见 `registry/images/` Tier2。

## 七、阶段 3 闭环（影子 tag → 真名）

Harbor 上线后，把同名本域镜像推入 Harbor（复用 `registry/download-images.sh` 思路），此后：

- 节点可正常从本域仓库拉取（重启/扩容/GC 不再依赖预载）。
- 建议给 Harbor 配置 `proxy-*` 项目回源上游，未预载镜像按需缓存。

## 八、验证

```bash
# 宿主机：校验 tar 内镜像
skopeo inspect docker-archive:$(IMAGE_CACHE_DIR)/<file>.tar

# 节点：确认本域镜像存在
ssh k8s-cp-1 "ctr -n k8s.io images ls | grep ${HARBOR_HOST}"

# 集群内
kubectl get nodes
kubectl get pods -A | grep -iE 'ImagePull|ErrImage'
```

## 九、风险与注意

- **空窗期**：Harbor 起来前，节点重启/扩容/镜像 GC 会因拉取不到本域镜像而失败。建议：
  - 窗口内不要重启/新增节点；
  - 调高 kubelet `imageGCHighThresholdPercent` / `imageGCLowThresholdPercent`；
  - `containerd` 的 `k8s.io` 命名空间镜像尽量不被驱逐。
- **ACR 配额**：personal 版需能容纳核心+CNI+存储镜像（约 10–20GB）。
- **Tag 一致性**：清单 tag 必须与 chart 默认 tag 一致，否则需同步改 values。
- **版本升级**：chart/组件升级可能改镜像名，重跑 `make helm-images` 更新清单。
- **安全**：`acr.env` 勿提交；节点 containerd 若配置 ACR 认证，注意文件权限。

## 十、实测修复（1CP+1W 验证）

- **ACR 凭据只应作用于 ACR 源**：曾把 `--src-creds` 加到所有源，导致 quay/1ms 镜像 copy 认证失败。现仅当源为 `${ACR_REGISTRY}` 时才带凭据。
- **国内镜像重写**：`registry.k8s.io → 阿里云 google_containers`、`ghcr.io → ghcr.nju.edu.cn`、`docker.io → docker.1ms.run`、`quay.io → quay.m.daocloud.io`（可用 `MIRROR_*=...` 覆盖）。
- **直连**：`BYPASS_PROXY=1`（默认）时脚本 `no_proxy=*` 直连，规避宿主代理导致的国外站点 TLS 失败。
- **版本以 chart/kubeadm 为准**：
  - `kubeadm config images list` 决定核心镜像 tag（1.31 的 `pause` 是 **3.10**）；
  - Cilium `hubble-ui`/`hubble-ui-backend` 是 **v0.13.1**（非 v1.16.0），并需 `cilium-envoy`；
  - operator 预载名 `quay.cilium.operator-generic`，但 values 里 repository 要用 `.../operator`（chart 会补 `-generic`）；
  - Longhorn CSI 侧车 tag 以 chart `values` 为准（如 `csi-provisioner:v4.0.1`）。
- **镜像分发目录**：节点 `/tmp` 常为 2G tmpfs，导入用 `/var/lib/k8s-images`。
