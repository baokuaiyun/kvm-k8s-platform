# 生产同构入口：LB → Gateway → Harbor

> 目标：演练与生产**同一套入口架构**——`LB → Gateway → Harbor(443, TLS)`。演练用 kgateway + 自签证书；生产换内网 SLB + 受信任证书。
> 网络分层、地址规划、数据路径与三环境差异详见 [`network-architecture.md`](network-architecture.md)（本文只讲入口这一段）。

## 一、生产架构（正常做法）

```
用户/节点
  │ HTTPS (harbor.<domain>:443)
  ▼
内网 SLB（生产） / VIP（演练）
  ▼
kgateway（Gateway API，TLS 终止）
  ├─ /v2, /service, /api, /  → harbor-core (80)
  └─ registry 流量            → harbor-registry (5000)
  ▼
Harbor Pods
```

- **TLS**：生产用受信任证书（cert-manager + Let's Encrypt DNS-01，或阿里云 SSL 证书）。
- **DNS 内外分离**：内网解析给节点拉镜像；公网入口给用户（或仅内网 + VPN）。
- **registry 不直接暴露公网**。

## 二、演练实现（kgateway + 自签）

当前 KVM 集群无 Gateway API/kgateway（cert-manager 已装）。步骤：

```bash
# 1) 安装 kgateway（Gateway API CRD + 控制器）——chart 先本地 vendor
#    本地: /data/kvm/charts/kgateway-*.tgz
helm upgrade --install kgateway <chart> -n kgateway-system --create-namespace

# 2) cert-manager 自签 ClusterIssuer + 通配符证书
#    (见 platform/gateway/selfsigned-issuer.yaml)
kubectl apply -f platform/gateway/selfsigned-issuer.yaml   # ClusterIssuer: selfsigned
kubectl apply -f platform/gateway/wildcard-cert.yaml       # Certificate *.test.baokuaiyun.com -> secret wildcard-test-tls

# 3) Gateway（监听 VIP:443）+ HTTPRoute（harbor）
kubectl apply -f platform/gateway/gateway.yaml
kubectl apply -f platform/gateway/harbor-route.yaml
```

内网 DNS：`kvm/br-prod.xml` 的 dnsmasq 增 `harbor.test.baokuaiyun.com → 192.168.124.30`；宿主机 `/etc/hosts` 同步。

## 三、镜像/节点访问

- Harbor 域名：`https://harbor.test.baokuaiyun.com`（演练自签）。
- 节点 containerd：`insecure_skip_verify=true`（演练）；用 robot 认证（见 `image-pipeline.md` 第六节）。
- 生产：证书受信任，`insecure_skip_verify=false`。

## 四、生产替换清单

| 演练 | 生产 |
|---|---|
| 自签 ClusterIssuer/Certificate | cert-manager DNS-01(LE) 或阿里云证书 |
| Gateway VIP `192.168.124.30:443` | 内网 SLB → kgateway |
| libvirt dnsmasq | 阿里云 PrivateZone（内网解析） |

## 五、验证

```bash
curl -kI https://harbor.test.baokuaiyun.com            # 200/302
kubectl get gateway,httproute -A
kubectl get certificate -A                             # wildcard Ready=True
ssh <node> 'crictl pull <harbor>/baokuaiyun/<img>:<tag>'
```
