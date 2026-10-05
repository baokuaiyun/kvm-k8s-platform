# 镜像管理：预下载清单 + 推送到 Harbor

> 背景：国内网络访问 Docker Hub / gcr.io / quay.io 不稳定，需提前下载基础镜像，推送导入本地 Harbor，集群节点从 Harbor 拉取。

## 一、镜像清单（registry/images-list.txt）

```
# ============ Kubernetes 核心组件 (registry.k8s.io) ============
registry.k8s.io/kube-apiserver:v1.31.0
registry.k8s.io/kube-controller-manager:v1.31.0
registry.k8s.io/kube-scheduler:v1.31.0
registry.k8s.io/kube-proxy:v1.31.0
registry.k8s.io/coredns/coredns:v1.11.1
registry.k8s.io/etcd:3.5.15-0
registry.k8s.io/pause:3.9
registry.k8s.io/metrics-server/metrics-server:v0.7.1

# ============ Cilium CNI (quay.io) ============
quay.io/cilium/cilium:v1.16.0
quay.io/cilium/operator-generic:v1.16.0
quay.io/cilium/hubble-relay:v1.16.0
quay.io/cilium/hubble-ui:v1.16.0
quay.io/cilium/hubble-ui-backend:v1.16.0
quay.io/cilium/certgen:v0.2.0
quay.io/cilium/startup-script:v1.16.0

# ============ Longhorn 存储 (longhornio) ============
longhornio/longhorn-manager:v1.7.0
longhornio/longhorn-engine:v1.7.0
longhornio/longhorn-ui:v1.7.0
longhornio/longhorn-instance-manager:v1.7.0
longhornio/csi-attacher:v4.4.3
longhornio/csi-provisioner:v3.6.3
longhornio/csi-resizer:v1.9.3
longhornio/csi-snapshotter:v6.3.3
longhornio/csi-node-driver-registrar:v2.10.1
longhornio/livenessprobe:v2.13.1

# ============ 监控 (quay.io/registry.k8s.io) ============
quay.io/prometheus/prometheus:v2.54.0
quay.io/prometheus/alertmanager:v0.27.0
quay.io/prometheus/node-exporter:v1.8.2
registry.k8s.io/kube-state-metrics:v2.13.0
quay.io/grafana/grafana:11.1.0
quay.io/prometheus-operator/prometheus-operator:v0.76.0
docker.io/grafana/loki:3.1.0
docker.io/grafana/promtail:3.1.0

# ============ 可观测性 agent ============
otel/opentelemetry-collector-contrib:0.104.0
quay.io/prometheus/blackbox-exporter:v0.25.0

# ============ 运维自动化 ============
kubereboot/kured:1.15.0
registry.k8s.io/descheduler/descheduler:v0.30.0

# ============ Harbor (goharbor) ============
goharbor/harbor-core:v2.11.0
goharbor/harbor-portal:v2.11.0
goharbor/registry-photon:v2.11.0
goharbor/harbor-jobservice:v2.11.0
goharbor/harbor-db:v2.11.0
goharbor/redis-photon:v2.11.0
goharbor/trivy-adapter-photon:v2.11.0

# ============ 数据库 Operator ============
ghcr.io/cloudnative-pg/cloudnative-pg:1.24.0
quay.io/opstree/redis-operator:v0.17.0
quay.io/opstree/redis:v7.2.4

# ============ 常用工具 ============
docker.io/library/busybox:1.36
docker.io/library/nginx:stable-alpine
docker.io/library/alpine:3.20
docker.io/curlimages/curl:8.9.0
docker.io/bitnami/postgresql:16.3.0
docker.io/bitnami/redis:7.2.5

# ============ vCluster ============
ghcr.io/loft-sh/vcluster:0.20.0
ghcr.io/loft-sh/vcluster-k3s:0.20.0

# ============ GitLab ============
registry.gitlab.com/gitlab-org/build/cng/gitlab-webservice-ee:17.2.0
registry.gitlab.com/gitlab-org/build/cng/gitlab-sidekiq-ee:17.2.0
registry.gitlab.com/gitlab-org/build/cng/gitlab-workhorse-ee:17.2.0
```

## 二、下载并推送到 Harbor 脚本

`registry/download-images.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

# 读取变量
source ../variables.mk 2>/dev/null || {
  HARBOR_FQDN="harbor.test.baokuaiyun.com"
  HARBOR_USER="admin"
  HARBOR_PASS="<强密码>"
  HARBOR_PROJECT="k8s-library"
}

IMAGES_FILE="$(dirname "$0")/images-list.txt"
HARBOR_PREFIX="${HARBOR_FQDN}/${HARBOR_PROJECT}"

echo "[+] 登录 Harbor: ${HARBOR_FQDN}"
docker login "${HARBOR_FQDN}" -u "${HARBOR_USER}" -p "${HARBOR_PASS}"

# 确保项目存在（Harbor API）
curl -sk -u "${HARBOR_USER}:${HARBOR_PASS}" \
  -X POST "https://${HARBOR_FQDN}/api/v2.0/projects" \
  -H "Content-Type: application/json" \
  -d "{\"project_name\":\"${HARBOR_PROJECT}\",\"public\":false}" || true

SUCCESS=0; FAILED=0

while IFS= read -r line; do
  # 跳过注释和空行
  [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue

  src_img="$line"
  # 生成 Harbor 目标名：命名空间用 . 连接（Harbor 不支持多级路径）
  # 例: quay.io/cilium/cilium:v1.16.0 → k8s-library/quay.cilium.cilium:v1.16.0
  img_path="${src_img%%:*}"
  img_tag="${src_img##*:}"
  flat_name=$(echo "$img_path" | sed 's|/|.|g')
  dst_img="${HARBOR_PREFIX}/${flat_name}:${img_tag}"

  echo "--- 拉取: ${src_img}"
  if docker pull "${src_img}"; then
    docker tag "${src_img}" "${dst_img}"
    echo "--- 推送: ${dst_img}"
    if docker push "${dst_img}"; then
      SUCCESS=$((SUCCESS+1))
    else
      echo "[!] 推送失败: ${dst_img}"; FAILED=$((FAILED+1))
    fi
    # 清理本地镜像
    docker rmi "${src_img}" "${dst_img}" >/dev/null 2>&1 || true
  else
    echo "[!] 拉取失败: ${src_img}"; FAILED=$((FAILED+1))
  fi
done < "$IMAGES_FILE"

echo ""
echo "[+] 完成。成功: ${SUCCESS}, 失败: ${FAILED}"
```

## 三、离线环境备用方案（无外网时）

```bash
# 方案 A: 有外网的机器先 docker pull + save，scp 到集群后 load
docker pull <镜像> && docker save <镜像> -o /tmp/img.tar
scp /tmp/img.tar kvm-host:/data/images/
ssh kvm-host "docker load -i /data/images/img.tar"

# 方案 B: 用 skopeo 直接跨 registry 同步（无需本地磁盘）
skopeo copy docker://docker.io/library/nginx:alpine \
  docker://harbor.test.baokuaiyun.com/k8s-library/nginx:alpine
```

## 四、containerd mirror 配置（节点指向 Harbor）

`kubernetes/configs/containerd-config.toml`：

```toml
version = 3
[plugins."io.containerd.grpc.v1.cri".registry]
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
      endpoint = ["https://harbor.test.baokuaiyun.com/v2/proxy-docker"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."quay.io"]
      endpoint = ["https://harbor.test.baokuaiyun.com/v2/proxy-quay"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."registry.k8s.io"]
      endpoint = ["https://harbor.test.baokuaiyun.com/v2/proxy-k8s"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."gcr.io"]
      endpoint = ["https://harbor.test.baokuaiyun.com/v2/proxy-gcr"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs."harbor.test.baokuaiyun.com".tls]
    insecure_skip_verify = true   # 演练用自签名，生产改 false
  [plugins."io.containerd.grpc.v1.cri".registry.configs."harbor.test.baokuaiyun.com".auth]
    username = "admin"
    password = "<强密码>"
```

## 五、Harbor Proxy Cache 配置

```
Harbor UI → Project → New Project:
  project: proxy-docker    → Endpoint: https://registry-1.docker.io
  project: proxy-quay      → Endpoint: https://quay.io
  project: proxy-k8s       → Endpoint: https://registry.k8s.io
  project: proxy-gcr       → Endpoint: https://gcr.io

每个项目勾选 "Proxy Cache"，Access Level: Public
```

> 首次拉取走外网缓存到 Harbor，之后所有节点从 Harbor 内网高速拉取。

## 六、验证

```bash
# 推送后验证
docker pull harbor.test.baokuaiyun.com/k8s-library/quay.cilium.cilium:v1.16.0

# containerd 拉取验证（节点上）
crictl pull harbor.test.baokuaiyun.com/k8s-library/nginx:stable-alpine

# 查看镜像同步统计
bash registry/download-images.sh   # 输出 成功/失败 计数
```
