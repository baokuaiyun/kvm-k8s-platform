# 三模式多租户架构：Namespace 隔离 + API 隔离 + vCluster 虚拟集群

## 一、vCluster 架构说明

### 1.1 什么是 vCluster

vCluster 在**一个物理集群内**创建**完全隔离的虚拟 Kubernetes 控制面**，每个租户拥有独立的 API Server、CRD、RBAC。

```
┌─ 物理集群 (KVM: 3CP + 2Worker；1CP+1W 起步，make scale-out 扩容) ─┐
│                                                                │
│  ┌──── vCluster: team-a (ns: vc-team-a) ────────────┐        │
│  │  ┌──────────────┐   ┌──────────────┐              │        │
│  │  │ API Server   │   │ Controller   │              │        │
│  │  │ (独立)        │   │ Manager      │              │        │
│  │  └──────┬───────┘   └──────────────┘              │        │
│  │         │  kubectl (管理员视角)                     │        │
│  │         ▼                                          │        │
│  │  ┌─────────────────┐   ┌─────────────────┐        │        │
│  │  │ Pod A1 (host)    │   │ Service A       │        │        │
│  │  │ → worker-1       │   │ ConfigMap A     │        │        │
│  │  └─────────────────┘   └─────────────────┘        │        │
│  └────────────────────────────────────────────────────┘        │
│                                                                │
│  ┌──── vCluster: team-b (ns: vc-team-b) ────────────┐        │
│  │  ┌──────────────┐   ┌──────────────┐              │        │
│  │  │ API Server   │   │ Controller   │              │        │
│  │  │ (独立)        │   │ Manager      │              │        │
│  │  └──────┬───────┘   └──────────────┘              │        │
│  │         │  kubectl (租户视角)                       │        │
│  │         ▼                                          │        │
│  │  ┌─────────────────┐   ┌─────────────────┐        │        │
│  │  │ Pod B1 (host)    │   │ Redis Operator  │        │        │
│  │  │ → worker-2       │   │ (独立安装)       │        │        │
│  │  └─────────────────┘   └─────────────────┘        │        │
│  └────────────────────────────────────────────────────┘        │
│                                                                │
│  ┌─ 宿主机视角 ──────────────────────────────────────┐        │
│  │  ns: vc-team-a → vcluster-api, vcluster-syncer    │        │
│  │                    Pod-A1...                       │        │
│  │  ns: vc-team-b → vcluster-api, vcluster-syncer    │        │
│  │                    Pod-B1...                       │        │
│  └────────────────────────────────────────────────────┘        │
└────────────────────────────────────────────────────────────────┘
```

### 1.2 vCluster 核心组件

| 组件 | 说明 | 资源消耗（k3s 模式） |
|------|------|-------------------|
| **API Server** | 租户独立的 Kubernetes API | ~200m CPU / 256MB RAM |
| **Controller Manager** | 内置控制器 | ~100m CPU / 128MB RAM |
| **Syncer** | 虚拟资源 ↔ 宿主机资源同步 | ~50m CPU / 64MB RAM |
| **DNS** | 虚拟集群 DNS | ~20m CPU / 32MB RAM |
| **总计** | | **~500m CPU / ~512MB RAM** |

### 1.3 vCluster vs 其他模式的对比

| 维度 | Namespace 隔离 | API 隔离 (Crossplane) | **vCluster** |
|------|---------------|----------------------|-------------|
| **隔离级别** | Namespace 级别 | API 请求级别 | **控制面级别** |
| **独立 CRD** | ❌ 共享集群 CRD | ❌ 平台定义 | ✅ **可自行安装** |
| **独立 Operator** | ❌ 共享 | ❌ 平台管理 | ✅ **可自行安装** |
| **独立 RBAC** | Role/ClusterRole | 平台 Token | ✅ **完整 RBAC** |
| **资源开销** | 零 | ~200MB (Crossplane) | ~500MB / 租户 |
| **网络隔离** | NetworkPolicy | 平台控制 | ✅ **默认隔离** |
| **租户自由度** | 中 | 低 | **高** |
| **管理成本** | 低 | 中 | 中 |

---

## 二、三模式完整架构

### 2.1 模式选择矩阵

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│   租户为什么需要 K8s?                                           │
│         │                                                        │
│         ├─ 只需要数据库/缓存 → Mode B: API 隔离 (Crossplane)     │
│         │   例: 业务开发团队，只申请 PG/Redis                     │
│         │                                                        │
│         ├─ 需要部署应用 + 标准 K8s API → Mode A: Namespace 隔离  │
│         │   例: 内部平台团队，有 K8s 经验                          │
│         │                                                        │
│         └─ 需要完全控制面 + 自定义 CRD/Operator → Mode C: vCluster│
│             例: 第三方集成团队、需要装自己的 Operator                │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 三种模式共存拓扑

```
                    ┌──────────────────────────┐
                    │  平台管理入口             │
                    │  (Flux CD + GitOps)       │
                    └──────┬───────────────────┘
                           │
                           ▼
┌─ KVM 物理集群 ──────────────────────────────────────────────┐
│                                                              │
│  共享基础设施:                                                │
│    redis-operator / cnpg-operator / Harbor / GitLab          │
│    Longhorn / Prometheus / kgateway / cert-manager           │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Mode A: Namespace 隔离                              │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐            │   │
│  │  │ ns:ops   │ │ ns:ci    │ │ ns:demo  │            │   │
│  │  │ (平台)   │ │ (CI/CD)  │ │ (示例)   │            │   │
│  │  └──────────┘ └──────────┘ └──────────┘            │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Mode B: API 隔离 (Crossplane + Backstage)            │   │
│  │                                                      │   │
│  │  Backstage → PostgreSQLClaim → Crossplane            │   │
│  │                         → ns:team-x → PG Cluster    │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Mode C: vCluster 虚拟集群                             │   │
│  │                                                      │   │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐    │   │
│  │  │ vc-tenant1 │  │ vc-tenant2 │  │ vc-tenant3 │    │   │
│  │  │ (独立 API) │  │ (独立 API) │  │ (独立 API) │    │   │
│  │  │ 自定义 CRD │  │ 自装 Operator│  │ 第三方集成  │    │   │
│  │  └────────────┘  └────────────┘  └────────────┘    │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### 2.3 三层租户管理入口

| 角色 | 访问方式 | 可见范围 |
|------|---------|---------|
| SRE / 平台团队 | `kubectl --context=kvm` | 物理集群全部资源 |
| 内部团队 (Mode A) | `kubectl --context=kvm -n team-x` | 指定 namespace |
| 业务开发 (Mode B) | Backstage UI | 自助模板，无 kubectl |
| 独立租户 (Mode C) | `kubectl --context=vc-tenant1` | 自己的虚拟集群 |
| 全局管理 | Flux GitOps | 所有配置 Git 化 |

---

## 三、vCluster 安装与配置

### 3.1 安装 vCluster CLI (宿主机)

```bash
# 通过脚本安装
curl -L -o vcluster "https://github.com/loft-sh/vcluster/releases/latest/download/vcluster-linux-amd64"
chmod +x vcluster
sudo mv vcluster /usr/local/bin/

# 验证
vcluster version
```

### 3.2 Helm 方式安装 vCluster（推荐生产）

```bash
# 添加 Helm 仓库
helm repo add loft https://charts.loft.sh
helm repo update

# 为每个租户创建命名空间并安装 vCluster
kubectl create namespace vc-tenant1

# 安装 vCluster (k3s 模式，最轻量)
helm upgrade --install vc-tenant1 loft/vcluster \
  --namespace vc-tenant1 \
  --set syncer.extraArgs='{--tolerations=[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists"}]}' \
  --set rbac.clusterRole.create=true \
  --set rbac.role.extended=false
```

### 3.3 vCluster 核心配置 (values.yaml)

```yaml
# vcluster-values.yaml
syncer:
  extraArgs:
  - --tolerations=
  - --enforce-node-selector-node-selector={"worker-type":"tenant"}
  - --enforce-node-selector-allow-existing-node-selector=false

# 资源限制
coredns:
  resources:
    requests:
      cpu: 20m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 128Mi

vcluster:
  image: loft-sh/vcluster-k3s:latest
  
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

  # 持久化 etcd (避免重启丢失)
  storage:
    persistence: true
    size: 5Gi
    storageClass: longhorn

  # 限制虚拟集群可创建的 Namespace 数量
  limits:
    maxNamespaces: 5

# 网络隔离
network:
  enabled: true
  networkPolicy: |
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: default-deny
    spec:
      podSelector: {}
      policyTypes:
      - Ingress
      - Egress
```

### 3.4 创建租户 vCluster 脚本

```bash
#!/usr/bin/env bash
# create-vcluster-tenant.sh
set -euo pipefail

TENANT=$1
NAMESPACE="vc-${TENANT}"
CPU_LIMIT=${2:-"1"}
MEM_LIMIT=${3:-"2Gi"}

echo "[+] 创建 vCluster 租户: ${TENANT}"

kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# 创建 ResourceQuota 限制 vCluster 对宿主机资源的消耗
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: vcluster-quota
  namespace: ${NAMESPACE}
spec:
  hard:
    requests.cpu: "${CPU_LIMIT}"
    requests.memory: "${MEM_LIMIT}"
    limits.cpu: "$((CPU_LIMIT * 2))"
    limits.memory: "$((MEM_LIMIT * 2))"
    persistentvolumeclaims: "5"
    count/namespaces: "1"
EOF

# 安装 vCluster
helm upgrade --install ${NAMESPACE} loft/vcluster \
  --namespace ${NAMESPACE} \
  --values vcluster-values.yaml \
  --set vcluster.resources.requests.cpu="200m" \
  --set vcluster.resources.requests.memory="256Mi" \
  --set vcluster.resources.limits.cpu="500m" \
  --set vcluster.resources.limits.memory="512Mi"

echo "[+] 等待 vCluster 就绪..."
kubectl wait --for=condition=available --timeout=120s -n ${NAMESPACE} deployment/${NAMESPACE}

# 生成租户 kubeconfig
vcluster connect ${NAMESPACE} -n ${NAMESPACE} --update-current=false \
  -o ${NAMESPACE}-kubeconfig.yaml

echo "[+] 租户 kubeconfig: ./${NAMESPACE}-kubeconfig.yaml"
echo "    使用: kubectl --kubeconfig=${NAMESPACE}-kubeconfig.yaml get ns"
```

### 3.5 验证 vCluster 隔离性

```bash
# 宿主机管理员视角
kubectl get pods -A                              # 可以看到所有

# 租户 A 视角 (vCluster 内部)
kubectl --kubeconfig=vc-tenant1-kubeconfig.yaml get ns  # 只能看到自己
kubectl --kubeconfig=vc-tenant1-kubeconfig.yaml get nodes # 看不到具体 Node

# 租户在 vCluster 内安装自己的 Operator
kubectl --kubeconfig=vc-tenant1-kubeconfig.yaml helm install my-crd-operator ...
```

### 3.6 清理 vCluster

```bash
vcluster delete vc-tenant1 -n vc-tenant1
kubectl delete ns vc-tenant1
```

---

## 四、资源规划

### 4.1 物理集群可用资源

```
KVM 集群总计: 14 vCPU / 20G RAM
├─ 系统开销 (OS + K8s 组件):    ~2 vCPU / 3G
├─ 基础设施 (Cilium/Longhorn等): ~2 vCPU / 4G
├─ 平台服务 (Harbor/GitLab等):  ~2 vCPU / 4G
├─ 可用资源:                    ~8 vCPU / 9G
│
├─ Mode A: 内部 namespace:      ~1 vCPU / 1G
├─ Mode B: Crossplane + API:    ~1 vCPU / 2G
│
└─ Mode C: vCluster 租户
   ├─ vc-tenant1 (轻量):        ~1 vCPU / 1G  (配额: 1C/2G)
   ├─ vc-tenant2 (轻量):        ~1 vCPU / 1G  (配额: 1C/2G)
   └─ vc-tenant3 (轻量):        ~1 vCPU / 1G  (配额: 1C/2G)
```

**结论**：在当前硬件上，可支撑 **2-3 个轻量 vCluster 租户** + Crossplane API + Namespace 隔离。

### 4.2 扩展建议

| 场景 | 建议 |
|------|------|
| 需要更多 vCluster | 增加 Worker VM (额外 4C/4G 每台) |
| vCluster 需要更多资源 | 增加 ECS 数据盘 + 扩容 Worker VM 规格 |
| 生产环境隔离 | 不同 vCluster 分配到不同 Worker (节点亲和性) |

---

## 五、三模式实施路线图

```
Phase 1 — 基础设施 (KVM 集群就绪)
├── Cilium / Longhorn / cert-manager / kgateway
├── redis-operator / cnpg-operator (共享)
└── Harbor / GitLab / CoreDNS 域名重写

Phase 2 — Mode A: Namespace 隔离
├── 创建 ops / ci / demo 等 namespace
├── RBAC 模板 + NetworkPolicy 模板
├── ResourceQuota + LimitRange
└── 租户 kubeconfig 生成脚本

Phase 3 — Mode C: vCluster (新增)
├── 安装 vCluster CLI + Helm Chart
├── 创建首个 vCluster 验证 (vc-tenant1)
├── 验证隔离性 (独立 API / CRD / Operator)
├── vCluster 网络策略配置
└── 创建租户自助脚本

Phase 4 — Mode B: API 隔离
├── Crossplane + Provider
├── PostgreSQLClaim / RedisClaim 定义
├── Backstage 开发者门户
└── 自助模板

Phase 5 — GitOps 统一管理
├── Flux CD 管理物理集群
├── Git 仓库结构:
│   clusters/kvm/
│   ├── infrastructure/       # Cilium, Longhorn, etc.
│   ├── platform/             # Harbor, GitLab, Backstage
│   ├── modes/
│   │   ├── namespace/        # RBAC, NetworkPolicy, Quota
│   │   ├── crossplane/       # XRD, Composition
│   │   └── vcluster/         # vCluster values, create scripts
│   └── tenants/
│       ├── tenant-a.yaml     # Mode A 配置
│       ├── tenant-b.yaml     # Mode C 配置
│       └── tenant-c.yaml     # Mode B 配置
```

---

## 六、模式对照速查

```
租户需求                          → 推荐模式
──────────────────────────────────────────────────────
"我要跑一个 Web 应用 + Redis"     → B (API/Crossplane)
"我要部署全套微服务"               → A (Namespace)
"我要装自己的 Operator"            → C (vCluster)
"我是第三方，不想跟别人共享 API"   → C (vCluster)
"我只是 CI/CD 跑流水线"            → A (Namespace, 只读权限)
"我需要等保/合规审计"             → C (vCluster + 独立 etcd)
"我不懂 K8s，只要 PG 数据库"       → B (Backstage 点一下)
```