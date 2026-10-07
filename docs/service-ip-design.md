# 服务/业务 IP 设计（平台入口固定 IP + 业务按需 IP）

> 目标：把“**平台入口**”和“**业务暴露**”两类 IP 讲清、可参数配置、可运营，并给出 **KVM / 阿里云 ECS / 裸机** 三种集群的部署差异。
> 关联 [`network-architecture.md`](network-architecture.md)、[`access-gateway.md`](access-gateway.md)、
> [`network-verification.md`](network-verification.md)、[`parameters.md`](parameters.md)。

## 一、两个功能

| 功能 | 定位 | IP 模式 | 承载 |
|---|---|---|---|
| **① 平台入口固定 IP** | 平台服务（Harbor/GitLab/Grafana/Casdoor/ArgoCD）入口 | **1 个固定 IP**（`GATEWAY_VIP`），L7 共享 | Gateway API（按 hostname 分流） |
| **② 业务请求 IP 管理** | 其它业务按需暴露 | **池 + 按需自动分配**（`LB_POOL`），可固定 | `Service type=LoadBalancer`（L4） |

## 二、IP 在哪里（网络平面）

```
管理网（集群自身）          业务网（业务入口/服务，对客户端可达）
  节点 IP / CP_VIP           ① GATEWAY_VIP（固定，L7 共享）
                             ② LB_POOL（池，L4 按需）
```

- 管理网：kubelet/etcd/apiserver、`CP_VIP`（kube-vip / 云内网 SLB）——**内部**。
- 业务网：平台入口与业务服务——**对客户端可达**（KVM 双网卡桥接；云 vSwitch/ENI；裸机 VLAN/桥接）。

## 三、IP 参数化（单一真源）

默认在 [`variables.mk`](../variables.mk)，环境覆盖在 [`gitops/profiles/<env>.env`](../gitops/profiles)。

| 参数 | 含义 | drill | prod(云) |
|---|---|---|---|
| `NET_BIZ_ENABLED` | 是否启用业务网（0=沿用管理网兼容单网段） | `0`（建好 br-lan 后置 1） | — |
| `NET_BIZ_NAME/CIDR/GATEWAY` | 业务网名/网段/网关 | `br-lan`/`192.168.1.0/24`/`.1` | 业务 vSwitch |
| `MGMT_IFACE` / `BIZ_IFACE` | 节点双网卡 | `enp1s0` / `enp2s0` | 主/辅助 ENI |
| `BIZ_HOST_IFACE` | 宿主业务网桥 | `br-lan` | — |
| `LAN_NODE_IPS` | 节点业务网副 IP（静态） | `.230-.234` | ENI 分配 |
| **`GATEWAY_VIP`**（功能①） | 平台入口固定 IP | `.31`（业务网：`BIZ_GATEWAY_VIP=.235`） | 空 → SLB 回写 |
| **`LB_POOL_START/END`**（功能②） | 业务池范围 | `.40-.79`（业务网：`.240-.249`） | 空 → CCM/SLB |
| `LB_IP_MODE` / `LB_ANNOUNCE` / `LB_CLASS` | 实现/宣告/类 | `cilium-l2`/`l2`/空 | `slb`/`cloud`/`alibabacloud` |

> 生效值 `EFF_GATEWAY_VIP` / `EFF_LB_POOL_*` / `EFF_BIZ_IFACE` 由 `NET_BIZ_ENABLED` 自动选择，供渲染消费。

## 四、所需基础设施

| 能力 | KVM(drill) | 阿里云(prod) | 裸机 |
|---|---|---|---|
| L7 控制器 | kgateway（Gateway API） | 同 | 同 |
| 证书 | cert-manager 自签 | cert-manager + DNS-01/云证书 | cert-manager + 企业 CA |
| 服务 LB 实现 | Cilium LB IPAM + L2 | **CCM → SLB** | Cilium L2 / BGP |
| 业务网可达 | **双网卡桥接 br-lan** | 业务 vSwitch + 辅助 ENI | VLAN/桥接 |
| DNS | dnsmasq / LAN DNS | PrivateZone/云解析 | 企业 DNS |

## 五、功能①：平台入口固定 IP（L7）

- 一个固定 IP，写进 Gateway `addresses`（渲染 `platform/gateway/gateway.yaml` 的 `__GATEWAY_VIP__`）。
- 所有平台域名解析到它，Gateway 按 hostname 路由。
- 操作：`make gateway`（渲染+apply）；新增平台服务只需加 `HTTPRoute`，**不消耗新 IP**。

## 六、功能②：业务请求 IP 管理（L4）

- 池（`CiliumLoadBalancerIPPool`，见 `kubernetes/configs/lb-ipam.yaml`）+ L2 公告（`CiliumL2AnnouncementPolicy`）。
- **自动（默认）**：建 `type=LoadBalancer` Service → IPAM **按需分配**，删即回收。
- **固定（可选）**：注解 `io.cilium/lb-ipam-ips: 192.168.1.24x`（drill）；云上绑 EIP / 固定 SLB。

```yaml
# 自动（默认）
kind: Service
metadata: { name: myapp }
spec: { type: LoadBalancer, selector: {app: myapp}, ports: [{port: 80, targetPort: 8080}] }
---
# 固定（需在池内且未占用）
metadata: { annotations: { "io.cilium/lb-ipam-ips": "192.168.1.245" } }
```

## 七、三环境部署差异

| 维度 | KVM（drill） | 阿里云 ECS（prod） | 裸机 |
|---|---|---|---|
| 管理网 | `br-prod`(NAT) | VPC mgmt vSwitch/ENI | 管理 VLAN |
| 业务网 | **双网卡桥接 `br-lan`** | 业务 vSwitch + 辅助 ENI | 业务 VLAN/桥接 |
| ① 固定入口 IP | 固定 `GATEWAY_VIP`（L2 宣告） | **固定 EIP / 内网 SLB** | 固定 VIP（L2/BGP） |
| ② 按需 IP | Cilium LB IPAM + L2 | **CCM 按需建 SLB** | Cilium L2 / BGP |
| 宣告 | ARP | 云代管 | ARP / BGP |
| CP 端点 | kube-vip | 内网 SLB | kube-vip |
| DNS | dnsmasq/LAN DNS | PrivateZone | 企业 DNS |
| 证书 | 自签 | LE/云证书 | 企业 CA |
| 应用契约 | `type=LoadBalancer`+Gateway API（**三环境一致**） | 同 | 同 |

```
[KVM]  用户(LAN) ─ 桥接 br-lan ─► ①GATEWAY_VIP(L7) / ②池IP(Cilium L2) ─► Pod
[云 ]  用户 ─► ①固定EIP-SLB / ②按需SLB ─► NodePort ─► Cilium ─► Pod
[裸机] 用户 ─► ①固定VIP / ②Cilium L2/BGP ─► Pod
```

## 八、运营

| 场景 | 功能①（固定） | 功能②（按需） |
|---|---|---|
| 新增 | 加 `HTTPRoute` | 建 `type=LoadBalancer` Service |
| 指定 IP | 唯一固定，无需 | 注解钉池内 IP |
| 查看 | `kubectl get gateway` | `kubectl get svc -A`；`cilium lb ipam list` |
| 回收 | — | 删 Service 自动回收 |
| DNS | 平台域名 → `GATEWAY_VIP` | 需 DNS 用固定 IP，否则按 IP 用 |
| 验证 | `make verify-network TARGET=lb`（6a L7） | 同（6b L4） |

## 九、落地步骤（KVM）
```
1) 探测 LAN（避开 DHCP/已用）→ 选业务段
2) 宿主建 br-lan（Linux bridge 桥接 eno1）→ 校验宿主在线
3) 节点加第二网卡（enp2s0）+ cloud-init 配副 IP（不设默认网关）
4) 设 NET_BIZ_ENABLED=1；make cni（下发池+L2，功能②）；make gateway（功能①）
5) DNS 指向 GATEWAY_VIP；make verify-network
```
> 云上：建业务 vSwitch/辅助 ENI + 装 CCM；① 用固定 EIP/SLB，② 用按需 SLB。裸机：VLAN/桥接 + Cilium L2（或 BGP）。

## 十、风险
- 切桥断网（需带外控制）；**业务 IP 必须避开 LAN DHCP/已用**；业务网卡**勿设默认路由**（出网仍走管理网 NAT）；云商 ARP 抑制 → 云上不能 Cilium L2。
