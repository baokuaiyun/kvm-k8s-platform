# 本机 KVM 演练环境分阶段实施手册

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

### 1.4.2 部署 kube-vip（init 之前，提供 VIP）

```bash
make kube-vip
# = kubernetes/scripts/setup-kube-vip.sh
#   生成 /etc/kubernetes/manifests/kube-vip.yaml 分发到 cp-1
#   ARP/L2 模式，VIP=192.168.124.30，网卡取 variables.mk 的 VIP_IFACE（默认 enp1s0）
```

> 网卡名不确定时：登录节点 `ip -br link` 确认，改 `variables.mk` 的 `VIP_IFACE`。

### 1.4.3 初始化控制面（cp-1）

```bash
make k8s-init
# = kubernetes/scripts/init-control-plane.sh，等价于：
# kubeadm init \
#   --control-plane-endpoint=k8s-api.test.baokuaiyun.com:6443 \
#   --image-repository=harbor.test.baokuaiyun.com/k8s-library \
#   --pod-network-cidr=10.244.0.0/16 \
#   --service-cidr=10.96.0.0/12 \
#   --kubernetes-version=v1.31.0 \
#   --cri-socket unix:///run/containerd/containerd.sock \
#   --upload-certs
```

- kubeconfig 自动拉到宿主机 `~/.kube/config`
- worker join 命令存到 `.join/worker-join.sh`（24h 有效）

### 1.4.4 加入起步 Worker（worker-1）

```bash
make k8s-join
kubectl get nodes -w        # cp-1 + worker-1 均 Ready
```

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

## 1.5 安装 Cilium CNI

```bash
helm repo add cilium https://helm.cilium.io && helm repo update
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=192.168.124.30 \
  --set k8sServicePort=6443 \
  --set ipam.mode=kubernetes

kubectl wait -n kube-system --for=condition=Ready pod -l k8s-app=cilium --timeout=300s
```

## 1.6 安装 Longhorn 存储

```bash
helm repo add longhorn https://charts.longhorn.io && helm repo update
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace \
  --set defaultSettings.defaultReplicaCount=1   # 起步 2 节点；扩容到 3 节点后改 $(LONGHORN_REPLICAS)

kubectl wait -n longhorn-system --for=condition=Available deployment longhorn-ui --timeout=300s
kubectl get sc   # 期望 longhorn 出现
```

## 1.7 安装 cert-manager + Let's Encrypt

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --set installCRDs=true

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

## 3.1 Harbor

```bash
helm repo add harbor https://helm.goharbor.io && helm repo update
helm upgrade --install harbor harbor/harbor \
  --namespace harbor --create-namespace \
  --set expose.type=clusterIP \
  --set externalURL=https://harbor.test.baokuaiyun.com \
  --set expose.tls.secretName=wildcard-test-tls \
  --set harborAdminPassword=<强密码> \
  --set persistence.enabled=true \
  --set persistence.persistentVolumeClaim.registry.storageClass=longhorn \
  --set metrics.enabled=true
```

## 3.2 GitLab

```bash
helm repo add gitlab https://charts.gitlab.io && helm repo update
cat > gitlab-values.yaml <<'EOF'
global:
  hosts:
    domain: test.baokuaiyun.com
    https: true
  ingress:
    configureCertmanager: false
    tls: {secretName: wildcard-test-tls}
certmanager: {install: false}
nginx-ingress: {enabled: false}
gitlab: {webservice: {minReplicas: 1}}
registry: {enabled: false}
postgresql: {install: true, persistence: {size: 30Gi}}
redis: {install: true, persistence: {size: 10Gi}}
EOF
helm upgrade --install gitlab gitlab/gitlab \
  --namespace gitlab --create-namespace --timeout 600s -f gitlab-values.yaml
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

## 3.5 共享 Operator

```bash
# redis-operator
helm repo add ot-helm https://ot-container-kit.github.io/helm-charts && helm repo update
helm upgrade --install redis-operator ot-helm/redis-operator \
  --namespace redis-operator --create-namespace

# CloudNative PG
helm repo add cnpg https://cloudnative-pg.github.io/charts && helm repo update
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace
```

## 3.6 镜像迁移（阿里云 CR → Harbor）

```bash
# 见 baokuaiyun-domain-migration.md 第四节
# docker pull → tag → push harbor.baokuaiyun.com/k8s-library/...
# 配置 containerd mirror 指向 Harbor
```

## 阶段 3 验收

```bash
docker pull harbor.test.baokuaiyun.com/k8s-library/nginx:alpine  # ✅
# git push → Flux 自动部署                                         # ✅
# 租户 A 无法访问租户 B                                             # ✅
# Backstage 自助创建 PG                                             # ✅
# vCluster 内装独立 Operator                                       # ✅
```

---

# 阶段 4：持续升级和维护

## 4.1 etcd 定时备份

```bash
cat > /data/kvm/backup-etcd.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DATE=$(date +%Y%m%d-%H%M%S)
DIR=/data/backups/etcd
mkdir -p $DIR
ssh k8s-cp-1 "etcdctl snapshot save /tmp/etcd-$DATE.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key"
scp k8s-cp-1:/tmp/etcd-$DATE.db $DIR/
# 保留最近 7 天
find $DIR -name "*.db" -mtime +7 -delete
EOF
chmod +x /data/kvm/backup-etcd.sh
# crontab -e  加入: 0 2 * * * /data/kvm/backup-etcd.sh
```

## 4.2 Velero 备份（PV + 灾难恢复）

```bash
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.9.0 \
  --bucket velero-backup \
  --secret-file ./credentials-velero \
  --use-volume-snapshots=false \
  --backup-location-config region=oss-cn-hangzhou

# 定时备份
velero schedule create daily-backup --schedule="0 3 * * *" --ttl 168h

# 恢复演练
velero backup create test-backup --include-namespaces default
velero restore create --from-backup test-backup
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
