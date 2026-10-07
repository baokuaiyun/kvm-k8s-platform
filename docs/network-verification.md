# 网络验证（Network Verification）

> 目标：把 [`network-architecture.md`](network-architecture.md) 里定义的 **4 个网络平面 + 两个 LB 角色**变成**可执行、可复现、可入库**的核对。
> 风格与 `make verify-storage` 等一致：**退出码即结论**；证据可入 `evidence/`。
> 关联 [`network-architecture.md`](network-architecture.md)、[`evidence-and-acceptance.md`](evidence-and-acceptance.md)、[`parameters.md`](parameters.md)。

## 一、一键验证

```bash
make verify-network                    # 全部平面（ENV=drill）
make verify-network TARGET=host        # 只查宿主内网
make verify-network TARGET=dns|vip|pod|svc|lb|egress
make verify-network ENV=prod           # 生产（云，自动跳过 ARP 类检查）
```

- 退出码：`0`=通过（可含 WARN/SKIP），`1`=存在 FAIL，`2`=前置缺失。
- 已纳入 `make verify`（全量验收）与 `make evidence`（证据包，check 名 `network_verify`）。

## 二、检查分区（7 项）

| # | 分区 | 对应平面 | 关键检查 |
|---|---|---|---|
| 1 | `host` | 宿主机内网（underlay） | 网桥/网关/连通 |
| 2 | `dns` | 内网 DNS | `CP_ENDPOINT`→`CP_VIP`；入口域名解析 |
| 3 | `vip` | 控制面浮动 IP（kube-vip，**内网**） | kube-vip Pod、API `/healthz` |
| 4 | `pod` | 容器网络 · Pod | Cilium DaemonSet、节点 PodCIDR |
| 5 | `svc` | 容器网络 · Service | `kubernetes` ClusterIP/Endpoints、CoreDNS |
| 6 | `lb` | 服务 LB | `type=LoadBalancer` 的 EXTERNAL-IP |
| 7 | `egress` | 外网 | 本域 Harbor 可达 |

## 三、逐项：命令 / 期望 / 排障

### 1. 宿主内网（host）
```bash
virsh net-info br-prod          # Active: yes
ping -c1 192.168.124.1          # 网关可达
```
- **期望**：网络 Active、网关可 ping。
- **排障**：`make network-create` / `make network-refresh`；网关 = 宿主 `br-prod` 地址。

### 2. 内网 DNS（dns）
```bash
dig @192.168.124.1 k8s-api.test.baokuaiyun.com +short   # → 192.168.124.30
dig @192.168.124.1 harbor.test.baokuaiyun.com +short    # → 入口 VIP
```
- **期望**：`CP_ENDPOINT` 解析为 `CP_VIP`；业务域名解析为入口 VIP。
- **排障**：改 `kvm/br-prod.xml` 的 `host-record` → `make network-refresh`；宿主另需 `/etc/hosts`（宿主不查 guest dnsmasq）。

### 3. 控制面浮动 IP（vip，内网）
```bash
kubectl -n kube-system get pod -l app=kube-vip        # Running
curl -k https://192.168.124.30:6443/healthz           # ok
ssh <cp> "ip -br addr | grep 192.168.124.30"          # leader 持有
```
- **期望**：kube-vip Running、`/healthz=ok`、某 CP 网卡持有 VIP。
- **排障**：`make kube-vip`；确认静态 Pod 清单 `/etc/kubernetes/manifests/kube-vip.yaml`、`kube-vip.conf`、网卡 `VIP_IFACE`；见 `network-architecture.md` 第五节。

### 4. Pod 网络（pod）
```bash
kubectl -n kube-system get ds cilium                  # ready=desired
kubectl get nodes -o wide                             # 每节点有 PodCIDR
cilium status
cilium health status
```
- **期望**：Cilium 全 ready、节点有 PodCIDR、health 全通。
- **全面连通测试（按需，资源占用较大）**：
  ```bash
  cilium connectivity test          # 部署较多测试 Pod
  ```
- **排障**：`cilium status` 看 agent；跨节点不通优先查 VXLAN(8472)/MTU/`bridge-nf-call-*`。

### 5. Service 网络（svc）
```bash
kubectl get svc kubernetes
kubectl get endpoints kubernetes                      # 非空
kubectl -n kube-system get pod -l k8s-app=kube-dns    # CoreDNS Running
cilium service list
```
- **期望**：ClusterIP 存在、Endpoints 非空、CoreDNS Running。
- **排障**：无后端→查目标 Pod/selector；解析失败→查 CoreDNS。

### 6. 服务 LB（lb）

**6a 平台入口 L7（共享固定 IP，需 SNI）**
```bash
# 用域名 + 指定解析到 GATEWAY_VIP（无需改 DNS）
curl -k --resolve harbor.test.baokuaiyun.com:443:<GATEWAY_VIP> \
  https://harbor.test.baokuaiyun.com/                 # → 200
```
> drill 实际：`<GATEWAY_VIP>` = `192.168.1.235`（业务网）；命令即
> `curl -k --resolve harbor.test.baokuaiyun.com:443:192.168.1.235 https://harbor.test.baokuaiyun.com/`

**6b 业务按需池（L4）**
```bash
kubectl get svc -A | grep LoadBalancer                # EXTERNAL-IP 应已分配
curl -s http://<POOL_IP>/                             # → 200（示例；drill 池 192.168.1.240-249）
```

- **期望**：L7 固定 VIP 有响应；L4 池内 IP 已分配且可访问（drill = Cilium L2 池；prod = SLB）。
- **⚠️ 验证方式说明（重要，别踩坑）**：
  - `ping <GATEWAY_VIP>` **不通是正常的**：LB VIP 是 Service 前端，Cilium L2/eBPF **只做 TCP/UDP，不回复 ICMP**。健康检查请用 **TCP/HTTP**（`curl`/`nc`），不要用 ping。
  - **裸 IP** `curl -k https://<GATEWAY_VIP>/` 会 **`Connection reset`**：Gateway 为**虚拟主机 TLS**（listener 绑定 `*.test.baokuaiyun.com`），握手**必须带 SNI**；`-H 'Host: ...'` 只设 HTTP 头、**不等于 SNI**。
  - **正确访问/验证姿势（任选）**：
    ```bash
    curl -k https://harbor.test.baokuaiyun.com/                                    # a) 域名（DNS 指向 VIP）
    curl -k --resolve harbor.test.baokuaiyun.com:443:<GATEWAY_VIP> https://harbor.test.baokuaiyun.com/   # b) 强制解析到 VIP
    openssl s_client -connect <GATEWAY_VIP>:443 -servername harbor.test.baokuaiyun.com                    # c) 带 SNI 握手
    ```
  - 若需**裸 IP 可访问 / 可 ping**：采用「无 SNI 默认 listener / 宿主副 IP+DNAT / kube-vip 服务模式」之一，见 [`service-ip-design.md`](service-ip-design.md)。
- **pending 排障**：
  - drill：未部署 LB 实现（缺 `CiliumLoadBalancerIPPool` / Cilium L2）→ 见 `network-architecture.md` 第六节；确认 `LB_IP_MODE=cilium-l2`。
  - prod：CCM 未装或 SLB 创建失败（查 CCM 事件/RAM 权限）。

### 7. 外网（egress）
```bash
curl -kI https://harbor.test.baokuaiyun.com           # 200/302
```
- **期望**：本域 Harbor 可达（节点拉镜像依赖）。
- **排障**：DNS/入口 Gateway/证书；见 `access-gateway.md`。

## 四、drill 与 prod 差异

| 检查 | drill（KVM） | prod（阿里云） |
|---|---|---|
| host | libvirt `br-prod` | VPC/vSwitch（跳过 virsh） |
| dns | dnsmasq | PrivateZone |
| vip | kube-vip（ARP） | 内网 SLB（`CP_ENDPOINT`） |
| lb | Cilium L2 | CCM → SLB |
| egress | 宿主 NAT | NAT 网关 / EIP |

> `make verify-network ENV=prod` 会自动跳过 `virsh` 等非云检查；ARP 类检查对云无意义。

## 五、证据入库

```bash
make evidence CHECKS="network_verify"     # 或并入默认证据包
# 产出: evidence/<env>/<ts>/{report.json,report.md,network_verify.log}
```
`report.json` 记录本项退出码与日志尾部，可与 prod 对比，体现“仅 env/config 差异”。

## 六、常用工具速查

| 目的 | 命令 |
|---|---|
| DNS 解析 | `dig @<gw> <name> +short`、`getent hosts <name>` |
| API 健康 | `curl -k https://<CP_VIP>:6443/healthz` |
| VIP 持有 | 节点 `ip -br addr` |
| 端口连通 | `nc -zv <ip> <port>`、`curl -v` |
| 路径追踪 | `mtr <ip>`、`traceroute` |
| Cilium | `cilium status`、`cilium health status`、`cilium service list`、`cilium lb list` |
| 抓包 | `tcpdump -ni <iface> arp` / `port 8472` |

## 七、常见故障定位表

| 现象 | 可能原因 | 处置 |
|---|---|---|
| `CP_ENDPOINT` 不解析 | dnsmasq 无记录 / XML 未 refresh | 改 `br-prod.xml` + `make network-refresh` |
| 经 VIP 访问 API 失败 | kube-vip 未运行 / VIP 未持有 | `make kube-vip`，查静态 Pod |
| Pod 跨节点不通 | VXLAN 端口/MTU/防火墙 | 查 8472、MTU、`bridge-nf-call-*` |
| Service 无后端 | selector/endpoints | `kubectl describe svc`、查 Pod |
| LoadBalancer pending | 无 LB 实现 / CCM | 配 Cilium L2 或云 CCM |
| `ping <VIP>` 不通 | VIP 不回 ICMP（**正常**） | 用 TCP/HTTP 探测（`curl`/`nc`），别用 ping |
| 裸 IP `curl https://<VIP>/` reset | 无 SNI（虚拟主机 TLS） | 用域名或 `curl --resolve ...` 带 SNI |
| Harbor 不可达 | 入口/DNS/证书 | 见 `access-gateway.md` |
