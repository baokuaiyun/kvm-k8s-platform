# 环境差异说明：本机 KVM 演练 vs 阿里云生产

> 核心原则：**同一套集群方案，两套环境落地**。演练环境跑通验证后，生产环境复用全部配置，仅替换环境相关变量。

## 一、总体策略

```
本机 KVM 演练（先做）          阿里云生产（后做）
单机 + KVM 虚拟化          →   多 ECS 自建 kubeadm
验证架构/流程/配置          →   复用同一套 GitOps 配置
证明方案可行               →   替换环境变量上线
```

## 二、差异对照表

| 维度 | 本机 KVM 演练 | 阿里云生产 | 说明 |
|------|--------------|-----------|------|
| **宿主机** | 1 台物理机/ECS | N 台 ECS | 生产节点即 ECS，无需嵌套 KVM |
| **节点形态** | KVM VM (5台) | ECS 实例 (5台+) | 生产直接买 ECS 当节点 |
| **网络** | libvirt NAT `192.168.124.0/24` | VPC 内网 `192.168.1.0/24` | 生产用真实 VPC |
| **节点 IP** | 静态 DHCP 分配 | VPC 私网 IP 自动分配 | 生产不需要手动 MAC/IP |
| **存储** | 本地 qcow2 + Longhorn | 云盘 + NAS/云盘 CSI | 生产可用阿里云原生存储 |
| **DNS** | `/etc/hosts` 或 `*.test` | 阿里云云解析 | 生产有公网域名 |
| **域名** | `*.test.baokuaiyun.com` | `*.baokuaiyun.com` | 环境隔离 |
| **证书** | 自签名（演练够用） | Let's Encrypt DNS-01 | 生产必须合法证书 |
| **入口** | NodePort + 端口转发 | SLB 负载均衡 | 生产用 SLB |
| **镜像源** | Harbor Proxy Cache | 阿里云内网源 + Harbor | 生产可走阿里云内网 |
| **高可用** | 3CP 同宿主机（宿主单点） | 3CP 跨可用区 | 生产真正 HA |
| **备份** | 本地目录 | OSS 异地 | 生产异地容灾 |
| **监控** | Prometheus + Grafana | 同左 + 阿里云 SLS | 可选增强 |

## 三、配置复用方式

演练环境验证通过后，生产环境只需改动以下变量：

```bash
# 演练环境（本机）
DOMAIN=test.baokuaiyun.com
WILDCARD=*.test.baokuaiyun.com
CERT_SECRET=wildcard-test-tls
HARBOR_URL=harbor.test.baokuaiyun.com
GITLAB_URL=gitlab.test.baokuaiyun.com
STORAGE_CLASS=longhorn            # VM 本地盘
INGRESS=nodeport                  # 端口转发

# 生产环境（阿里云）
DOMAIN=baokuaiyun.com
WILDCARD=*.baokuaiyun.com
CERT_SECRET=wildcard-prod-tls
HARBOR_URL=harbor.baokuaiyun.com
GITLAB_URL=gitlab.baokuaiyun.com
STORAGE_CLASS=alicloud-disk       # 阿里云云盘
INGRESS=slb                       # SLB 负载均衡
```

Git 仓库结构（环境差异通过 Kustomize overlay 隔离）：

```
k8s-gitops/
├── base/                          # 共享，两环境完全一致
│   ├── cilium/
│   ├── longhorn/
│   ├── cert-manager/
│   ├── harbor/
│   ├── gitlab/
│   ├── flux/
│   ├── operators/
│   └── tenants/
└── overlays/
    ├── drill/                     # 本机演练环境
    │   ├── kustomization.yaml
    │   └── env-patch.yaml         # 域名/IP/存储差异
    └── prod/                      # 阿里云生产环境
        ├── kustomization.yaml
        └── env-patch.yaml
```

## 四、两阶段推进顺序

```
Phase 1: 本机 KVM 演练（当前机器）
  ├─ 1. 单机建 KVM + 5 VM + kubeadm 集群
  ├─ 2. Cilium + Longhorn + cert-manager
  ├─ 3. Harbor + GitLab（*.test 域名，自签名）
  ├─ 4. Flux + 三模式租户 + Operator
  ├─ 5. 全套验证 + 备份恢复演练
  └─ 产出：验证通过的 GitOps 配置 + SOP

Phase 2: 阿里云生产（演练通过后）
  ├─ 1. 购买 N 台 ECS（跨可用区）
  ├─ 2. 阿里云控制台：VPC/安全组/SLB/云解析/RAM
  ├─ 3. 复用 Phase 1 的 base 配置
  ├─ 4. 替换 overlay 为 prod 环境变量
  ├─ 5. kubeadm 初始化 + Flux 同步
  └─ 产出：生产就绪集群
```

## 五、演练环境的限制（需知晓）

| 限制 | 影响 | 生产是否解决 |
|------|------|-------------|
| 3CP 在同一宿主机 | 宿主宕机 = 控制面全挂 | ✅ 生产跨 AZ |
| NAT 网络无真实公网 | 无法测真实 DNS-01 | ✅ 生产云解析 |
| VM 本地盘性能 | 存储 I/O 不代表生产 | ✅ 生产云盘/NAS |
| 自签名证书 | 需跳过验证 | ✅ 生产 Let's Encrypt |
| 单机资源瓶颈 | 48C/31G 上限 | ✅ 生产按需扩容 |

> 演练环境的目的是**验证架构与配置正确性**，不是测性能/可用性。性能与可用性在阿里云生产环境验证。
