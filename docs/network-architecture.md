# 网络架构与 LB 设计

> 本文是**网络相关内容的单一入口**：分层模型、地址规划、数据路径、LB 架构、三环境差异、双网段规划与常见疑问。
> 关联 [`parameters.md`](parameters.md)、[`access-gateway.md`](access-gateway.md)、[`environment-differences.md`](environment-differences.md)、
> [`alicloud-deployment.md`](alicloud-deployment.md)、[`implementation-playbook.md`](implementation-playbook.md)。
>
> 参数单一真源：[`variables.mk`](../variables.mk)（G 默认）<- [`gitops/profiles/<env>.env`](../gitops/profiles)（P 覆盖，`make ... ENV=<env>`）<- `acr.env`（S 密钥）。

## 一、分层模型

从下到上一共 6 层，每层职责与“由谁负责”如下：

| # | 层 | 内容 | 负责组件 |
|---|---|---|---|
| L0 | 物理/underlay | 宿主网桥(`br-prod`)、VPC/vSwitch、交换机 VLAN | libvirt / 云 / 交换机 |
| L1 | 节点网（管理网） | 节点 IP、网关、DHCP/DNS | dnsmasq / VPC / 企业 DHCP |
| L2 | 控制面 VIP | kube-apiserver 端点 `CP_VIP:6443` | **kube-vip**（云上=内网 SLB） |
| L3 | Pod 网络（东西向） | pod↔pod | **Cilium**（CNI，VXLAN/native） |
| L4 | Service 网络（东西向） | ClusterIP | **Cilium**（kube-proxy 替换，eBPF） |
| L5 | 入口/服务 LB（南北向） | Gateway 443、L4 LB IP | **Cilium L2**（本地）/ **SLB**（云） |

> 关键点：**L3–L5 的集群数据面几乎全部经过 Cilium 的 eBPF datapath**；例外只有两个——入口设备（云 SLB）与控制面 VIP（kube-vip）。

## 二、地址与网段规划

### 2.1 现状（drill，单网段）
`kvm/br-prod.xml`：libvirt NAT 网络 `192.168.124.0/24`。

| 区段 | 用途 |
|---|---|
| `.1` | 宿主/网关（dnsmasq 兼 DHCP/DNS） |
| `.10-.12` / `.20-.21` | 控制面 / Worker 节点（按 MAC 静态保留） |
| `.30` | `CP_VIP`（kube-vip 独占，仅 API 6443） |
| `.100-.200` | DHCP 池 |
| `.31` / `.40-.79` | （规划）`GATEWAY_VIP` / LB IP 池 |

### 2.2 规划（双网段）
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

> 现状为单网段；双网段为规划项，落地要点见第七节。

## 三、数据路径详解

### 3.1 Pod ↔ Pod（东西向）
```
Pod A → veth → Cilium eBPF(policy/lb) → [VXLAN 隧道 | native] → Pod B
```
全程 Cilium。

### 3.2 Pod → Service（ClusterIP，东西向）
```
Pod → ClusterIP → Cilium eBPF DNAT → 后端 Pod（可能跨节点）
```
全程 Cilium（kube-proxy 被替换）。

### 3.3 南北向入口（业务 Service）
```
用户
 │ 域名解析 → GATEWAY_VIP
 ▼
[KVM/裸机] Cilium L2 宣告 LB IP ─┐
[阿里云]   SLB（外部设备）      ─┤
                                ▼
                        节点 → Cilium eBPF service LB → Pod
```
- **本地/裸机**：入口第一跳就是 Cilium（L2 公告 + eBPF）。
- **云上**：入口第一跳是 SLB；**进入节点后仍由 Cilium** 转发到 Pod。

### 3.4 控制面 VIP（集群自身）
```
主机层组件(kubelet / kubeadm join / Cilium agent) ── 直接 L2 ──► CP_VIP:6443 (kube-vip)
Pod ──► kubernetes ClusterIP(10.96.0.1) ──► Cilium DNAT ──► apiserver 真实 IP:6443
Pod(显式访问 CP_VIP) ──► 节点 underlay L2 ──► CP_VIP        （可通，但非必需）
```

## 四、LB 架构：两个角色

| | 控制面 LB（内网/集群自身） | 服务 LB（对外业务入口） |
|---|---|---|
| 谁在用 | kubelet、join、Cilium agent、kubectl | 用户/节点/其他系统 |
| 端口 | TCP 6443（仅 API） | 443(经 Gateway)、22、其他 L4 |
| 地址 | `CP_VIP` | `GATEWAY_VIP` + `LB_POOL` |
| 生命周期 | **必须先于集群存在**（引导面） | 依赖集群运行（平台面） |
| 机制 | kube-vip（云上=内网 SLB） | Cilium L2 / kube-vip svc / SLB |

**为什么必须分成两个**：用途、生命周期、治理边界都不同；共用同一 IP（如现状 Gateway 蹭 `CP_VIP:443`）会让 API 高可用受业务入口影响。

## 五、为什么 CP VIP 必须用 kube-vip（FAQ 核心）

**Cilium 无法提供控制面 VIP**，原因是启动顺序（鸡生蛋）：

```
要起 Cilium agent → 要调度 Pod → 要有 apiserver → 要有 control-plane-endpoint(CP_VIP)
                                                          ↑ 此刻 Cilium 还不存在
```

三条硬约束：
1. Cilium agent 是 **DaemonSet**，依赖 apiserver 调度；`kubeadm init` 完成前不存在。
2. Cilium **没有** host/static-pod 模式来持有节点级 VIP；其 LB 能力只面向 **Service**（LB IPAM/L2/BGP）。
3. `control-plane-endpoint` 在 init 时固化进 apiserver 证书 SAN、kubeconfig、etcd/kubelet 引导。

反过来说：**Cilium 是 kube-vip 的下游**——`kubernetes/configs/cilium-values.yaml` 里 `k8sServiceHost: 192.168.124.30` 正是指向 kube-vip 的 VIP。

可替代 kube-vip 的现实方案（都非 Cilium）：外部 LB（HAProxy+keepalived/硬件）、keepalived(VRRP)、云 SLB。

## 六、三环境差异

| 维度 | KVM（drill） | 阿里云 ECS（prod） | 裸机 |
|---|---|---|---|
| underlay | libvirt NAT `br-prod` | VPC + vSwitch | VLAN/交换机 |
| 节点 IP | 静态 DHCP(`NODE_IP_MODE=static`) | VPC ENI 分配(`cloud`) | 静态/DHCP |
| 控制面端点 | kube-vip `CP_VIP`(ARP) | **内网 SLB** 作 controlPlaneEndpoint | kube-vip(ARP/BGP) |
| 服务 LB | **Cilium L2**(`LB_IP_MODE=cilium-l2`) | **CCM→SLB**(`slb`) | Cilium L2 / BGP |
| 宣告方式(`LB_ANNOUNCE`) | `l2` | `cloud` | `l2` / `bgp` |
| LB 地址来源 | `LB_POOL` 手工池 | SLB 分配/固定 EIP | 池 / BGP 段 |
| DNS | libvirt dnsmasq | 云解析 PrivateZone | 企业 DNS |
| 证书 | 自签 | LE DNS-01 / 云证书 | 企业 CA / 内部 ACME |
| `LB_CLASS` | 空（用默认） | `alibabacloud` | 空 / 自定义 |

> **统一性**：应用侧契约统一（`Service type=LoadBalancer` + Gateway API）；**实现**在云上必须换 SLB（VPC 是 L3，且云商 ARP 抑制，Cilium L2 不可用）。

## 七、双网段落地要点与风险

**改动面（规划）**
- 变量：`NET_MGMT_*` / `NET_SVC_*`、`SVC_IFACE`、`SVC_DHCP_*`；`GATEWAY_VIP`/`LB_POOL_*` 归业务网。
- KVM：新增 `kvm/br-svc.xml`；`Makefile:network-create` 定义两张网；`kvm/scripts/create-vm.sh` 加第二 NIC；cloud-init 配 `enp2s0`。
- Cilium：显式 `devices: [enp1s0]`；`CiliumL2AnnouncementPolicy.interfaces=[enp2s0]`。
- kubelet `--node-ip` 固定管理网 IP。

**风险**
- **多网卡 + Cilium**：必须显式 `devices` 且 `--node-ip` 指管理网，否则选错网卡。
- **etcd/apiserver 地址**：init 时固定管理网，加第二网卡不影响（安全）。
- **宿主**：需同时接入 `br-prod`、`br-svc` 才能直接访问服务 VIP。
- **iSCSI portal**（现 `NET_GATEWAY=192.168.124.1`）保持管理网。
- **DNS**：可两网各一 dnsmasq，或集中管理网。

## 八、常见疑问（FAQ）

1. **Pod 能访问 CP_VIP 吗？** 能，但不必需：Pod 用 `kubernetes` ClusterIP 由 Cilium DNAT 到真实 apiserver。
2. **Cilium 能顶替 kube-vip 做 CP VIP 吗？** 不能，见第五节。
3. **云上为什么不能用 Cilium L2？** VPC 是三层路由、无跨 vSwitch 二层广播域，且云商 ARP 抑制；必须用 SLB。
4. **统一用 Cilium 可行吗？** KVM/裸机可统一 Cilium（L2，必要时 BGP）；云上只能用 CCM/SLB。**契约统一，实现分环境。**
5. **`type=LoadBalancer` 一直 pending？** 未部署服务 LB 实现（Cilium LB IPAM/MetalLB/kube-vip svc），或云上未装 CCM。

## 九、参数速查

| 变量 | 含义 | 作用域 |
|---|---|---|
| `NET_NAME` / `NET_CIDR` / `NET_GATEWAY` | 网络名/网段/网关 | G |
| `NODE_IP_MODE` | 节点 IP 来源 `static`\|`dhcp`\|`cloud` | G/P |
| `CP_VIP` / `CP_ENDPOINT` / `VIP_IFACE` | 控制面 VIP/端点/网卡 | G |
| `LB_IP_MODE` | LB 实现 `cilium-l2`\|`kubevip`\|`metallb`\|`slb`\|`none` | G/P |
| `LB_POOL_START` / `LB_POOL_END` | LB IP 池 | G/P |
| `GATEWAY_VIP` | 入口主 IP（prod 由 SLB 回写） | G/P |
| `LB_ANNOUNCE` | `l2`\|`bgp`\|`cloud` | G/P |
| `LB_CLASS` | `loadBalancerClass` | G/P |

> 完整说明见 [`parameters.md`](parameters.md)「节点 / LB IP」。
