# baokuaiyun.com 域名迁移与 Harbor/GitLab 部署方案

## 一、整体架构

### 1.1 域名规划

```
baokuaiyun.com
├── harbor.baokuaiyun.com      → Harbor 镜像仓库 + ChartMuseum
├── gitlab.baokuaiyun.com      → GitLab 代码仓库 + CI/CD
├── registry.baokuaiyun.com    → (可选) 纯容器镜像 Registry
├── argocd.baokuaiyun.com      → ArgoCD (后续)
├── grafana.baokuaiyun.com     → Grafana (后续)
└── *.baokuaiyun.com           → 通配符留用
```

### 1.2 DNS 分内外解析方案

| 场景 | 解析方式 | 说明 |
|------|----------|------|
| **外网用户** | 阿里云云解析 DNS | `harbor.baokuaiyun.com` → ECS 公网 IP |
| **集群内 Pod** | CoreDNS Rewrite | `harbor.baokuaiyun.com` → Harbor Service ClusterIP |
| **宿主机/VM** | /etc/hosts 或内网 DNS | `harbor.baokuaiyun.com` → 192.168.124.x (VM IP) |

### 1.3 TLS 证书链

```
Let's Encrypt (生产环境)
    └─ *.baokuaiyun.com 通配符证书  (DNS-01 挑战)
         ├─ harbor.baokuaiyun.com
         ├─ gitlab.baokuaiyun.com
         └─ 后续所有 *.baokuaiyun.com 子域
```

通过 `cert-manager` + `ClusterIssuer` 自动签发和续期，DNS-01 挑战需要阿里云 DNS API Token。

### 1.4 流量路径（部署后）

```
外网用户
    │ HTTPS (harbor.baokuaiyun.com:443)
    ▼
阿里云 SLB/ECS 公网 IP (192.168.1.251)
    │
    ▼
kgateway (K8s Gateway API)
    │  TLS termination + 路由
    ├──→ Harbor Service (harbor.baokuaiyun.com)
    └──→ GitLab Service (gitlab.baokuaiyun.com)

集群内部 Pull 镜像:
    Pod → containerd → Harbor Mirror → Harbor Registry (本地)
```

---

## 二、前置准备

### 2.1 需要用户手动完成

| 步骤 | 操作 | 说明 |
|------|------|------|
| ① | 阿里云云解析添加 A 记录 | `harbor.baokuaiyun.com` → `ECS 公网 IP` |
| ② | 阿里云云解析添加 A 记录 | `gitlab.baokuaiyun.com` → `ECS 公网 IP` |
| ③ | RAM 子账号 AccessKey | 用于 cert-manager DNS-01 挑战（阿里云 DNS API） |
| ④ | 开通 80/443 端口 | ECS 安全组规则允许公网访问 |

### 2.2 阿里云 DNS API 权限

cert-manager 需要通过 DNS-01 挑战签发证书，需要阿里云 RAM 子账号权限：

```json
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "alidns:DescribeDomainRecords",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "alidns:AddDomainRecord",
        "alidns:DeleteDomainRecord",
        "alidns:UpdateDomainRecord"
      ],
      "Resource": "*"
    }
  ]
}
```

---

## 三、部署步骤（按顺序执行）

### Phase 1: 基础设施就绪

```bash
# 1. 创建 namespace
kubectl create namespace cert-manager
kubectl create namespace harbor
kubectl create namespace gitlab

# 2. 创建阿里云 DNS API Secret (给 cert-manager 使用)
kubectl create secret generic alidns-secret \
  --namespace cert-manager \
  --from-literal=access-key=<ALIBABA_CLOUD_ACCESS_KEY> \
  --from-literal=secret-key=<ALIBABA_CLOUD_SECRET_KEY>
```

### Phase 2: cert-manager + Let's Encrypt

```bash
# 安装 cert-manager
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true

# 创建 ClusterIssuer (Let's Encrypt 生产)
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@baokuaiyun.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - dns01:
        alidns:
          accessKeySecretRef:
            name: alidns-secret
            key: access-key
          secretKeySecretRef:
            name: alidns-secret
            key: secret-key
          regionId: cn-hangzhou
EOF

# 创建测试证书验证
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-baokuaiyun
  namespace: cert-manager
spec:
  secretName: wildcard-baokuaiyun-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - "*.baokuaiyun.com"
  - "baokuaiyun.com"
EOF

# 验证证书签发
kubectl get certificate -n cert-manager wildcard-baokuaiyun -w
```

### Phase 3: 部署 Harbor

```bash
# 准备 PV (Longhorn StorageClass)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: harbor-registry
  namespace: harbor
spec:
  storageClassName: longhorn
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: harbor-database
  namespace: harbor
spec:
  storageClassName: longhorn
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: harbor-redis
  namespace: harbor
spec:
  storageClassName: longhorn
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: harbor-trivy
  namespace: harbor
spec:
  storageClassName: longhorn
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
EOF

# 安装 Harbor
helm repo add harbor https://helm.goharbor.io
helm upgrade --install harbor harbor/harbor \
  --namespace harbor \
  --create-namespace \
  --set expose.type=clusterIP \
  --set expose.tls.auto.commonName=harbor.baokuaiyun.com \
  --set expose.tls.secretName=wildcard-baokuaiyun-tls \
  --set externalURL=https://harbor.baokuaiyun.com \
  --set harborAdminPassword=admin123 \
  --set persistence.persistentVolumeClaim.registry.existingClaim=harbor-registry \
  --set persistence.persistentVolumeClaim.database.existingClaim=harbor-database \
  --set persistence.persistentVolumeClaim.redis.existingClaim=harbor-redis \
  --set persistence.persistentVolumeClaim.trivy.existingClaim=harbor-trivy \
  --set metrics.enabled=true \
  --set cache.layerGroups.redis.enabled=true \
  --set portal.tls.secretName=wildcard-baokuaiyun-tls
```

### Phase 4: 创建 Harbor Gateway + HTTPRoute

```yaml
# harbor-gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: harbor-gateway
  namespace: harbor
spec:
  gatewayClassName: kgateway
  listeners:
  - name: https
    protocol: HTTPS
    port: 443
    hostname: harbor.baokuaiyun.com
    tls:
      mode: Terminate
      certificateRefs:
      - name: wildcard-baokuaiyun-tls
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: harbor-route
  namespace: harbor
spec:
  parentRefs:
  - name: harbor-gateway
  hostnames:
  - harbor.baokuaiyun.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: harbor-portal
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /api
    backendRefs:
    - name: harbor-core
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /service
    backendRefs:
    - name: harbor-core
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /v2
    backendRefs:
    - name: harbor-core
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /chartrepo
    backendRefs:
    - name: harbor-core
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /c
    backendRefs:
    - name: harbor-core
      port: 80
```

### Phase 5: 部署 GitLab

```bash
# 下载 GitLab values
cat <<'EOF' > gitlab-values.yaml
global:
  hosts:
    domain: baokuaiyun.com
    hostSuffix: ""
    https: true
    externalIP: ""
    gitlab:
      name: gitlab.baokuaiyun.com
    registry:
      name: harbor.baokuaiyun.com
  ingress:
    configureCertmanager: false
    class: kgateway
    tls:
      secretName: wildcard-baokuaiyun-tls
  shell:
    host: gitlab.baokuaiyun.com

certmanager:
  install: false

nginx-ingress:
  enabled: false

gitlab-runner:
  install: true

gitlab:
  webservice:
    minReplicas: 1
    maxReplicas: 2

registry:
  enabled: false   # 使用 Harbor 作为容器镜像仓库

redis:
  install: true
  persistence:
    size: 10Gi

postgresql:
  install: true
  persistence:
    size: 30Gi

minio:
  persistence:
    size: 50Gi

prometheus:
  install: false
EOF

# 安装 GitLab
helm repo add gitlab https://charts.gitlab.io
helm upgrade --install gitlab gitlab/gitlab \
  --namespace gitlab \
  --create-namespace \
  --timeout 600s \
  --values gitlab-values.yaml
```

### Phase 6: CoreDNS 内部域名解析

```bash
# 配置 CoreDNS 重写规则，让集群内 Pod 通过 ClusterIP 访问
kubectl edit configmap -n kube-system coredns

# 添加以下内容到 Corefile:
#     rewrite name harbor.baokuaiyun.com harbor.harbor.svc.cluster.local
#     rewrite name gitlab.baokuaiyun.com gitlab.gitlab.svc.cluster.local
```

### Phase 7: Harbor 接管镜像仓库

```bash
# 1. 配置 containerd mirror (所有节点)
# 编辑 /etc/containerd/config.toml，添加:

# [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
#   endpoint = ["https://harbor.baokuaiyun.com/v2/proxy-docker"]

# 2. 在 Harbor 创建 Proxy Cache 项目
#    Project → New Project → 
#    Project Name: proxy-docker
#    Access Level: Public
#    Proxy Cache: 勾选, Endpoint: https://registry-1.docker.io

# 3. 推送到 Harbor
docker pull nginx:alpine
docker tag nginx:alpine harbor.baokuaiyun.com/k8s-library/nginx:alpine
docker push harbor.baokuaiyun.com/k8s-library/nginx:alpine

# 4. 拉取测试
docker pull harbor.baokuaiyun.com/k8s-library/nginx:alpine
```

---

## 四、已有镜像迁移方案

从阿里云 CR 迁移到 Harbor：

```bash
#!/usr/bin/env bash
# migrate-images.sh — 将阿里云 CR 镜像迁移到 Harbor
set -euo pipefail

SRC_REGISTRY="crpi-adznwq8xa40ei174.cn-hangzhou.personal.cr.aliyuncs.com/baokuaiyun"
DST_REGISTRY="harbor.baokuaiyun.com/k8s-library"

# 登录源和目标
docker login --username=<阿里云CR用户名> $SRC_REGISTRY
docker login harbor.baokuaiyun.com

# 定义需要迁移的镜像列表
IMAGES=(
  "service-demo:0.1.0"
  "kgateway:v2.4.5"
  # 添加更多...
)

for img in "${IMAGES[@]}"; do
  echo "[+] 迁移 ${img}..."
  docker pull "${SRC_REGISTRY}/${img}" || { echo "[!] 拉取失败"; continue; }
  docker tag "${SRC_REGISTRY}/${img}" "${DST_REGISTRY}/${img}"
  docker push "${DST_REGISTRY}/${img}"
  docker rmi "${SRC_REGISTRY}/${img}" "${DST_REGISTRY}/${img}"
done
```

---

## 五、部署顺序总览

```
时间线
│
├─ Step 1: 用户添加 DNS A 记录  (手动)
├─ Step 2: 创建阿里云 RAM 子账号  (手动)
├─ Step 3: install cert-manager  (脚本)
├─ Step 4: create ClusterIssuer  (kubectl apply)
├─ Step 5: 等待通配符证书签发  (kubectl wait)
├─ Step 6: install Harbor  (helm)
├─ Step 7: create Gateway + HTTPRoute  (kubectl apply)
├─ Step 8: 验证 Harbor 可访问  (curl https://harbor.baokuaiyun.com)
├─ Step 9: install GitLab  (helm)
├─ Step 10: 验证 GitLab 可访问  (curl https://gitlab.baokuaiyun.com)
├─ Step 11: 配置 CoreDNS 内部域名解析
├─ Step 12: Harbor 创建 Proxy Cache 项目
├─ Step 13: 迁移已有镜像到 Harbor
├─ Step 14: 配置 containerd mirror 指向 Harbor
└─ Step 15: 更新所有 workload 镜像地址 → harbor.baokuaiyun.com
```

---

## 六、验证清单

| 检查项 | 预期结果 |
|--------|----------|
| `curl -I https://harbor.baokuaiyun.com` | HTTP 200, TLS 证书有效 |
| `curl -I https://gitlab.baokuaiyun.com` | HTTP 302 (重定向到登录页) |
| `docker login harbor.baokuaiyun.com` | Login Succeeded |
| `docker pull harbor.baokuaiyun.com/k8s-library/nginx:alpine` | 拉取成功 |
| 集群内 Pod 访问 `harbor.baokuaiyun.com` | 通过 CoreDNS 解析到 ClusterIP |
| cert-manager 证书状态 | `Ready=True` |
| Harbor Proxy Cache 测试 | 首次拉取 docker.io 镜像后，二次拉取命中缓存 |