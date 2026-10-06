# 本机 KVM 演练环境分阶段实施手册（命令详解）

> ⚠️ **总纲已迁移**：实施顺序与分层以 [`implementation-matrix.md`](implementation-matrix.md) 为准
> （四平面 × 集群定位 × CDM 阶梯 × 规模）。本文保留为**命令与踩坑详解**，四阶段是其一个视图。
>
> 适用范围：**本机单机 KVM 演练环境**（Phase 1）
> 四阶段递进：基础集群 → 安全监控 → 应用+GitOps → 升级维护
> 每阶段有验收标准，通过后再进入下一阶段。
>
> 关联文档：
> - 环境差异 → `environment-differences.md`
> - 阿里云生产部署（演练通过后）→ `alicloud-deployment.md`
> - 域名/证书/镜像迁移 → `baokuaiyun-domain-migration.md`
> - 多租户三模式 → `tenant-isolation-architecture.md`

---

# 阶段 1：基础集群创建

**目标**：先以 **1CP+1W 起步**跑通，再 `make scale-out` 扩到 **3CP+2W HA**。control-plane-endpoint 从一开始就用内网 DNS `k8s-api.test.baokuaiyun.com`（kube-vip VIP），避免后期重签证书。

## 1.1 客户端运维端准备（本地 Linux）

```bash
# 基础工具
sudo apt update && sudo apt install -y openssh-client curl wget git jq vim gnupg

# SSH 密钥
ssh-keygen -t ed25519 -C "ops@baokuaiyun.com" -f ~/.ssh/id_ed25519 -N ""
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@<ECS公网IP>

# SSH 快捷别名
cat >> ~/.ssh/config <<'EOF'
Host kvm-host
    HostName <ECS公网IP>
    User root
    IdentityFile ~/.ssh/id_ed25519

Host k8s-cp-1 k8s-cp-2 k8s-cp-3 k8s-worker-1 k8s-worker-2
    ProxyJump kvm-host
    User root
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR

# 重建 VM 后主机指纹会变，按 IP 直连时也放宽
Host 192.168.124.*
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF

# kubectl
curl -LO "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# vcluster
curl -L -o vcluster "https://github.com/loft-sh/vcluster/releases/latest/download/vcluster-linux-amd64"
chmod +x vcluster && sudo mv vcluster /usr/local/bin/

# 验证
kubectl version --client && helm version && vcluster version
```

## 1.2 KVM 宿主机准备（ECS）

```bash
# 挂载数据盘（前置：阿里云控制台买盘挂到 /dev/sdb）
lsblk
parted /dev/sdb mklabel gpt
parted /dev/sdb mkpart primary ext4 0% 100%
mkfs.ext4 /dev/sdb1
mkdir -p /data
mount /dev/sdb1 /data
UUID=$(blkid -s UUID -o value /dev/sdb1)
echo "UUID=${UUID} /data ext4 defaults,nofail 0 2" >> /etc/fstab
df -h /data

# 安装 KVM 工具链
apt update
apt install -y qemu-kvm libvirt-daemon-system libvirt-clients \
  virtinst bridge-utils cloud-image-utils cpu-checker libguestfs-tools
systemctl enable --now libvirtd
kvm-ok

# 存储目录
mkdir -p /data/kvm/{images,disks,seeds,cloud-init}

# NAT 网络
virsh net-define /dev/stdin <<'NET'
<network>
  <name>br-prod</name>
  <forward mode="nat">
    <nat><port start="1024" end="65535"/></nat>
  </forward>
  <bridge name="br-prod" stp="on" delay="0"/>
  <ip address="192.168.124.1" netmask="255.255.255.0">
    <dhcp>
      <range start="192.168.124.100" end="192.168.124.200"/>
      <host name="k8s-cp-1" ip="192.168.124.10" mac="52:54:00:01:01:01"/>
      <host name="k8s-cp-2" ip="192.168.124.11" mac="52:54:00:01:01:02"/>
      <host name="k8s-cp-3" ip="192.168.124.12" mac="52:54:00:01:01:03"/>
      <host name="k8s-worker-1" ip="192.168.124.20" mac="52:54:00:01:02:01"/>
      <host name="k8s-worker-2" ip="192.168.124.21" mac="52:54:00:01:02:02"/>
    </dhcp>
  </ip>
</network>
NET
virsh net-start br-prod && virsh net-autostart br-prod

# IP 转发
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-kvm.conf
sysctl -p /etc/sysctl.d/99-kvm.conf
```

### 1.2.1 内网 DNS（libvirt 内置 dnsmasq）

libvirt 为 `br-prod` 自动拉起一个 dnsmasq，绑定网关 `192.168.124.1:53` 兼做 DHCP；VM 通过 DHCP 拿到的 DNS 就是它。`kvm/br-prod.xml` 已内置：

```xml
<domain name='test.baokuaiyun.com' localOnly='yes'/>
<dnsmasq:options>
  <dnsmasq:option value='host-record=k8s-api.test.baokuaiyun.com,192.168.124.30'/>
</dnsmasq:options>
```

- `k8s-api.test.baokuaiyun.com` → VIP `192.168.124.30`（1CP+1W 起步阶段的 control-plane-endpoint）。
- `localOnly='yes'`：`test.baokuaiyun.com` 只本地解析，不向公网转发。
- 节点名经 `expand-hosts` 变为 `k8s-cp-1.test.baokuaiyun.com` 等。

应用与验证：

```bash
make network-refresh   # 已激活网络套用 XML 变更（短暂断网）
make dns-check         # dig @192.168.124.1 k8s-api.test.baokuaiyun.com
```

宿主机不在 `br-prod` 内，不查该 dnsmasq，需在宿主机 `/etc/hosts` 追加：

```
192.168.124.30 k8s-api.test.baokuaiyun.com
```

> DNS 只解决「名字→IP」；VIP 本身需由 keepalived/kube-vip 真实持有，否则仍连不通。生产环境改用阿里云 PrivateZone（见 `alicloud-deployment.md`）。

```bash
# 下载 Debian 13 cloud image
cd /data/kvm/images
wget https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2
# 若 IPv4 不通，试 wget -6 <同上>，或在本地下载后 scp 上传
qemu-img info debian-13-generic-amd64.qcow2
```

## 1.3 创建 VM（cloud-init）

```bash
# cloud-init 模板（宿主机 /data/kvm/cloud-init/）
cat > /data/kvm/cloud-init/common-user-data <<'EOF'
#cloud-config
users:
  - name: root
    lock_passwd: false
    ssh_authorized_keys:
      - <粘贴客户端 id_ed25519.pub 内容>
package_update: true
packages:
  - containerd curl wget gnupg2 apt-transport-https ca-certificates jq
  - ipvsadm nfs-common iptables ethtool socat conntrack ebtables
write_files:
  - path: /etc/modules-load.d/k8s.conf
    content: |
      overlay
      br_netfilter
  - path: /etc/sysctl.d/k8s.conf
    content: |
      net.bridge.bridge-nf-call-iptables = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward = 1
runcmd:
  - sysctl --system
  - modprobe overlay
  - modprobe br_netfilter
EOF

cat > /data/kvm/cloud-init/meta-data <<'EOF'
instance-id: k8s-vm
EOF

# 创建 VM 脚本
cat > /data/kvm/create-vm.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
NAME=$1; IP=$2; MAC=$3; VCPU=$4; RAM=$5; DISK=$6
BASE=/data/kvm
cloud-localds $BASE/seeds/$NAME-seed.iso \
  $BASE/cloud-init/common-user-data $BASE/cloud-init/meta-data
qemu-img create -f qcow2 -b $BASE/images/debian-13-generic-amd64.qcow2 \
  -F qcow2 $BASE/disks/$NAME.qcow2 $DISK
virt-install \
  --name $NAME --vcpus $VCPU --memory $RAM \
  --boot uefi \
  --disk path=$BASE/disks/$NAME.qcow2,format=qcow2,bus=virtio \
  --disk path=$BASE/seeds/$NAME-seed.iso,device=cdrom \
  --network bridge=br-prod,mac=$MAC,model=virtio \
  --os-variant debiantrixie --graphics none --noautoconsole --import
SCRIPT
chmod +x /data/kvm/create-vm.sh

# 起步仅创建 1CP(k8s-cp-1) + 1W(k8s-worker-1)
/data/kvm/create-vm.sh k8s-cp-1     192.168.124.10 52:54:00:01:01:01 2 4096 30G
/data/kvm/create-vm.sh k8s-worker-1 192.168.124.20 52:54:00:01:02:01 4 4096 50G

virsh list --all
```

> 仓库脚本版：`make vm-create`（按 `variables.mk` 的 `CP_INIT_COUNT/WK_INIT_COUNT` 建起步节点）；
> 扩容用 `make vm-add-cp IDX=2` / `make vm-add-worker IDX=2`。
> cloud-init 会按节点名注入**唯一 hostname**（`kvm/cloud-init/*-user-data` 的 `__HOSTNAME__`），避免多节点同名。
>
> **必须 `--boot uefi`（OVMF）**：Debian 13 云镜像用传统 BIOS 会 GRUB 反复重启（无内核日志）；
> UEFI 下正常。对应销毁需 `virsh undefine <name> --nvram`。

## 1.4 kubeadm 集群安装（1CP+1W 起步）

> endpoint 全称使用内网 DNS `k8s-api.test.baokuaiyun.com`，指向 kube-vip VIP `192.168.124.30`。
> **镜像必须在本步之前就绪**（见 1.4.0）。完整编排：`make phase1`。
> 详细 ACR 同步见 → `acr-image-sync.md`。

### 1.4.0 镜像准备（init 前必须完成）

宿主机从 ACR/上游拉取，**重命名成本域镜像**，分发导入各节点：

```bash
cp acr.env.example acr.env && vim acr.env   # 填 ACR 用户名/密码
make acr-prepare          # 下载 + 重命名 + 导出 tar（Tier0,Tier1）
make image-load           # scp + ctr -n k8s.io images import
make image-preflight      # 缺失即失败，阻止 init
```

> 命名规则、认证模式、Tier 清单、Helm 覆盖、阶段 3 闭环 → 见 `acr-image-sync.md`。

### 1.4.1 安装 kubelet/kubeadm/containerd（起步节点）

```bash
make k8s-common
# = kubernetes/scripts/install-common.sh
#   先 'cloud-init status --wait' 等 cloud-init 装完 gnupg/containerd
#   再按 K8S_VERSION 主次号拉 apt 源，安装 kubelet/kubeadm/kubectl 并 hold
```

> 常见坑：VM 刚 SSH 通时 cloud-init 可能仍在跑，直接装会 `gpg: command not found`。脚本已内置等待。

> 编排顺序：`make phase1` = 1.4.0 镜像 → 1.4.1 装组件 → **1.4.2 init**（自动绑静态 VIP）→ **1.4.3 join** → **1.4.4 kube-vip 接管** → cni/storage/cert。
> kube-vip 在 **init 之后**部署（见下），不是之前。

### 1.4.2 初始化控制面（cp-1，自动绑静态 VIP）

```bash
make k8s-init
# = kubernetes/scripts/init-control-plane.sh
#   1) 先在 cp-1 上 ip addr add <VIP>/32（引导期静态持有，避免 kube-vip 读 admin.conf(server=VIP) 的循环依赖）
#   2) kubeadm init：
#      --control-plane-endpoint=k8s-api.test.baokuaiyun.com:6443 \
#      --apiserver-cert-extra-sans=<VIP> \        # 关键：否则经 VIP 访问 TLS 校验失败
#      --image-repository=harbor.test.baokuaiyun.com/baokuaiyun   # scheme C（baokuaiyun 单项目）
#      --pod-network-cidr=10.244.0.0/16 --service-cidr=10.96.0.0/12 \
#      --kubernetes-version=v1.31.0 \
#      --cri-socket unix:///run/containerd/containerd.sock --upload-certs
```

- kubeconfig **合并**进宿主机 `~/.kube/config`（context 名由 `K8S_CONTEXT` 定义，默认 `kvm-test`），并自动切换到该 context；**不覆盖**你已有的其他集群配置
- 独立文件 `~/.kube/<K8S_CONTEXT>.config`；随时可 `make kubeconfig` 重新导出/合并
- worker join 命令存到 `.join/worker-join.sh`（24h 有效）

> **误覆盖恢复**（若早期版本把 `~/.kube/config` 冲掉）：
> ```bash
> cp ~/.kube/config ~/.kube/config.bak.$(date +%s)          # 先备份现状
> k3d kubeconfig get kagent     > ~/.kube/k3d-kagent.config
> k3d kubeconfig get my-cluster > ~/.kube/k3d-my-cluster.config
> KUBECONFIG=~/.kube/config:~/.kube/k3d-kagent.config:~/.kube/k3d-my-cluster.config:~/.kube/k3s.config \
>   kubectl config view --flatten --raw > /tmp/kc && mv /tmp/kc ~/.kube/config
> kubectl config use-context kvm-test
> ```
> 关键：`kubectl config view` 必须带 **`--raw`**，否则会脱敏丢证书。

### 1.4.3 加入起步 Worker（worker-1）

```bash
make k8s-join
kubectl get nodes            # cp-1 + worker-1（此时 NotReady，装 CNI 后 Ready）
```

### 1.4.4 部署 kube-vip（init 之后，接管 VIP）

```bash
make kube-vip
# = kubernetes/scripts/setup-kube-vip.sh
#   若节点尚无 kubeconfig：报错提示先 init
#   生成 /etc/kubernetes/kube-vip.conf（由 admin.conf 改写 server 为「本节点IP:6443」）
#   生成 /etc/kubernetes/manifests/kube-vip.yaml（ARP/L2，VIP=<CP_VIP>，网卡 VIP_IFACE）
#   kube-vip 用本节点 kubeconfig 选举成功后会接管 VIP
```

> 为什么 init 后再部署：kube-vip 启动即需一份可用的 kubeconfig；若指向 VIP 则形成循环（VIP 未起 → API 不可达）。
> 引导期先用静态 VIP 让 init 通过，之后 kube-vip 接管即可，扩容到 3CP 时同样适用。

### 1.4.5 扩容到 3CP+2W（HA）

```bash
make scale-out
# = vm-add-cp IDX=2/3 + vm-add-worker IDX=2
#   + join-control-plane cp-2/cp-3（每次现取 certificate-key，规避 2h 过期）
#   + join-worker worker-2
kubectl get nodes           # 5 节点，control-plane 3 台
```

单独扩一台：`make vm-add-cp IDX=2 && make join-cp IDX=2`。

> 注意：`certificate-key` 默认 2h 过期，`join-control-plane.sh` 每次重新
> `kubeadm init phase upload-certs --upload-certs` 现取，无需缓存。

### 1.4.6 实测踩坑与修复（1CP+1W 演练验证）

| 现象 | 根因 | 修复 |
|---|---|---|
| `virsh net-define` 报已存在 | 网络非幂等 | `network-create` 先 `net-info` 判断 |
| VM GRUB 反复重启、无内核日志 | Debian13 云镜像需 UEFI | `virt-install --boot uefi` |
| `cloud-localds` 参数错、VM 建不出 | `-f/-m` 误用 | 位置参数：`cloud-localds seed.iso user-data meta-data` |
| 多 CP 同名 | user-data 写死 hostname | `__HOSTNAME__` 注入唯一主机名 |
| cloud-init 装包极慢 | `deb.debian.org` | cloud-init 覆盖 `debian.sources` 为阿里云镜像 |
| `gpg: command not found` | cloud-init 未完成 | 先 `cloud-init status --wait` |
| apt 装 k8s 报 v3 签名被拒 | k8s 上游 Release 用 v3，Debian13 sqv 拒 | 源用 `[trusted=yes]` |
| kubeadm 报 `pause:3.10` 拉不到 | 清单 pause 写 3.9 | 以 `kubeadm config images list` 为准（3.10） |
| Pod 沙箱报拉 `pause:3.8` | containerd `sandbox_image` 默认 3.8 | 设为 `${本域}/pause:3.10` |
| Pod 卡 `FailedCreatePodSandBox: loopback/cilium-cni not found [/usr/lib/cni]` | containerd `bin_dir` 与插件目录不符 | containerd `bin_dir=/opt/cni/bin` |
| 经 VIP 访问 API TLS 失败 | apiserver 证书 SAN 不含 VIP | init 加 `--apiserver-cert-extra-sans=<VIP>` |
| kube-vip 崩溃/移走 VIP | 启动需 kubeconfig，指向 VIP 成环 | init 后部署，kubeconfig 用「本节点IP」 |
| Cilium operator 拉 `operator-generic-generic` | chart 会自动追加 `-generic` | values 里 repository 用 `.../quay.cilium.operator` |
| Longhorn 崩溃：`iscsiadm` 缺失 | 节点无 open-iscsi | 节点装 `open-iscsi` 并启用 `iscsid` |
| `/tmp` 写入失败、scp 报 Failure | 云镜像 `/tmp` 是 2G tmpfs | 镜像导入用磁盘目录（`/var/lib/k8s-images`） |
| 宿主代理导致国外 TLS 失败 | 代理问题 | 脚本 `BYPASS_PROXY=1` 直连 + 国内镜像源 |

## 1.5 安装 Cilium CNI

> 用 `make cni`（本地 chart + 本域镜像 values，见 `kubernetes/configs/cilium-values.yaml`）。
> 关键：`k8sServiceHost=<VIP>`、`useDigest:false`、operator repository 用 `.../operator`（chart 会补 `-generic`）。

```bash
make cni
kubectl wait -n kube-system --for=condition=Ready pod -l k8s-app=cilium --timeout=300s
```

## 1.6 安装 Longhorn 存储

> 前置：节点需 **open-iscsi**（`make k8s-common` 已装并启用 `iscsid`），否则 longhorn-manager 会因 `iscsiadm` 缺失崩溃。
> 用 `make storage`（本地 chart + 本域镜像 values，副本数取 `LONGHORN_REPLICAS`）。

```bash
make storage
kubectl -n longhorn-system get pods
kubectl get sc   # 期望 longhorn (default)
```

## 1.7 安装 cert-manager + Let's Encrypt

```bash
make cert   # 本地 chart + 本域镜像 values（cert-manager-values.yaml）

# 阿里云 DNS 凭据（DNS-01 挑战用）
kubectl -n cert-manager create secret generic alidns-secret \
  --from-literal=access-key=<ALIBABA_ACCESS_KEY> \
  --from-literal=secret-key=<ALIBABA_SECRET_KEY>

# ClusterIssuer（test/prod 通用，仅域名不同）
cat <<'EOF' | kubectl apply -f -
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
          accessKeySecretRef: {name: alidns-secret, key: access-key}
          secretKeySecretRef: {name: alidns-secret, key: secret-key}
          regionId: cn-hangzhou
EOF

# 通配符证书（test 和 prod 各一份，自动续期）
cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-test
  namespace: cert-manager
spec:
  secretName: wildcard-test-tls
  issuerRef: {name: letsencrypt-prod, kind: ClusterIssuer}
  dnsNames: ["*.test.baokuaiyun.com", "test.baokuaiyun.com"]
EOF

kubectl get certificate -n cert-manager -w   # 等待 Ready=True
```

## 阶段 1 验收

```bash
kubectl get nodes                          # 起步 2 节点 Ready（扩容后 5）
kubectl get pods -A                        # 全 Running
kubectl get sc                             # longhorn
kubectl get certificate -n cert-manager    # Ready=True
```

---

# 阶段 2：安全及运营监控

## 2.1 安全基线

```bash
# 平台命名空间
kubectl create ns platform

# Pod Security Standards（默认 enforce baseline）
cat <<'EOF' | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
# ...（按需配置，此处示意）
EOF

# ResourceQuota 模板（应用到每个租户 ns）
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-quota
  namespace: default
spec:
  hard:
    requests.cpu: "4"
    requests.memory: "8Gi"
    limits.cpu: "8"
    limits.memory: "16Gi"
    persistentvolumeclaims: "5"
EOF

# CiliumNetworkPolicy 默认拒绝跨 ns（模板见租户文档）
# kubectl apply -f infrastructure/tenants/network-policy-template.yaml
```

## 2.2 监控栈（kube-prometheus-stack + Loki）

```bash
# Prometheus + Grafana + Alertmanager
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set alertmanager.enabled=true \
  --set grafana.enabled=true \
  --set grafana.ingress.enabled=true \
  --set grafana.ingress.hosts[0]=grafana.test.baokuaiyun.com

# Loki + Promtail（日志采集）
helm upgrade --install loki grafana/loki \
  --namespace monitoring --create-namespace
helm upgrade --install promtail grafana/promtail \
  --namespace monitoring --create-namespace

kubectl get pods -n monitoring
```

## 2.3 告警规则（示例）

```yaml
# alert-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cluster-alerts
  namespace: monitoring
spec:
  groups:
  - name: node
    rules:
    - alert: NodeDown
      expr: up == 0
      for: 5m
      labels: {severity: critical}
      annotations: {summary: "节点 {{ $labels.node }} 不可用"}
    - alert: HighCPUUsage
      expr: 100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
      for: 10m
      labels: {severity: warning}
```

## 2.4 云原生可观测性 Agent 工具（完整清单）

> 在 2.2 监控栈基础上，补充生产级可观测性所需全部 agent。

### 指标类

| 工具 | 部署方式 | 用途 | 优先级 |
|------|---------|------|--------|
| **Node Exporter** | kube-prometheus-stack 自带 | 节点硬件/OS 指标 | P0 |
| **kube-state-metrics** | kube-prometheus-stack 自带 | K8s 对象状态指标 | P0 |
| **OpenTelemetry Collector** | Helm (Gateway 模式) | 链路追踪 + 指标聚合 | P1 |

### 日志类

| 工具 | 部署方式 | 用途 | 优先级 |
|------|---------|------|--------|
| **Promtail** | DaemonSet | 采集容器日志 → Loki | P0 |
| **Fluent Bit** | DaemonSet（备选）| 高性能日志采集 → Loki/ES | P1 |

### 探测类

| 工具 | 部署方式 | 用途 | 优先级 |
|------|---------|------|--------|
| **Blackbox Exporter** | kube-prometheus-stack 附加 | HTTP/TCP/ICMP 外部端点探测 | P1 |

### 安装命令

```bash
# OpenTelemetry Collector
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm upgrade --install otel open-telemetry/opentelemetry-collector \
  --namespace monitoring --set mode=deployment

# Blackbox Exporter
helm upgrade --install blackbox prometheus-community/prometheus-blackbox-exporter \
  --namespace monitoring

# Fluent Bit（如不用 Promtail）
helm repo add fluent https://fluent.github.io/helm-charts
helm upgrade --install fluent-bit fluent/fluent-bit \
  --namespace monitoring
```

## 2.5 运维自动化 Agent

| 工具 | 用途 | 部署方式 |
|------|------|---------|
| **kured** | 节点安全重启（内核更新后自动 drain+reboot）| Helm |
| **descheduler** | Pod 重调度，负载均衡 | Helm |
| **VPA + Goldilocks** | 资源 Requests/Limits 推荐 | Helm |
| **Popeye** | 集群安全/配置静态分析 | kubectl 插件 |
| **Pluto** | 检查已弃用 API 版本（升级前必查）| kubectl 插件 |

```bash
# kured
helm repo add kured https://kubereboot.github.io/charts
helm upgrade --install kured kured/kured --namespace kube-system

# descheduler
helm repo add descheduler https://kubernetes-sigs.github.io/descheduler/
helm upgrade --install descheduler descheduler/descheduler --namespace kube-system

# Popeye / Pluto（客户端 kubectl 插件，用于升级前检查）
# 在阶段 4 升级前执行
```

## 阶段 2 验收

```bash
kubectl get pods -n monitoring              # Prometheus/Grafana/Loki/OTel/Blackbox 全 Running
# Grafana 可登录，Dashboard 有数据
# Loki 能查到容器日志
# 跨 ns 访问被 NetworkPolicy 拒绝
# 模拟 kill 一个节点，收到 NodeDown 告警
# Blackbox 探测外部端点返回指标
```

---

# 阶段 3：应用部署 + GitOps

> Harbor 与 GitLab 的 **PostgreSQL / Redis 不再各自内置**，统一消费共享的
> `platform-data`（CNPG 多库 + redis-operator）——详见 [`platform-data.md`](platform-data.md)。

## 3.0 共享数据层（先于 Harbor/GitLab）

```bash
make operators        # 安装 cloudnative-pg(>=1.25) + redis-operator
make platform-data    # 建 Cluster/platform-pg(多库) + RedisReplication + ScheduledBackup
# 产物: platform-pg-rw.platform-data.svc:5432 / platform-redis.platform-data.svc:6379
```

## 3.1 Harbor（外部 PG/Redis）

```bash
# values: kubernetes/configs/harbor-values.yaml（database.type=external + redis.type=external）
make platform
# 等价于对 harbor/harbor 1.15.0 用 sed 注入 __PG_HOST__/__REDIS_HOST__ 后 helm install
```

关键 values：

```yaml
database:
  type: external
  external: {host: platform-pg-rw.platform-data.svc.cluster.local, port: "5432",
             username: harbor, coreDatabase: registry, password: <PG_HARBOR_PASS>}
redis:
  type: external
  external: {addr: platform-redis.platform-data.svc.cluster.local:6379, password: <REDIS_PASS>}
```

## 3.2 GitLab（route C：Operator 3.4.1 + CNG CE 19.4.1）

> 现采用 **GitLab route C**（Operator + CNG chart 10.4.1 / v19.4.1），完整步骤见
> [`gitlab-cng-operator.md`](gitlab-cng-operator.md)。旧 `make platform` / chart 8.2.0 已弃用。

```bash
bash registry/push-gitlab-to-harbor.sh          # CNG/Operator 镜像入 Harbor
helm upgrade --install gitlab-operator ...      # 见 gitlab-cng-operator.md
bash platform/gitlab/deploy.sh                  # 建密钥 + apply GitLab CR
```

关键 values（`platform/gitlab/gitlab-cr.yaml`，节选）：

```yaml
global:
  edition: ce
  communityImages:                             # 组件镜像 -> Harbor scheme C 短名
    webservice: {repository: harbor.test.baokuaiyun.com/baokuaiyun/gitlab-webservice-ce}
  psql:  {host: platform-pg-rw.platform-data.svc.cluster.local, port: 5432,
          username: gitlab, database: gitlabhq_production,
          password: {secret: gitlab-pg-cred, key: password}}
  redis: {host: platform-redis.platform-data.svc.cluster.local, port: 6379, database: 3,
          auth: {enabled: true, secret: gitlab-redis-cred, key: password}}
postgresql: {install: false}
redis: {install: false}
```

## 3.3 Flux CD（GitOps）

```bash
# 安装 Flux CLI（客户端）
curl -s https://fluxcd.io/install.sh | bash

# 引导 Flux
export GITHUB_TOKEN=<token>
flux bootstrap github --owner=baokuaiyun --repository=k8s-gitops \
  --branch=main --path=./clusters/kvm --personal

# 仓库结构（Git push 自动同步）
# clusters/kvm/
#   ├── infrastructure/  → Cilium/Longhorn/cert-manager
#   ├── platform/        → Harbor/GitLab/Backstage
#   ├── modes/           → namespace/crossplane/vcluster
#   └── tenants/         → 各租户配置
```

## 3.4 多租户三模式

### Mode A: Namespace 隔离

```bash
# 创建租户（脚本化）
kubectl create ns team-a
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata: {name: quota, namespace: team-a}
spec: {hard: {requests.cpu: "2", requests.memory: "4Gi"}}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: admin, namespace: team-a}
rules:
- apiGroups: ["", "apps", "networking.k8s.io"]
  resources: ["*"]
  verbs: ["*"]
- apiGroups: ["postgresql.cnpg.io"]
  resources: ["clusters", "backups", "scheduledbackups"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: admin-binding, namespace: team-a}
subjects: [{kind: User, name: team-a-admin, apiGroup: rbac.authorization.k8s.io}]
roleRef: {kind: Role, name: admin, apiGroup: rbac.authorization.k8s.io}
EOF
```

### Mode B: Crossplane API 隔离

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm upgrade --install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace

# Provider + XRD + Composition（见 tenant-isolation-architecture.md）
```

### Mode C: vCluster

```bash
# 客户端执行
vcluster create vc-tenant1 -n vc-tenant1 --create-namespace
vcluster connect vc-tenant1 -n vc-tenant1
# 租户 kubeconfig 独立，可装自己的 CRD/Operator
```

## 3.5 共享 Operator（redis-operator + CloudNativePG）

镜像与 chart 均走本域体系（与 Cilium/Longhorn 一致）：

```bash
# 1. 预置 Tier2 镜像（含 operator 本体 + Redis/Postgres 运行时）
make acr-prepare TIERS=Tier0,Tier1,Tier2
make image-load

# 2. 预置 chart（Codeup Git 或上游，见 helm-chart-distribution.md）
make charts-pull

# 3. 安装（Makefile 用 sed 注入 __IMAGE_REPOSITORY__，并等待 rollout）
make operators
# = redis-operator chart 0.16.4  @ ns redis-operator
#   cnpg/cloudnative-pg chart 0.23.2 @ ns cnpg-system
```

- values：`kubernetes/configs/redis-operator-values.yaml`、`kubernetes/configs/cloudnative-pg-values.yaml`
- 镜像清单：`registry/images/` 的 Tier2「运维 / 数据库 Operator」
- 运行时镜像（Redis 实例 / PostgreSQL 实例）由 CR 的 `spec.*.image` 指定，生产须指向本域仓库：

```yaml
# Redis（opstree）—— scheme C 短名
spec:
  image: harbor.test.baokuaiyun.com/baokuaiyun/opstree-redis:v7.0.15
# Cluster (CloudNativePG)
spec:
  imageName: harbor.test.baokuaiyun.com/baokuaiyun/cloudnative-pg-postgresql:16.4
```

## 3.6 镜像迁移（→ 本域 Harbor）

```bash
# 见 docs/image-pipeline.md（scheme C，单项目 baokuaiyun）
# 源镜像 → tar/直传 → harbor.test.baokuaiyun.com/baokuaiyun/<flat>:<tag>
# 配置节点 containerd 指向 Harbor（insecure + robot 认证）
```

## 阶段 3 验收

```bash
crictl pull harbor.test.baokuaiyun.com/baokuaiyun/opstree-redis:v7.0.15  # ✅
# 见 docs/implementation-status.md（实际验收记录）
```

---

# 阶段 4：持续升级和维护

## 4.1 etcd 定时备份（本地 + 异地）

```bash
# 脚本已内置：本地快照 + 异地目录(NFS) + 可选 rsync + 保留策略
OFFSITE_DIR=/data/backups/etcd-offsite OFFSITE_RETENTION_DAYS=30 \
  bash scripts/backup-etcd.sh
# crontab -e  加入: 0 2 * * * OFFSITE_DIR=/data/backups/etcd-offsite /root/k8s/scripts/backup-etcd.sh
```

## 4.2 Velero 备份（集群资源 + PV 文件级）

```bash
# 一键安装（AWS 插件指向 OSS/MinIO）+ 应用每日 Schedule
make velero
# 内部等价于 scripts/velero-install.sh + scripts/velero-schedule.yaml

# 恢复演练
velero backup create test-backup --include-namespaces platform-data
velero restore create --from-backup test-backup
```

## 4.2.1 应用数据一致性备份（L1）

```bash
make app-backup            # CNPG Backup + Harbor dump + GitLab backup + Casdoor dump
make app-restore APP=pg    # 恢复 runbook
make verify-storage        # 存储/备份验收
```

## 4.3 版本升级 SOP

```bash
# Kubernetes 升级（逐节点）
kubectl drain k8s-cp-1 --ignore-daemonsets
ssh k8s-cp-1 "apt install -y kubeadm=1.32.0-1.1 && kubeadm upgrade apply v1.32.0"
ssh k8s-cp-1 "apt install -y kubelet=1.32.0-1.1 kubectl=1.32.0-1.1 && systemctl restart kubelet"
kubectl uncordon k8s-cp-1
# 重复上述流程到其余节点

# Helm 升级
helm list -A
helm upgrade <release> <chart> -n <ns> --values values.yaml
```

## 4.4 证书续期监控

```bash
# cert-manager 自动续期（30 天前），加到期告警
cat <<'EOF' | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata: {name: cert-expiry, namespace: monitoring}
spec:
  groups:
  - name: cert
    rules:
    - alert: CertificateExpiring
      expr: certmanager_certificate_expiration_timestamp_seconds - time() < 604800
      for: 1h
      labels: {severity: warning}
      annotations: {summary: "证书 7 天内到期 {{ $labels.name }}"}
EOF
```

## 4.5 节点维护（kured 安全重启）

```bash
helm repo add kured https://kubereboot.github.io/charts && helm repo update
helm upgrade --install kured kured/kured \
  --namespace kube-system \
  --set configuration.rebootDays="{su}"
```

## 阶段 4 验收

```bash
# Velero 恢复演练成功
# kubeadm 升级演练无中断
# 证书自动续期，收到续期通知
# etcd 快照可恢复
```

---

# 附：四阶段依赖与顺序

```
阶段 1（基础集群）
  └─ 产出：5 节点集群 + CNI + 存储 + 证书
      │
      ▼
阶段 2（安全监控）← 依赖阶段 1
  └─ 产出：RBAC/NetworkPolicy + Prometheus/Grafana/Loki
      │
      ▼
阶段 3（应用+GitOps）← 依赖阶段 1+2
  └─ 产出：Harbor/GitLab + Flux + 三模式租户 + Operator
      │
      ▼
阶段 4（升级维护）← 依赖阶段 3（有应用才有备份意义）
  └─ 产出：etcd/Velero 备份 + 升级 SOP + 续期告警
```

> 完整命令按阶段执行，每阶段通过验收后再进入下一阶段。
