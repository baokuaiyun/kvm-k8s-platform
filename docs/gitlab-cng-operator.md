# GitLab：Operator 3.4.1 + CNG CE 19.4.1（本域 Harbor 供镜像）

> 路线：**GitLab Operator 3.4.1 + CNG（Cloud Native GitLab）CE 19.4.1（chart 10.4.1）**，
> 镜像经本域 Harbor，chart 源 Gitee。外部依赖用 `platform-data` 的 CNPG PG / Redis，
> 对象存储用集群内 MinIO。入口挂平台 kgateway Gateway（Gateway API）。

## 一、为什么此路线

- CNG 镜像是微服务（十几个），需 **3CP+2W** 才跑得动。
- EE 未付费 → 用 **CE** 镜像（`*-ce`）；gitaly/shell/kas 等无 `-ce` 后缀。
- ACR 不支持 OCI Helm 且已弃用 → 镜像/图表统一走 **Harbor**。
- 与仓库 GitOps/声明式方向一致（Operator 管理 `GitLab` CR 生命周期）。

## 二、组件与版本

| 组件 | 来源 | 版本 |
|---|---|---|
| GitLab chart（CNG） | Gitee `baokuaiyun/gitlab-charts` 分支 `10-4-stable` | chart 10.4.1 ↔ app v19.4.1 |
| GitLab Operator | Gitee `baokuaiyun/gitlab-operator` tag `3.4.1` 的 `deploy/chart` | 3.4.1 |
| 引擎镜像 | Harbor 项目 `baokuaiyun`（scheme C 短名） | v19.4.1 |

本地源码：`/data/kvm/charts/src/gitlab-operator`、`/data/kvm/charts/src/gitlab-charts`。

## 三、镜像同步（→ Harbor，短名）

清单：`registry/images/gitlab-cng.txt`；脚本：`registry/push-gitlab-to-harbor.sh`（oras）。

> 实测：`registry.gitlab.com` 经本机代理 **skopeo 也可用**（比 oras 快），
> 遇到 oras 卡住可改用 `skopeo copy`。CNG 镜像为公开镜像，无需凭证。

组件清单（scheme C 短名）：
`certificates / cfssl-self-sign / gitaly / gitlab-base / gitlab-container-registry /
gitlab-exporter / gitlab-kas / gitlab-shell / gitlab-sidekiq-ce / gitlab-toolbox-ce /
gitlab-webservice-ce / gitlab-workhorse-ce / kubectl` + `gitlab-operator:3.4.1`。

## 四、前置依赖

1. **镜像仓库容量**：Harbor registry 卷需足够（本演练扩到 ~30Gi）。
2. **对象存储**：chart 10.x 不再内置 MinIO，需外部 S3。演练用集群内 MinIO：
   `platform/gitlab/minio.yaml`（单副本，SC `longhorn-1`），桶：
   `gitlab-artifacts/-lfs/-uploads/-packages/-mr-diffs/-terraform-state/-ci-secure-files/-dependency-proxy/-registry/-pages/-backups`。
3. **外部 PG/Redis**：`platform-data` 的 `platform-pg-rw`、`platform-redis`。
   CNPG 已声明角色 `gitlab`（superuser）与库 `gitlabhq_production`。
4. **Gateway**：平台已有 `gateway/gateway`（kgateway，listener 名 **`https`**，443，wildcard 证书）。
5. **节点内存**：CNG 较重，演练将 worker 提到 **6G**（`virsh setmaxmem/setmem`，
   需关机；宿主需有足够内存）。

## 五、部署步骤

```bash
# 1) 同步镜像（见三）
bash registry/push-gitlab-to-harbor.sh

# 2) MinIO
kubectl create ns minio
kubectl -n minio create secret generic minio-root-cred \
  --from-literal=root-user=$MINIO_ROOT_USER --from-literal=root-password=$MINIO_ROOT_PASSWORD
kubectl apply -f platform/gitlab/minio.yaml

# 3) 单副本 SC（容量紧张时）
kubectl apply -f platform/storage/sc-longhorn1.yaml

# 4) 安装 Operator（chart 依赖 cert-manager，本地裁剪后安装）
cp -r /data/kvm/charts/src/gitlab-operator/deploy/chart /tmp/gitlab-operator-chart
#   删除 Chart.yaml 的 dependencies 段（cert-manager）
helm upgrade --install gitlab-operator /tmp/gitlab-operator-chart \
  -n gitlab-operator --create-namespace -f platform/gitlab/operator-values.yaml

# 5) 预建 ServiceAccount（OLM 才自动建；Helm 安装需手动）
kubectl -n gitlab create sa gitlab-manager
kubectl -n gitlab create sa gitlab-app-nonroot
kubectl create clusterrolebinding gitlab-manager-admin \
  --clusterrole=cluster-admin --serviceaccount=gitlab:gitlab-manager

# 6) 凭据 + CR
set -a; source acr.env; set +a
bash platform/gitlab/deploy.sh          # 建 psql/redis/objectstore 密钥并 apply CR
```

## 六、values 要点（见 `platform/gitlab/gitlab-cr.yaml`）

```yaml
global:
  edition: ce
  hosts: {domain: test.baokuaiyun.com, https: true}
  gitlabVersion: v19.4.1
  communityImages:                     # CE 组件 -> Harbor 短名
    webservice: {repository: harbor.test.baokuaiyun.com/baokuaiyun/gitlab-webservice-ce}
    sidekiq:    {repository: harbor.test.baokuaiyun.com/baokuaiyun/gitlab-sidekiq-ce}
    toolbox:    {repository: harbor.test.baokuaiyun.com/baokuaiyun/gitlab-toolbox-ce}
    migrations: {repository: harbor.test.baokuaiyun.com/baokuaiyun/gitlab-toolbox-ce}
    workhorse:  {repository: harbor.test.baokuaiyun.com/baokuaiyun/gitlab-workhorse-ce}
  certificates: {image: {repository: .../certificates}}
  kubectl:      {image: {repository: .../kubectl}}
  gitlabBase:   {image: {repository: .../gitlab-base}}
  psql:  {host: platform-pg-rw.platform-data.svc.cluster.local, username: gitlab,
          database: gitlabhq_production, password: {secret: gitlab-pg-cred, key: password}}
  redis: {host: platform-redis.platform-data.svc.cluster.local, database: 3,
          auth: {enabled: true, secret: gitlab-redis-cred, key: password}}
  appConfig:
    object_store: {enabled: true, connection: {secret: gitlab-object-storage, key: connection}}
    lfs/artifacts/uploads/packages/external_diffs/terraform_state/ci_secure_files: {...}
  gatewayApi:
    enabled: true
    installEnvoy: false
    configureEnvoy: false
    httpToHttpsRedirect: false
    gatewayRef: {name: gateway, namespace: gateway}
gitlab:
  gitaly: {image: {.../gitaly}, persistence: {size: 10Gi, storageClass: longhorn-1}}
  gitlab-shell:
    image: {.../gitlab-shell}
    gatewayRoute: {enabled: false}     # 见下「坑1」
    service: {type: NodePort}
  kas:
    image: {.../gitlab-kas}
    gatewayRoute: {sectionName: https} # 见下「坑3」
  gitlab-exporter: {image: {.../gitlab-exporter}}
  webservice:
    minReplicas: 1
    gatewayRoute: {sectionName: https} # 见下「坑3」
  sidekiq: {minReplicas: 1}
# 关闭不需要的子 chart
postgresql/redis/prometheus/gitlab-runner/gitlab-zoekt/openbao/traefik/haproxy/registry/minio: disabled
nginx-ingress: {enabled: false}
certmanager: {install: false}
```

## 七、验证

```bash
kubectl -n gitlab get gitlab              # STATUS=Running VERSION=10.4.1
kubectl -n gitlab get pods                # 全部 Running/Completed
kubectl -n gitlab get httproute           # Accepted=True, sectionName=https

# 入口（注意绕过本机代理）
curl -sk --noproxy '*' --resolve gitlab.test.baokuaiyun.com:443:192.168.124.30 \
  -o /dev/null -w '%{http_code}\n' https://gitlab.test.baokuaiyun.com/users/sign_in   # 200
# root 初始密码
kubectl -n gitlab get secret gitlab-gitlab-initial-root-password \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

## 八、踩坑记录

### 坑1：chart 生成 `TCPRoute`，集群无该 CRD

chart 为 gitlab-shell SSH 生成 `TCPRoute`（`gateway.networking.k8s.io/v1`，属实验通道），
未安装会导致 operator 报 `no matches for kind "TCPRoute"`，整个 install 失败。
**解法**：`gitlab.gitlab-shell.gatewayRoute.enabled: false`，SSH 走 Service（`type: NodePort`，
端口见 `kubectl -n gitlab get svc gitlab-gitlab-shell`）。

### 坑2：缺 ServiceAccount `gitlab-manager` / `gitlab-app-nonroot`

Operator 假定这两个 SA 已存在（OLM bundle 的 `--extra-service-accounts` 才会创建）。
Helm 安装需 **手动预建**，否则 shared-secrets / gitaly / migrations 等 Job/Pod
报 `serviceaccount not found`。

### 坑3：路由 sectionName 与既有 Gateway listener 不匹配

chart 默认 route 的 `sectionName` 是 `gitlab-web` / `kas-web`，而平台 Gateway listener
名为 **`https`** → HTTPRoute `Accepted=False`。**解法**：在 CR 里把 webservice/kas 的
`gatewayRoute.sectionName` 覆盖为 `https`。同时 `httpToHttpsRedirect: false` 去掉
`http-default` listener 依赖。

### 坑4：集群内存/存储不足

CNG 部署需要 ~8G+ 内存；4G worker 会导致探针超时、Pod 被 OOM/杀、PG 无 endpoints。
演练把 worker 提升到 6G。存储方面 50G 盘需注意 Longhorn 预留与副本数（见
`docs/longhorn-engine-image-migration.md` 的容量章节），registry 卷需扩容。

### 坑5：`gitlab-manager` 的 PG 连接

PG 主库未就绪（probe 失败）时 `platform-pg-rw` 无 endpoints，migrations 报
`Operation not permitted`。需先保证 `platform-pg-1` 1/1 Ready、endpoints 存在。

## 九、后续

- GitLab Runner：chart 的 `gitlab-runner` 子 chart 已关，另行安装。
- Registry（容器镜像库）：本次 `registry.enabled: false`，如需可开启。
- SSH：当前经 NodePort，生产应经 LB/VIP:22。
- 对象存储：生产改用阿里云 OSS（`platform/gitlab/objectstore-secret.sh`）。
