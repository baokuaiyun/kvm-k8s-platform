# 阿里云生产环境部署说明（多 ECS 自建 kubeadm）

> 前置：本机 KVM 演练环境（Phase 1）验证通过后再执行本文档。
> 目标：多台 ECS 自建 kubeadm 集群，跨可用区，生产就绪。

## 一、资源规划

### 1.1 ECS 实例规格

| 角色 | 实例规格 | 数量 | 系统盘 | 数据盘 | 可用区 |
|------|---------|------|--------|--------|--------|
| cp-1 | 4C/8G | 1 | 40G | 无 | AZ-A |
| cp-2 | 4C/8G | 1 | 40G | 无 | AZ-B |
| cp-3 | 4C/8G | 1 | 40G | 无 | AZ-A |
| worker-1 | 8C/16G | 1 | 40G | 100G | AZ-A |
| worker-2 | 8C/16G | 1 | 40G | 100G | AZ-B |

> 说明：控制面 3 台跨 2 个可用区；worker 可横向扩展。生产可加更多 worker 或专设 DB 节点。

### 1.2 网络规划

```
VPC: 10.0.0.0/16
├── 交换机 A (AZ-A): 10.0.1.0/24   → cp-1, cp-3, worker-1
├── 交换机 B (AZ-B): 10.0.2.0/24   → cp-2, worker-2
│
├── SLB (公网): 
│   ├─ 443 → kgateway (Harbor/GitLab 入口)
│   └─ 22  → 跳板机 (可选)
│
├── NAT 网关: worker 出网 (拉镜像)
└── 安全组: 
    ├─ cp: 6443 (集群内), 22 (跳板)
    ├─ worker: 30000-32767 (NodePort), 22
    └─ 公网: 443 (SLB), 80 (HTTP→HTTPS 跳转)
```

### 1.3 阿里云依赖服务

| 服务 | 用途 |
|------|------|
| **VPC** | 内网隔离 |
| **SLB** | 公网负载均衡入口（CCM 自动创建）|
| **CCM** | cloud-controller-manager，自动创建/管理 SLB |
| **云解析 DNS** | `baokuaiyun.com` 域名 |
| **RAM 子账号** | cert-manager(DNS-01) + CCM(SLB/ECS/VPC) 权限 |
| **ECS RAM Role** | CCM 认证（替代 AK/SK 硬编码）|
| **OSS** | Velero 备份 / etcd 快照异地存储 |
| **NAS 或 ESSD** | 存储（Longhorn 底层或阿里云 CSI）|

## 二、部署步骤

### 2.1 阿里云控制台准备（手动）

```bash
# 1. 购买 ECS（5+ 台，按上表规格）
# 2. 创建 VPC + 交换机（2 个可用区）
# 3. 创建安全组 + 规则
# 4. 创建 RAM 子账号 ×2:
#    a. cert-manager 用: alidns 权限（DNS-01 挑战）
#    b. CCM 用: slb/ecs/vpc 权限（或用 ECS RAM Role 代替）
# 5. 云解析添加记录（SLB 创建后回填公网 IP）:
#    harbor.baokuaiyun.com  → A → <SLB 公网 IP>
#    gitlab.baokuaiyun.com  → A → <SLB 公网 IP>
# 6. 创建 OSS Bucket（velero-backup）
# 7. (可选) 创建 ECS 实例 RAM Role 并绑定 worker 节点
```

> 注意：SLB **不再手动创建**，由阿里云 CCM 在 LoadBalancer Service 声明后自动创建（见 2.6）。DNS A 记录在 SLB 创建后回填 IP。

### 2.2 节点初始化（每台 ECS）

```bash
# 所有节点执行（与演练环境相同的 k8s 准备脚本）
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y -qq kubelet=1.31.0-1.1 kubeadm=1.31.0-1.1 kubectl=1.31.0-1.1
apt-mark hold kubelet kubeadm kubectl

# 关闭 swap
swapoff -a && sed -i '/swap/d' /etc/fstab

# 内核模块
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay && modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system
```

### 2.3 kubeadm 初始化（cp-1）

```bash
kubeadm init \
  --control-plane-endpoint=<SLB内网IP>:6443 \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --upload-certs

# cp-2/cp-3 加入（跨 AZ）
# kubeadm join <SLB内网IP>:6443 --token ... --control-plane --certificate-key ...

# worker 加入
# kubeadm join <SLB内网IP>:6443 --token ... --discovery-token-ca-cert-hash ...
```

> 关键差异：生产用 **SLB 内网 IP** 作为 control-plane-endpoint，实现控制面负载均衡 + 跨 AZ 高可用，而非演练环境的单机 IP。

### 2.4 组件安装（复用演练 base 配置）

```bash
# Cilium / Longhorn / cert-manager / Harbor / GitLab / Flux / Operator
# 全部复用演练环境的 base 配置，仅替换 overlay 环境变量

# 阿里云存储（生产推荐：云盘 CSI，同名 SC app-storage，应用清单零改动）
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/alibaba-cloud-csi-driver/master/deploy/ack/disk-plugin.yaml
# 应用规范 StorageClass（app-storage -> diskplugin.csi.alibabacloud.com，ESSD+加密）
make storage-class STORAGE_BACKEND=alicloud STORAGE_CLASS=app-storage SNAPSHOT_CLASS=alicloud-disk
# 对象存储/异地备份：设置 OSS 后启用 PG barman + Longhorn backupTarget + Velero
#   PG_BACKUP_BUCKET=<bucket> S3_ENDPOINT=oss-cn-hangzhou.aliyuncs.com
#   BACKUP_TARGET=s3://<bucket>@oss-cn-hangzhou.aliyuncs.com/
#   VELERO_BUCKET=<bucket> VELERO_S3_URL=oss-cn-hangzhou.aliyuncs.com
# 详见 docs/storage-plan.md、docs/application-data.md
```

### 2.5 cert-manager + Let's Encrypt（生产）

```bash
kubectl -n cert-manager create secret generic alidns-secret \
  --from-literal=access-key=<RAM_ACCESS_KEY> \
  --from-literal=secret-key=<RAM_SECRET_KEY>

# ClusterIssuer 与演练相同，Certificate 用 prod 域名
# dnsNames: ["*.baokuaiyun.com", "baokuaiyun.com"]
```

### 2.6 CCM + SLB 整合（云原生负载均衡）

> 核心：安装阿里云 CCM，`type: LoadBalancer` Service 自动创建 SLB，无需手动在控制台建 SLB。

#### 2.6.1 整合架构

```
LoadBalancer Service (kgateway)
        │
        ▼
阿里云 CCM (cloud-controller-manager)
  ├─ 检测 LoadBalancer Service
  ├─ 调用阿里云 API 创建 SLB
  ├─ 绑定后端 ECS (worker 节点)
  └─ 回写 SLB 公网 IP 到 Service
        │
        ▼
SLB (47.x.x.x) → kgateway → 按 hostname 路由 → Harbor/GitLab
```

#### 2.6.2 安装阿里云 CCM

```bash
# 开源项目: github.com/kubernetes/cloud-provider-alibaba-cloud
kubectl apply -f https://raw.githubusercontent.com/kubernetes/cloud-provider-alibaba-cloud/master/docs/cloud-controller-manager.yaml
```

> 版本需与 K8s 版本匹配，生产用固定 release 而非 master。

#### 2.6.3 配置认证（推荐 ECS RAM Role）

```bash
# 方式1: ECS 实例 RAM Role（推荐，避免 AK/SK 硬编码）
#   - 创建 RAM Role，授予 slb/ecs/vpc 权限
#   - 将 Role 绑定到所有 worker ECS 实例

# 方式2: Secret 注入 AK/SK（简单，但需保管密钥）
kubectl -n kube-system create secret generic cloud-config \
  --from-literal=access-key-id=<ACCESS_KEY> \
  --from-literal=access-key-secret=<SECRET_KEY>
```

**CCM 所需 RAM 权限**：

```json
{
  "Version": "1",
  "Statement": [
    {"Effect": "Allow", "Action": ["slb:*", "ecs:*", "vpc:*"], "Resource": "*"}
  ]
}
```

#### 2.6.4 kgateway 以 LoadBalancer 暴露

```yaml
# kgateway 的 Gateway 会自动生成 LoadBalancer Service，
# 或用以下 Service 显式声明：
apiVersion: v1
kind: Service
metadata:
  name: kgateway-lb
  namespace: kgateway-system
  annotations:
    service.beta.kubernetes.io/alibaba-cloud-loadbalancer-spec: "slb.s2.small"
    service.beta.kubernetes.io/alibaba-cloud-loadbalancer-address-type: "internet"
    service.beta.kubernetes.io/alibaba-cloud-loadbalancer-charge-type: "paybytraffic"
    service.beta.kubernetes.io/alibaba-cloud-loadbalancer-health-check-flag: "on"
    service.beta.kubernetes.io/alibaba-cloud-loadbalancer-health-check-uri: "/readyz"
spec:
  type: LoadBalancer
  selector: {app: kgateway}
  ports:
  - port: 443
    targetPort: 8080
    protocol: TCP
```

#### 2.6.5 验证 SLB 自动创建

```bash
kubectl get svc kgateway-lb -n kgateway-system -w
# EXTERNAL-IP: 47.x.x.x   ← CCM 自动创建 SLB 并回写公网 IP

# DNS 指向 SLB（在 2.1 已配置）
# harbor.baokuaiyun.com  → A → 47.x.x.x
# gitlab.baokuaiyun.com  → A → 47.x.x.x
```

#### 2.6.6 共享 SLB vs 独立 SLB

| 模式 | 做法 | SLB 数量 | 适用 |
|------|------|---------|------|
| **共享 SLB（推荐）** | 一个 SLB → kgateway → 按域名路由 | 1 个 | Harbor/GitLab/多服务共入口 |
| **独立 SLB** | 每个 Service 一个 SLB | N 个 | 需独立 IP/带宽隔离 |

> 本方案采用共享 SLB：`*.baokuaiyun.com` 全走一个 SLB，kgateway 按 hostname 分流。

## 三、与演练环境的差异执行清单

| 步骤 | 演练环境 | 生产环境差异 |
|------|---------|-------------|
| 节点创建 | virt-install | 阿里云购买 ECS |
| 网络 | libvirt NAT | VPC + 安全组 |
| control-plane-endpoint | 单机 IP | SLB 内网 IP |
| 存储 | Longhorn(本地) | 云盘 CSI 或 Longhorn(云盘) |
| 域名 | *.test / hosts | *.baokuaiyun.com 云解析 |
| 证书 | 自签名 | Let's Encrypt |
| 入口 | NodePort | SLB |
| 备份 | 本地目录 | OSS |

## 四、生产验证清单

```bash
# 控制面 HA
kubectl get nodes                    # 3 CP Ready，跨 AZ
# 杀掉 cp-1，集群仍可用

# 存储
kubectl get sc                       # 云盘 StorageClass
# 创建 PVC，验证云盘自动挂载

# 域名 + 证书
curl -I https://harbor.baokuaiyun.com   # 200，合法证书

# 备份恢复
velero backup create test && velero restore create --from-backup test

# 高可用演练
# 销毁一个 worker，Pod 自动漂移
```

> 生产部署复用演练环境的所有 base 配置，只改 overlay 环境变量，因此文档只列差异部分，完整命令见 implementation-playbook.md。
