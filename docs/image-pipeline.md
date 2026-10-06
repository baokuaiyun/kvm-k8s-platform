# 镜像管道：源 → 本域 Harbor

> 本文取代 `acr-image-sync.md`。核心：**引导期用影子镜像把 Harbor 带起来，之后所有镜像一律走 Harbor**（弃用 ACR）。
> Harbor 单项目 **`baokuaiyun`（私有）**，robot 账号 **`pushpull`**；admin/robot 密码放 `acr.env`（gitignored）。

## 一、命名规则（scheme C）

镜像引用 = `$(HARBOR_HOST)/$(HARBOR_PROJECT)/<flat>:<tag>`，例：`harbor.test.baokuaiyun.com/baokuaiyun/goharbor-harbor-core:v2.11.0`。

- **通用**：去掉 registry 域，剩余路径段用 `-` 拼接
  - `docker.io/goharbor/harbor-core` → `goharbor-harbor-core`
  - `quay.io/cilium/cilium` → `cilium-cilium`
  - `ghcr.io/cloudnative-pg/postgresql` → `cloudnative-pg-postgresql`
  - `quay.io/opstree/redis` → `opstree-redis`
- **核心（kubeadm 强制 basename）**：`kube-apiserver`、`kube-controller-manager`、`kube-scheduler`、`kube-proxy`、`coredns`、`etcd`、`pause`
- **特例**：`ghcr.io/kube-vip/kube-vip` → `kube-vip`
- **GitLab CNG 逐行 override 短名**：如 `gitlab-webservice-ce`、`gitlab-sidekiq-ce`、`gitlab-toolbox-ce`、`gitlab-workhorse-ce`、`gitlab-shell`、`gitaly`、`gitlab-kas`、`gitlab-mailroom`、`certificates`、`kubectl`

## 二、Harbor 项目与账号

- 项目：`baokuaiyun`，**私有**（节点拉取需凭据）。
- 账号：
  - `admin`：仅 UI/建项目/建 robot/应急，密码改掉。
  - robot `pushpull`：作用域 `baokuaiyun`，权限 push+pull；用户名形如 `robot$baokuaiyun+pushpull`。
- 用 Harbor API 自动创建（`make harbor-init` → `registry/push-to-harbor.sh`）：
  ```bash
  # 建项目（私有）：POST /api/v2.0/projects
  # 建 robot：POST /api/v2.0/robots  { name, project, permissions: push/pull }
  ```

## 三、引导顺序（含“影子镜像闭环”）

```
1) acr-prepare(Tier0/1 + 平台必需) → image-load → image-preflight   # 影子镜像，名=Harbor 名(scheme C)
2) operators（CNPG + redis-operator）→ platform-data（PG + Redis）
3) harbor（外部 PG/Redis + 影子镜像）
4) harbor-init：建项目 baokuaiyun(私有) + robot pushpull + 改 admin 密码
5) push-to-harbor：影子镜像同名推入 Harbor
6) 节点 containerd 切 Harbor（pull robot）→ crictl pull 验证（闭环）
7) push-charts：chart → Harbor OCI（oci://<harbor>/baokuaiyun）
```

## 四、镜像清单

拆分（Tier/阶段）于 `registry/images/`：

| 文件 | 内容 |
|---|---|
| `tier0-core.txt` | k8s 核心 + kube-vip + Cilium |
| `tier1-infra.txt` | Longhorn + cert-manager |
| `tier2-platform.txt` | CNPG/redis-operator/redis/harbor/casdoor/gitlab |
| `tier3-observability.txt` | prometheus/loki/otel/blackbox… |

行格式：`<源镜像>  [<override 名>]`（`dst` 由 scheme C 规则生成；override 用于 GitLab/特例）。

## 五、prepare 与 push-to-harbor

- `registry/prepare-acr-images.sh`：源 → 宿主机 tar（目标名=Harbor scheme C）。
  - `docker/quay/ghcr` → **skopeo**（走国内镜像：`docker.m.daocloud.io`、`quay.m.daocloud.io`、`ghcr.nju.edu.cn`）
  - `registry.gitlab.com` → **oras**（skopeo 对该站失败）
- `registry/push-to-harbor.sh`：Harbor 项目/robot + 同名推入 Harbor（skopeo/oras）。
- 源与镜像重写变量：`MIRROR_DOCKER/MIRROR_QUAY/MIRROR_GHCR/MIRROR_K8S`。

## 六、节点 containerd 指向 Harbor

`kubernetes/scripts/install-common.sh` 下发：

```toml
[plugins."io.containerd.grpc.v1.cri".registry.mirrors."harbor.test.baokuaiyun.com"]
  endpoint = ["https://harbor.test.baokuaiyun.com"]
[plugins."io.containerd.grpc.v1.cri".registry.configs."harbor.test.baokuaiyun.com".tls]
  insecure_skip_verify = true    # 演练自签；生产 false
[plugins."io.containerd.grpc.v1.cri".registry.configs."harbor.test.baokuaiyun.com".auth]
  username = "robot$baokuaiyun+pushpull"
  password = "<robot 密码>"
```

## 七、Harbor 作为 OCI chart 源

Harbor 起来后，图表也走 Harbor：`registry/push-charts-to-harbor.sh` 把 `HELM_CHARTS_DIR/*.tgz` push 到 `oci://<harbor>/baokuaiyun`；之后 `make charts-pull` 可从 Harbor 拉。

## 八、演练 vs 生产

| 项 | 演练(test) | 生产 |
|---|---|---|
| Harbor 域名 | harbor.test.baokuaiyun.com | harbor.baokuaiyun.com |
| TLS | 自签 + insecure | 受信任证书 (LE DNS-01 / 阿里云) |
| 入口 | kgateway(VIP:443) | 内网 SLB → kgateway |
| DNS | libvirt dnsmasq | PrivateZone |
| 镜像源 | 国内镜像/registry.gitlab.com | 同左（或 ACR，可选） |
