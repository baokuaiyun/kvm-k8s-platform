# 网络架构与 LB 设计

> 本文是**网络相关内容的单一入口**：网络平面归属、宿主机内网、容器网络（Pod/Service 分开讲）、外网、控制面浮动 IP（kube-vip）、服务 LB、三环境实现对比、网络参数设置与要求、双网段规划与 FAQ。
> 关联 [`parameters.md`](parameters.md)、[`access-gateway.md`](access-gateway.md)、[`environment-differences.md`](environment-differences.md)、
> [`alicloud-deployment.md`](alicloud-deployment.md)、[`implementation-playbook.md`](implementation-playbook.md)。
> **验证**：网络正确性核对见 [`network-verification.md`](network-verification.md)（`make verify-network`）。
> **服务/业务 IP**（平台入口固定 IP + 业务按需池、三环境对比）见 [`service-ip-design.md`](service-ip-design.md)。
>
> 参数单一真源：[`variables.mk`](../variables.mk)（G 默认）<- [`gitops/profiles/<env>.env`](../gitops/profiles)（P 覆盖，`make ... ENV=<env>`）<- `acr.env`（S 密钥）。

---

## 一、网络平面总览与归属

本项目把网络分成 **4 个平面**。先记住“**谁属于哪个平面**”，后面所有细节都对得上：

| 平面 | 地址空间（drill） | 用途 | 谁负责 | 备注 |
|---|---|---|---|---|
| ① 宿主机网络（**内网/underlay**） | `192.168.124.0/24` | 节点互通、网关、DHCP/DNS | libvirt/dnsmasq（云=VPC，裸机=交换机/VLAN） | 承载一切 |
| ② 容器网络 | Pod `10.244.0.0/16` + Service `10.96.0.0/12` | Pod↔Pod、Service | **Cilium** | 叠加在①之上 |
| ③ 外网 | NAT/EIP/公网 | 南北向出口/入口 | NAT / SLB / 防火墙 | 通常只出不进（drill） |
| ④ 控制面浮动 IP | `192.168.124.30` | kube-apiserver 端点 | **kube-vip**（云=内网 SLB） | **归属①内网**，非外网 |

> 关键澄清：**kube-vip 的浮动 IP 是“内网”的一段地址**（和节点同二层），不是外网、也不是服务 LB。
> 容器网络（②）不是独立物理网络，而是构建在①之上的叠加网。

**分层（由下到上）**：

| # | 层 | 内容 | 负责组件 |
|---|---|---|---|
| L0 | 物理/underlay | 宿主网桥(`br-prod`)、VPC/vSwitch、交换机 VLAN | libvirt / 云 / 交换机 |
| L1 | 节点网（管理网） | 节点 IP、网关、DHCP/DNS | dnsmasq / VPC / 企业 DHCP |
| L2 | 控制面浮动 IP | kube-apiserver 端点 `CP_VIP:6443` | **kube-vip**（云=内网 SLB） |
| L3 | Pod 网络 | pod↔pod（真实 Pod IP） | **Cilium**（CNI，VXLAN/native） |
| L4 | Service 网络 | ClusterIP 等（虚拟 IP） | **Cilium**（kube-proxy 替换，eBPF） |
| L5 | 入口/服务 LB | Gateway 443、L4 LB IP | **Cilium L2**（本地）/ **SLB**（云） |

> **L3–L5 的集群数据面几乎全部经过 Cilium 的 eBPF datapath**；例外只有入口设备（云 SLB）与控制面浮动 IP（kube-vip）。

---

## 二、宿主机网络（内网 / underlay）

这是“物理/虚拟网络”，节点和上面的一切都跑在它之上。

### 2.1 KVM（drill）
由 `kvm/br-prod.xml` 定义，libvirt 在宿主上创建：

- **桥 `br-prod`**，网段 `192.168.124.0/24`，`<forward mode="nat">`（VM 出网经 NAT）；
- 宿主持有**网关 `192.168.124.1`**（即宿主在 `br-prod` 的 L2 上）；
- libvirt 内置 **dnsmasq**：绑定 `.1:53` 兼做 **DHCP（池 `.100-.200`）+ DNS**；节点按 MAC 静态保留（`.10-.12`/`.20-.21`）；
- 宿主开启 `net.ipv4.ip_forward=1`（`/etc/sysctl.d/99-kvm.conf`）。

**一个常见误区**：宿主在 `.1`、L2 可达；但**宿主的 resolver 不用** libvirt 的 dnsmasq，所以要直接由宿主访问业务域名，需在宿主 `/etc/hosts` 手加记录（见 `implementation-playbook.md`）。

**宿主上的内网服务（都在宿主网络）**：

| 服务 | 地址 | 用途 |
|---|---|---|
| dnsmasq | `192.168.124.1:53/67` | 内网 DNS + DHCP |
| MinIO | `192.168.124.1:9000`（console `:9001`） | 模拟 OSS（对象/备份层） |
| iSCSI portal | `192.168.124.1:3260` | 宿主 ZFS → zvol → 云盘（`app-storage`） |
| ZFS / 备份 | 宿主 `/data` | 存储池与备份目标 |

### 2.2 阿里云 ECS
- **VPC + vSwitch**（按 AZ）；节点是 ECS，**主 ENI** 持私网 IP；
- **安全组**控制入站/出站；
- 内网 DNS 用**云解析 PrivateZone**；
- CP 端点用**内网 SLB**（见第五节）。

### 2.3 裸机
- 节点接 **ToR 交换机**，按 **VLAN** 划分（管理网/业务网）；
- 可双口 **bond + VLAN 子接口**；
- 无 DHCP 时用静态；LB 走 ARP（同 VLAN）或 BGP（上联路由器）。

### 2.4 地址规划
见第九节「网络参数：设置与要求」与第十节「双网段规划」。

---

## 三、容器网络

**先把两个地址空间分清**——这是理解一切的关键：

| | Pod 网络 | Service 网络 |
|---|---|---|
| 地址空间 | `10.244.0.0/16`（**真实**路由的 Pod IP） | `10.96.0.0/12`（**虚拟** IP，不落任何网卡） |
| 生命周期 | 随 Pod 创建/销毁，IP 会回收 | 随 Service 对象，固定不变 |
| 本质 | 真实 L3 连通（veth + VXLAN/native） | DNAT/eBPF 抽象（ClusterIP→后端） |
| 实现 | Cilium IPAM + CNI | Cilium kube-proxy 替换（eBPF） |
| 失败表现 | 跨节点不通 / MTU / 策略拦截 | 无后端 / 端口错 / DNAT 异常 |
| 排障 | `cilium status`、`ip route`、抓包 | `kubectl get endpoints`、`cilium service list` |

Cilium 关键配置（`kubernetes/configs/cilium-values.yaml`）：
`kubeProxyReplacement: true`、`ipam.mode: kubernetes`、`k8sServiceHost: 192.168.124.30`（CP_VIP）、`k8sServicePort: 6443`；数据面默认 **VXLAN 隧道**；hubble 开启。

### 3.1 Pod 网络（工作负载网络）
- **CIDR**：`POD_CIDR=10.244.0.0/16`；每节点从中切一段（kubeadm 默认单节点 `/24` 起）。
- **IPAM**：`mode: kubernetes`，Pod IP 由节点从 PodCIDR 申请、Cilium 分配。
- **每 Pod 一张 veth**：一端在 Pod netns，一端在宿主（Cilium 管理）。
- **Pod↔Pod 路径**：
  ```
  Pod A → veth → Cilium eBPF(policy) → VXLAN 封装 → 宿主①网络 → 对端节点 → 解封装 → Pod B
  ```
  同节点直接经宿主路由；跨节点走 VXLAN（或 native routing）。
- **MTU**：VXLAN 封装开销 50 字节，Pod MTU ≈ underlay MTU − 50；Cilium 默认自动探测。
- **IP 回收**：Pod 删除后 IP 归还节点池。
- **与宿主网关系**：Pod 出集群的流量（访问内网服务/外网）在节点做 **masquerade/SNAT**（见外网一节）。

### 3.2 Service 网络（虚拟 IP 抽象）
Service 是“如何稳定地访问一组 Pod”，**地址是虚拟的**，由 Cilium eBPF 在数据面实现。按类型分：

| 类型 | 地址空间 | 依赖平面 | 谁实现 | 说明 |
|---|---|---|---|---|
| **ClusterIP** | Service CIDR | 容器网络 | Cilium eBPF | 集群内稳定入口，默认类型 |
| **NodePort** | 节点 IP:30000-32767 | **宿主机内网/外网** | Cilium + 节点 | 每节点开同端口 |
| **LoadBalancer** | LB IP | **服务 LB（L2/SLB）** | Cilium LB IPAM / CCM | 对外暴露（见第六节） |
| **ExternalName** | 无 | DNS | CoreDNS | 别名到外部域名 |
| **Headless** | Pod IPs | 容器网络 | DNS(A 记录) | `clusterIP: None`，直连 Pod |

- **ClusterIP 路径**：
  ```
  Pod → ClusterIP:port → Cilium eBPF DNAT → 后端 Pod（可能跨节点）
  ```
- `kubernetes.default`（`10.96.0.1:443`）是内置 ClusterIP，指向真实 apiserver。
- **kube-proxy 已被替换**：全部由 Cilium eBPF 处理（`kubeProxyReplacement: true`）。
- 排障：`kubectl get svc/endpoints`、`cilium service list`、`cilium lb list`。

### 3.3 容器 DNS
- 由 **CoreDNS**（`coredns:v1.11.1`，Tier0）提供，Service 名 `kube-dns`，ClusterIP 通常 `10.96.0.10`；
- Pod 的 `/etc/resolv.conf` 指向它，解析 `svc.cluster.local` 等；
- 与宿主 dnsmasq 是**两套 DNS**（宿主 DNS 解析节点/业务域名，CoreDNS 解析集群内名字）。

---

## 四、外网

区分**出口**与**入口**两件事（drill 默认“只出不进”）：

### 4.1 出口（集群 → 外网）
| 环境 | 机制 |
|---|---|
| KVM | `br-prod` 的 `<forward mode="nat">` + 宿主 `ip_forward`；VM 经宿主 SNAT |
| 阿里云 | NAT 网关 / EIP |
| 裸机 | 默认路由 + 防火墙 SNAT |

用途：拉取上游镜像（引导期）、时钟同步、访问外部依赖。Pod 出网还会经过 Cilium masquerade。

### 4.2 入口（外网 → 业务）
| 环境 | 机制 | 说明 |
|---|---|---|
| KVM（drill） | **无公网入口**，仅内网 VIP + 宿主 `/etc/hosts` | 演练内网可达即可 |
| 阿里云 | **SLB（公网/内网）+ EIP** | 经 CCM 自动创建，见第六节 |
| 裸机 | 公网 LB / 端口 DNAT | 需防火墙放行 |

### 4.3 安全/端口面
外网只放行业务端口（443/80），管理端口（22/6443）限内网；端口矩阵见第九节 8.4。

---

## 五、控制面浮动 IP（kube-vip）——归属内网

> **归属**：控制面浮动 IP（`CP_VIP:6443`）是**内网（underlay）**的一段地址，与节点同二层；**不是外网、不是服务 LB**。

### 5.1 定位
为 `kube-apiserver` 提供稳定的 HA 端点。kubeadm 的 `control-plane-endpoint` 指向它。

### 5.2 部署形态：kubelet 静态 Pod
- `kubernetes/scripts/setup-kube-vip.sh` 在**每台控制面**生成清单并下发到 `/etc/kubernetes/manifests/kube-vip.yaml`；
- kubelet 发现清单自动拉起（**静态 Pod**，`hostNetwork: true`，`args: ["manager"]`）；
- 镜像 `${IMAGE_REPOSITORY}/kube-vip:v${KUBE_VIP_VERSION}`（默认 `v1.2.4`；Harbor 里名字就是 `kube-vip`，见 5.9）；
- 能力：`NET_ADMIN/NET_RAW/SYS_TIME`。

### 5.3 引导时序（关键）
```
① init 前：init-control-plane.sh 手工 ip addr add .30/32 到 cp-1
   （破“endpoint 指向 VIP，而 kube-vip 又要 admin.conf”的循环依赖）
② kubeadm init --control-plane-endpoint=k8s-api.$(DOMAIN):6443
     --apiserver-cert-extra-sans=.30        （证书认 VIP）
③ join worker / join control-plane
④ setup-kube-vip.sh 下发静态 Pod → kubelet 启动 → 接管 .30（leader election）
```
`join-control-plane.sh` 在 join 后对新 CP 同样补部署 kube-vip。

### 5.4 运行配置（env）
| env | 本仓值 | 含义 |
|---|---|---|
| `vip_arp` | `true` | 用 ARP/L2 宣告 |
| `port` | `6443` | 暴露端口 |
| `vip_interface` | `enp1s0`（留空自动探测） | VIP 所在网卡 |
| `vip_subnet` | `32` | VIP 前缀（v1.x 用 `vip_subnet`；v0.8.x 的 `vip_cidr` 已移除） |
| `cp_enable` | `true` | 启用控制面模式 |
| `cp_namespace` | `kube-system` | 命名空间 |
| `vip_leaderelection` | `true` | 用 Kubernetes Lease 选举 |
| `vip_leaseduration` / `vip_renewdeadline` / `vip_retryperiod` | `15` / `10` / `2` | 租约参数（秒） |
| `address` | `192.168.124.30` | VIP |
| `prometheus_server` | `:2112` | 指标端口 |

### 5.5 kubeconfig 与循环依赖
- 挂载宿主 `/etc/kubernetes/kube-vip.conf`（`hostPath`，`FileOrCreate`）到容器 `/.kube/config`；
- 该文件由 `admin.conf` 生成，且把 `server` 改成**本节点 IP**（不指向 VIP），避免自引用循环。

### 5.6 领导选举与故障转移（failover）
- 多个控制面节点用 **client-go Lease** 抢锁，**只有 leader 持有 VIP**；
- leader 故障：在 `vip_leaseduration=15s` 内租约过期，备节点当选 → 重新 `ip addr add` + **免费 ARP** 刷新二层缓存 → 客户端秒级恢复。

### 5.7 VIP 如何“占用并宣告”
`ip addr add .30/32 dev enp1s0`（把 VIP 挂到节点网卡） + ARP 应答/免费 ARP（`vip_arp=true`）。因此**客户端/节点必须与持有者同二层**。

### 5.8 kube-vip 背后的软件与技术栈
kube-vip 是 **Go 单二进制/容器**，直接操作宿主内核网络。其依赖（源码 `go.mod` 实核）：

| 能力 | 底层依赖 | 说明 |
|---|---|---|
| IP/网卡操作 | `vishvananda/netlink`、`netns` | 加/删 VIP 地址、路由 |
| L2/ARP 公告 | `mdlayher/netlink`·`genetlink`·`packet` + `insomniacslk/dhcp` | 免费 ARP/应答（`vip_arp` 用的就是它） |
| IPv6 NDP | `mdlayher/ndp` | IPv6 版“ARP” |
| 服务 LB | `cloudflare/ipvs` + `google/nftables` + `florianl/go-conntrack` | IPVS + nftables + conntrack（服务模式才用） |
| BGP | `osrg/gobgp/v4` | BGP 模式（内嵌 GoBGP） |
| WireGuard | `zx2c4/wgctrl` | WireGuard 模式 |
| UPnP/DDNS | `huin/goupnp`、DHCP 库 | 实验特性 |
| 选举/API | `k8s.io/client-go`（Lease）、`etcd` client | 领导选举、watch Service |
| 指标 | `prometheus/client_golang` | `:2112/metrics` |

**运行时要求**：`hostNetwork` + 能力 `NET_ADMIN/NET_RAW/SYS_TIME`（本仓清单已含）；内核支持 netlink（ARP），按模式需要 IPVS/nftables/conntrack 模块。
**本仓实际启用子集**：只用 **ARP + client-go（Lease）**；未启用 BGP/IPVS 服务模式/WireGuard/Routing Table/UPnP。
**官方文档**：kube-vip.io → `Docs/About/Architecture`。

### 5.9 安装细节（用什么软件 + 流程）
**用什么软件**：kube-vip 本体是单二进制容器镜像 `ghcr.io/kube-vip/kube-vip:v${KUBE_VIP_VERSION}`（默认 `v1.2.4`），同步到本域 Harbor 为 `<IMAGE_REPOSITORY>/kube-vip:v<ver>`；**没有 Helm、没有 cloud-provider、没有额外守护进程**。

**安装方式**：本仓**手写 static Pod 清单**（官方已不再附带发布二进制，故不用 `kube-vip manifest` CLI；也**不是 `kubectl apply`/Helm**），直接放到 kubelet 静态 Pod 目录。因用 `admin.conf`（cluster-admin）作 kubeconfig，**无需 RBAC**。

**流程**：
```
① 镜像准备/预载（集群外）
   registry/images/tier0-core.txt  (kube-vip Tier0)
   make acr-prepare     → prepare-acr-images.sh 导出 tar（Harbor 名=kube-vip，scheme C 特例）
   → push-tars-to-harbor.sh 推 Harbor
   make image-load      → load-images.sh: scp tar → ctr -n k8s.io images import
   make image-preflight → preflight-images.sh 校验；缺则禁止 init
② 节点基础 make k8s-common → install-common.sh（containerd+kubelet；SystemdCgroup；
   sandbox_image=本域 pause；Harbor insecure+robot 认证）
③ 控制面 init（见 5.3 ①②）
④ 部署 kube-vip make kube-vip → setup-kube-vip.sh：
   生成清单（见 5.2/5.4）→ 逐节点 mkdir manifests、生成 kube-vip.conf、scp 清单
   → kubelet 拉起 → 选举 → 接管 VIP
⑤ 扩容 CP join-control-plane.sh：join 后对新 CP 再跑 setup-kube-vip.sh
⑥ 升级 改 KUBE_VIP_VERSION 后重跑 setup-kube-vip.sh（清单更新）
```
`imagePullPolicy: IfNotPresent` → 依赖预载，避免回源公网。

> **升级注意（版本迁移）**：kube-vip v1.x 相对 v0.8.x 有 env 变化——**`vip_cidr` 已移除，改用 `vip_subnet`**（本仓清单已同步）。跨小版本升级建议按官方“regenerate the manifest”方式重生成清单、逐控制面滚动替换静态 Pod 后观察 VIP 漂移；升级前先 `make acr-prepare/image-load` 预载新镜像。

### 5.10 kube-vip vs keepalived（为何本仓不用 keepalived）
> 本仓 CP VIP 由 **kube-vip** 持有，**不是 keepalived**。

| | keepalived | kube-vip（本仓） |
|---|---|---|
| 协议 | **VRRP**（多播 224.0.0.18） | **ARP**（免费 ARP），可选 BGP |
| 选举 | VRRP 优先级/抢占（主机层） | **Kubernetes Lease**（client-go） |
| 依赖 | 纯主机层，不依赖 k8s API | 需 kubeconfig（静态 Pod） |
| 健康检查 | 自定义脚本 | 内置 apiserver 健康检查 / Service |
| 面向 | 通用 VIP | 原生面向 k8s（CP + LoadBalancer svc + BGP） |
| 网络要求 | 需允许 VRRP 多播（云/受管网络常禁用） | 只需 ARP（同二层） |

**替代方案**（都非本仓当前实现）：keepalived(VRRP)、HAProxy+keepalived、外部硬件 LB、云 SLB。

### 5.11 未启用能力 / 边界 / 运维
- **未启用**：BGP、服务模式（`svc_enable`）、WireGuard、Routing Table、云 provider —— 当前只做“控制面 ARP”。
- **边界**：kube-vip 只做 CP VIP；**服务 LB** 交给 Cilium（本地）/SLB（云），见第六节。
- **运维/排查**：`kubectl -n kube-system get pod -l app=kube-vip`、`kubectl -n kube-system logs kube-vip-<node>`、节点上 `ip -br addr` 看 VIP、`curl -k https://192.168.124.30:6443/healthz`。

---

## 六、服务 LB 与两个角色

| | 控制面 LB（内网/集群自身） | 服务 LB（对外业务入口） |
|---|---|---|
| 谁在用 | kubelet、join、Cilium agent、kubectl | 用户/节点/其他系统 |
| 端口 | TCP 6443（仅 API） | 443(经 Gateway)、22、其他 L4 |
| 地址 | `CP_VIP` | `GATEWAY_VIP` + `LB_POOL` |
| 生命周期 | **必须先于集群存在**（引导面） | 依赖集群运行（平台面） |
| 机制 | kube-vip（云=内网 SLB） | Cilium L2 / kube-vip svc / SLB |

**为什么必须分成两个**：用途、生命周期、治理边界不同；共用同一 IP（现状 Gateway 蹭 `CP_VIP:443`）会让 API 高可用受业务入口影响。

### 6.1 服务 LB 的实现选型
| 方案 | 新增组件 | 适用 |
|---|---|---|
| **Cilium LB IPAM + L2**（推荐，本地/裸机） | 无（agent 已在跑） | 同二层 |
| Cilium BGP | 无（agent） | 裸机跨网段 |
| kube-vip svc + cloud-provider | 1 Deployment | 想统一 kube-vip |
| MetalLB | controller+speaker | 通用 L2/BGP |
| **CCM → SLB**（云） | 云 CCM | 阿里云 VPC |

### 6.2 云上为何不能用 Cilium L2
VPC 是**三层路由**、跨 vSwitch 无二层广播域，且云商**ARP 抑制**；必须用 SLB。
**统一原则**：应用侧契约统一（`Service type=LoadBalancer` + Gateway API），实现按环境切换。

---

## 七、数据路径全景

```
[南北向 - 业务]
用户 ─ 域名解析 → GATEWAY_VIP
   │
   ├─[KVM/裸机] Cilium L2 宣告 LB IP ┐
   └─[阿里云]   SLB（外部设备）      ┤
                                     ▼
                     节点 → Cilium eBPF service LB → Pod

[东西向 - 集群内]
Pod ↔ Pod            : Cilium（VXLAN/native）
Pod → ClusterIP      : Cilium eBPF DNAT → Pod

[控制面]
主机层(kubelet/join/Cilium agent) ─ 直接 L2 → CP_VIP:6443 (kube-vip, 内网)
Pod → kubernetes ClusterIP(10.96.0.1) → Cilium DNAT → apiserver 真实 IP:6443
```

---

## 八、三种集群实现方式对比（KVM / 阿里云 ECS / 裸机）

### 8.1 KVM（drill）
```
┌──────────────────── 单台宿主机 ─────────────────────┐
│  br-prod 192.168.124.0/24  (NAT + dnsmasq)          │
│    .1 宿主(网关/DNS/DHCP/MinIO/iSCSI)                │
│    ├─ k8s-cp-1 .10  ┐                                │
│    ├─ k8s-cp-2 .11  ├─ 控制面(kube-vip持.30)         │
│    ├─ k8s-cp-3 .12  ┘                                │
│    ├─ worker-1 .20  ┐                                │
│    └─ worker-2 .21  ┘                                │
│  Pod 网 10.244/16  ← Cilium(VXLAN)                   │
└──────────────────────────────────────────────────────┘
CP 端点: kube-vip .30  服务 LB: Cilium L2（规划）  外网: 仅出口
```

### 8.2 阿里云 ECS（prod）
```
VPC 10.0.0.0/16
 ├─ vSwitch A (AZ-A): cp-1/cp-3/worker-1 (主ENI)
 ├─ vSwitch B (AZ-B): cp-2/worker-2
 ├─ 内网 SLB → kube-apiserver:6443  (controlPlaneEndpoint)
 ├─ 公网 SLB → kgateway:443 (Harbor/GitLab)
 ├─ NAT 网关: 节点出网
 └─ 安全组: 22/6443/443/30000-32767
CP 端点: 内网 SLB  服务 LB: CCM→SLB  外网: SLB+EIP
```

### 8.3 裸机
```
ToR 交换机 (VLAN: 管理/业务)
 ├─ k8s-cp-x  管理VLAN → kube-vip 持 CP_VIP (ARP 或 BGP)
 ├─ k8s-worker-x
 └─ 路由化规模: kube-vip/Cilium BGP 发布 LB IP /32 给 ToR
CP 端点: kube-vip(ARP/BGP)  服务 LB: Cilium L2/BGP  外网: 公网 LB/DNAT
```

### 8.4 维度矩阵
| 维度 | KVM（drill） | 阿里云 ECS（prod） | 裸机 |
|---|---|---|---|
| underlay | libvirt NAT `br-prod` | VPC + vSwitch | VLAN/交换机 |
| 节点 IP 来源 | 静态 DHCP(`NODE_IP_MODE=static`) | VPC ENI(`cloud`) | 静态/DHCP |
| 控制面端点 | kube-vip `CP_VIP`(ARP) | **内网 SLB** | kube-vip(ARP/BGP) |
| 服务 LB | **Cilium L2**(`cilium-l2`) | **CCM→SLB**(`slb`) | Cilium L2/BGP |
| 宣告(`LB_ANNOUNCE`) | `l2` | `cloud` | `l2`/`bgp` |
| LB 地址来源 | `LB_POOL` 手工池 | SLB 分配/固定 EIP | 池/BGP 段 |
| 外网 | 仅出口 NAT | SLB+EIP | 公网 LB/DNAT |
| 容器网络 | Cilium(VXLAN) | Cilium(VXLAN) | Cilium(VXLAN/native) |
| DNS | libvirt dnsmasq | PrivateZone | 企业 DNS |
| 证书 | 自签 | LE DNS-01/云证书 | 企业 CA |
| HA 级别 | 单宿主（伪 HA） | 跨 AZ 真 HA | 物理 HA |
| 存储网络 | 宿主 iSCSI/ZFS | 云盘 CSI | SAN/iSCSI |
| 运维复杂度 | 低 | 中（云依赖） | 高（网络/硬件） |
| 成本 | 低（本机） | 中（按量） | 高（设备） |
| 适用 | 演练/验证 | 生产 | 自建机房 |

> 一致性：**契约统一**（`type=LoadBalancer`+Gateway API）；**实现分环境**（本地 Cilium/云 SLB）。

---

## 九、网络参数：设置与要求

> 变量真源见 [`parameters.md`](parameters.md)。这里强调**设置要求与约束**。

### 9.1 地址与网段
| 参数 | 含义 | 设置要求 |
|---|---|---|
| `NET_CIDR` / `NET_GATEWAY` | 网段/网关 | 网关须在网段内，且**不在 DHCP 池** |
| `CP_IPS` / `WK_IPS` / `*_MACS` | 节点 IP/MAC | 静态、MAC 唯一、**避开 DHCP 池** |
| `CP_VIP` | 控制面浮动 IP | 静态、**避开 DHCP/节点/LB 池**、**与节点同二层** |
| `CP_ENDPOINT` / `:PORT` | 端点域名/端口 | 域名须解析到 `CP_VIP`；端口 `6443` |
| `VIP_IFACE` | VIP 网卡 | 真实网卡名（`ip -br link` 核对） |
| DHCP 池 | 动态地址 | 与上述静态段**互斥** |

### 9.2 容器网络
| 参数 | 含义 | 设置要求 |
|---|---|---|
| `POD_CIDR` | Pod 网 | **不得与节点网/`SERVICE_CIDR`/VPC 重叠**；默认 `/16`，单节点 `/24`；按 Pod 规模选 |
| `SERVICE_CIDR` | Service 网 | 不与 Pod/节点重叠；默认 `/12`，预留 ClusterIP 数量 |
| MTU | Pod MTU | ≈ underlay MTU − 50（VXLAN）；避免分片 |
| Cilium 开关 | `kubeProxyReplacement/ipam/k8sServiceHost` | `true`/`kubernetes`/`CP_VIP:6443` |
| `devices`（多网卡） | Cilium 绑定网卡 | 显式指**管理网**，避免选错 |

### 9.3 入口 / LB
| 参数 | 含义 | 设置要求 |
|---|---|---|
| `LB_IP_MODE` | 实现 | `cilium-l2`\|`kubevip`\|`metallb`\|`slb`\|`none` |
| `LB_ANNOUNCE` | 宣告 | `l2`\|`bgp`\|`cloud` |
| `LB_CLASS` | `loadBalancerClass` | 多后端共存/切换；云上 `alibabacloud` |
| `LB_POOL_START/END` | LB 池 | **同二层(L2)或可路由(BGP)**；避开 DHCP/VIP/节点 |
| `GATEWAY_VIP` | 入口主 IP | drill 固定；prod 留空由 SLB 回写 |

### 9.4 端口矩阵
| 端口 | 用途 | 平面 | drill | 云 | 裸机 |
|---|---|---|---|---|---|
| 6443/tcp | apiserver | 内网 | `CP_VIP` | 内网 SLB | `CP_VIP`/内网 LB |
| 8472/udp | VXLAN（隧道） | 容器↔宿主 | 节点间 | 节点间 | 节点间 |
| 4240/tcp | Cilium 健康 | 容器 | 节点间 | 节点间 | 节点间 |
| 53/tcp,udp | DNS | 内网 | dnsmasq/CoreDNS | PrivateZone/CoreDNS | 企业 DNS/CoreDNS |
| 443/80 | 业务入口 | 外网 | 内网 VIP | SLB/EIP | 公网 LB |
| 22/tcp | SSH | 内网/外网 | 内网 | 跳板机 | 内网 |
| 30000-32767 | NodePort | 宿主/外网 | 默认关/受限 | 安全组限 | 限 |
| 3260/tcp | iSCSI | 内网 | 宿主 | 云盘 CSI | 存储网 |
| 9000/9001 | MinIO | 内网 | 宿主 | OSS | 存储网 |
| 2112/tcp | kube-vip 指标 | 内网 | 节点 | 节点 | 节点 |

### 9.5 约束总表（可校验）
1. 静态段（节点/`CP_VIP`/`GATEWAY_VIP`/LB 池）**互不重叠**且**避开 DHCP 池**；
2. `CP_VIP`、`GATEWAY_VIP`、LB 池**与节点同二层**（L2），否则改 BGP；
3. `POD_CIDR` / `SERVICE_CIDR` **不与任一物理网段重叠**；
4. `CP_ENDPOINT` 域名**解析到 `CP_VIP`**；
5. 外网仅放行业务端口；管理端口限内网。

---

## 十、双网段规划（管理网 / 业务网）

把“集群自身”与“业务入口”在物理上分开，与“两个 LB 角色”一一对应：

```
管理网 br-prod  192.168.124.0/24     业务网 br-svc  192.168.125.0/24
  .1 宿主/网关                           .1 宿主/网关
  .10-.29 节点                           .10-.29 节点副IP(可选)
  .30 CP_VIP (kube-vip)                  .31 GATEWAY_VIP
  .100-.200 DHCP                         .40-.79 LB_POOL
                                           .100-.200 DHCP
```

| 平面 | 用途 | 承载 | LB 角色 |
|---|---|---|---|
| 管理网 | 集群自身 | 节点互通、kubelet、etcd、apiserver、存储 portal | 控制面 LB（`CP_VIP`） |
| 业务网 | 对外入口/服务 | 用户流量、域名入口 | 服务 LB（`GATEWAY_VIP`+`LB_POOL`） |

**落地要点**：新增 `kvm/br-svc.xml`；`create-vm.sh` 加第二 NIC（`enp2s0`）；Cilium 显式 `devices:[enp1s0]`；`CiliumL2AnnouncementPolicy.interfaces:[enp2s0]`；kubelet `--node-ip` 指管理网。
**风险**：多网卡须显式绑管理网；`etcd/apiserver` 地址 init 时固定管理网（安全）；宿主需同时接入两网；iSCSI portal 保持管理网。

> 现状为单网段；双网段为规划项。

---

## 十一、常见疑问（FAQ）

1. **Pod 能访问 `CP_VIP` 吗？** 能，但不必需：Pod 用 `kubernetes` ClusterIP 由 Cilium DNAT 到真实 apiserver。
2. **Cilium 能顶替 kube-vip 做 CP VIP 吗？** 不能，见第五节 5.3。
3. **CP VIP 用 keepalived 吗？** 不用，本仓用 kube-vip，见 5.10。
4. **kube-vip 是 k8s 自带吗？** 不是，是第三方组件；本平台将其作为引导面自带组件部署。
5. **云上为什么不能用 Cilium L2？** VPC 是三层路由 + ARP 抑制；必须 SLB。
6. **统一用 Cilium 可行吗？** KVM/裸机可统一 Cilium（L2/BGP）；云上只能 CCM/SLB。**契约统一，实现分环境**。
7. **`type=LoadBalancer` 一直 pending？** 未部署服务 LB 实现（Cilium LB IPAM/MetalLB/kube-vip svc），或云上未装 CCM。
8. **Pod 和 Service 网络是一回事吗？** 不是：Pod 是真实 IP（`10.244/16`），Service 是虚拟 IP（`10.96/12`），见第三节。

---

## 十二、参数速查
| 变量 | 含义 | 作用域 |
|---|---|---|
| `NET_NAME` / `NET_CIDR` / `NET_GATEWAY` | 网络名/网段/网关 | G |
| `NODE_IP_MODE` | 节点 IP 来源 `static`\|`dhcp`\|`cloud` | G/P |
| `CP_VIP` / `CP_ENDPOINT` / `VIP_IFACE` | 控制面浮动 IP/端点/网卡 | G |
| `POD_CIDR` / `SERVICE_CIDR` | Pod/Service 网段 | G |
| `LB_IP_MODE` | LB 实现 `cilium-l2`\|`kubevip`\|`metallb`\|`slb`\|`none` | G/P |
| `LB_POOL_START` / `LB_POOL_END` | LB IP 池 | G/P |
| `GATEWAY_VIP` | 入口主 IP（prod 由 SLB 回写） | G/P |
| `LB_ANNOUNCE` | `l2`\|`bgp`\|`cloud` | G/P |
| `LB_CLASS` | `loadBalancerClass` | G/P |

> 完整说明见 [`parameters.md`](parameters.md)「节点 / LB IP」。
