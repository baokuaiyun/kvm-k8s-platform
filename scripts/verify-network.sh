#!/usr/bin/env bash
# 网络平面验收：宿主内网 / DNS / 控制面 VIP / Pod / Service / 服务 LB / 外网
# 用法: bash scripts/verify-network.sh [all|host|dns|vip|pod|svc|lb|egress]
# 退出码: 0=通过（可含 WARN），1=存在 FAIL，2=前置缺失
# 关联文档: docs/network-verification.md / docs/network-architecture.md
set -uo pipefail

TARGET="${1:-all}"

# ---- 参数（来自 variables.mk/profile 的导出；均给默认值）----
ENV="${ENV:-${FLEET_ENV:-drill}}"
NET_NAME="${NET_NAME:-br-prod}"
NET_GATEWAY="${NET_GATEWAY:-192.168.124.1}"
NET_CIDR="${NET_CIDR:-192.168.124.0/24}"
CP_VIP="${CP_VIP:-192.168.124.30}"
CP_ENDPOINT="${CP_ENDPOINT:-k8s-api.test.baokuaiyun.com}"
CP_ENDPOINT_PORT="${CP_ENDPOINT_PORT:-6443}"
VIP_IFACE="${VIP_IFACE:-}"
GATEWAY_VIP="${GATEWAY_VIP:-}"
LB_IP_MODE="${LB_IP_MODE:-cilium-l2}"
LB_ANNOUNCE="${LB_ANNOUNCE:-l2}"
NODE_IP_MODE="${NODE_IP_MODE:-static}"
DOMAIN="${DOMAIN:-test.baokuaiyun.com}"
HARBOR_HOST="${HARBOR_HOST:-harbor.$DOMAIN}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"

FAIL=0
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [WARN] $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=1; }
skip() { echo "  [SKIP] $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# 集群是否可达（决定哪些平面可查）
KUBECTL_OK=0
if have kubectl && kubectl cluster-info >/dev/null 2>&1; then KUBECTL_OK=1; fi

echo "=================================================================="
echo " 网络平面验收  ENV=$ENV"
echo "   网段=$NET_CIDR 网关=$NET_GATEWAY CP_VIP=$CP_VIP 端点=$CP_ENDPOINT:$CP_ENDPOINT_PORT"
echo "   LB_IP_MODE=$LB_IP_MODE LB_ANNOUNCE=$LB_ANNOUNCE GATEWAY_VIP=${GATEWAY_VIP:-<空>} NODE_IP_MODE=$NODE_IP_MODE"
echo "   Pod_CIDR=$POD_CIDR Service_CIDR=$SERVICE_CIDR  kubectl=$([ $KUBECTL_OK -eq 1 ] && echo 可达 || echo 不可达)"
echo "=================================================================="

# ---------------- 1. 宿主内网（underlay） ----------------
check_host() {
  echo "=== 1. 宿主内网（underlay）==="
  if have virsh; then
    if virsh net-info "$NET_NAME" >/dev/null 2>&1; then
      active=$(virsh net-info "$NET_NAME" 2>/dev/null | awk -F: '/Active/{gsub(/ /,"",$2);print $2}')
      ok "libvirt 网络 $NET_NAME 存在（Active=$active）"
      [ "$active" = "yes" ] || bad "网络 $NET_NAME 未激活（make network-create / network-refresh）"
    else
      warn "libvirt 网络 $NET_NAME 不存在（非 KVM 环境可忽略）"
    fi
  else
    skip "无 virsh（非 KVM 宿主），跳过 libvirt 网络检查"
  fi
  if have ping; then
    if ping -c1 -W2 "$NET_GATEWAY" >/dev/null 2>&1; then ok "网关 $NET_GATEWAY 可达"
    else bad "网关 $NET_GATEWAY 不可达"; fi
  else
    skip "无 ping，跳过网关连通性"
  fi
}

# ---------------- 2. 内网 DNS ----------------
check_dns() {
  echo "=== 2. 内网 DNS ==="
  if have dig; then
    out=$(dig @${NET_GATEWAY} "$CP_ENDPOINT" +short 2>/dev/null | head -1)
    if [ -z "$out" ]; then
      bad "$CP_ENDPOINT 未解析（期望 $CP_VIP）；核对 kvm/br-prod.xml + make network-refresh / 宿主 /etc/hosts"
    elif [ "$out" = "$CP_VIP" ]; then
      ok "$CP_ENDPOINT -> $out（= CP_VIP）"
    else
      warn "$CP_ENDPOINT -> $out（期望 $CP_VIP）"
    fi
    for h in "harbor.$DOMAIN" "gitlab.$DOMAIN" "grafana.$DOMAIN" "casdoor.$DOMAIN"; do
      v=$(dig @${NET_GATEWAY} "$h" +short 2>/dev/null | head -1)
      [ -n "$v" ] && ok "$h -> $v" || warn "$h 未解析（如需入口域名，补 dnsmasq host-record）"
    done
  else
    skip "无 dig（apt install dnsutils），跳过 DNS 检查"
  fi
}

# ---------------- 3. 控制面浮动 IP（kube-vip，内网） ----------------
check_vip() {
  echo "=== 3. 控制面浮动 IP（kube-vip，内网）==="
  # API 健康（经 VIP）
  if have curl; then
    if curl -k -s --max-time 5 "https://${CP_VIP}:${CP_ENDPOINT_PORT}/healthz" 2>/dev/null | grep -q ok; then
      ok "经 CP_VIP https://${CP_VIP}:${CP_ENDPOINT_PORT}/healthz = ok"
    else
      bad "经 CP_VIP 访问 apiserver 失败（VIP 未持有 / kube-vip 未运行 / 端口不通）"
    fi
  else
    skip "无 curl，跳过 API 健康检查"
  fi
  if [ "$KUBECTL_OK" -eq 1 ]; then
    pod=$(kubectl -n kube-system get pod -l app=kube-vip --no-headers 2>/dev/null || true)
    if [ -z "$pod" ]; then
      bad "未发现 kube-vip 静态 Pod（app=kube-vip）；make kube-vip"
    else
      running=$(echo "$pod" | grep -c Running || true)
      total=$(echo "$pod" | wc -l)
      [ "${running:-0}" -ge 1 ] && ok "kube-vip Pod Running ${running}/${total}" || bad "kube-vip Pod 非 Running"
    fi
  else
    skip "集群不可达，跳过 kube-vip Pod 检查"
  fi
  # 提示：VIP 实际持有点需在节点上核对
  echo "       [提示] 节点核对: ssh <cp> \"ip -br addr | grep ${CP_VIP}\""
}

# ---------------- 4. Pod 网络（容器网络 - 工作负载） ----------------
check_pod() {
  echo "=== 4. Pod 网络（Cilium）==="
  if [ "$KUBECTL_OK" -ne 1 ]; then skip "集群不可达，跳过"; return; fi
  ds=$(kubectl -n kube-system get ds cilium -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null || true)
  [ -n "$ds" ] && ok "cilium DaemonSet ready=$ds" || bad "未发现 cilium DaemonSet"
  nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  withcidr=$(kubectl get nodes -o jsonpath='{range .items[*]}{.spec.podCIDR}{"\n"}{end}' 2>/dev/null | grep -c . || true)
  [ "${withcidr:-0}" -ge "${nodes:-1}" ] && ok "全部节点已分配 PodCIDR（$withcidr/$nodes）" \
    || bad "有节点未分配 PodCIDR（$withcidr/$nodes）"
  if have cilium; then
    cilium status --brief 2>/dev/null | sed 's/^/       /' || warn "cilium status 失败"
    cilium health status 2>/dev/null | sed 's/^/       /' || true
  else
    echo "       [提示] 有 cilium CLI 时: cilium status / cilium health status"
  fi
  if [ "${NET_VERIFY_CONNECTIVITY:-0}" = "1" ]; then
    warn "跨节点连通全面测试（cilium connectivity test）资源占用大，需手动执行"
  else
    echo "       [提示] 全面连通测试: cilium connectivity test（占用较多 Pod，按需）"
  fi
}

# ---------------- 5. Service 网络（容器网络 - 虚拟 IP） ----------------
check_svc() {
  echo "=== 5. Service 网络（ClusterIP）==="
  if [ "$KUBECTL_OK" -ne 1 ]; then skip "集群不可达，跳过"; return; fi
  if kubectl get svc kubernetes >/dev/null 2>&1; then
    cip=$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    ok "内置 Service kubernetes ClusterIP=$cip"
  else
    bad "缺少内置 Service kubernetes"
  fi
  eps=$(kubectl get endpoints kubernetes -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
  [ -n "$eps" ] && ok "kubernetes Endpoints 非空（apiserver 后端存在）" || bad "kubernetes Endpoints 为空"
  coredns=$(kubectl -n kube-system get pod -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c Running || true)
  [ "${coredns:-0}" -ge 1 ] && ok "CoreDNS Running ${coredns}" || bad "CoreDNS 未 Running（容器 DNS 不可用）"
  if have cilium; then cilium service list 2>/dev/null | head -8 | sed 's/^/       /' || true; fi
}

# ---------------- 6. 服务 LB（LoadBalancer 类型） ----------------
check_lb() {
  echo "=== 6. 服务 LB（type=LoadBalancer）==="
  if [ "$KUBECTL_OK" -ne 1 ]; then skip "集群不可达，跳过"; return; fi
  lb=$(kubectl get svc -A --no-headers 2>/dev/null | awk '$3=="LoadBalancer"{print $1"/"$2, $5}' || true)
  if [ -z "$lb" ]; then
    warn "当前无 type=LoadBalancer 的 Service（M2 落 Cilium L2 后应出现）"
    return
  fi
  echo "$lb" | while read -r name ip; do
    case "$ip" in
      *pending*|"") echo "  [FAIL] $name EXTERNAL-IP=pending（LB 实现未生效：LB_IP_MODE=$LB_IP_MODE）" ;;
      *) echo "  [OK]   $name EXTERNAL-IP=$ip" ;;
    esac
  done
  echo "$lb" | grep -q pending && FAIL=1
  if [ "$LB_IP_MODE" = "cilium-l2" ]; then
    if have cilium; then
      n=$(cilium lb list 2>/dev/null | grep -c . || true)
      echo "       cilium LB IP（${n:-0} 条）"; cilium lb list 2>/dev/null | head -5 | sed 's/^/       /' || true
    fi
  fi
}

# ---------------- 7. 外网（出口/入口） ----------------
check_egress() {
  echo "=== 7. 外网（出口/入口）==="
  if have curl; then
    if curl -k -sI --max-time 5 "https://${HARBOR_HOST}" >/dev/null 2>&1; then
      ok "本域 Harbor https://${HARBOR_HOST} 可达"
    else
      warn "本域 Harbor https://${HARBOR_HOST} 不可达（DNS/入口/证书，见 access-gateway.md）"
    fi
  else
    skip "无 curl，跳过"
  fi
  [ "$NODE_IP_MODE" = "cloud" ] && echo "       [提示] 云上外网: SLB/EIP + NAT 网关（见 alicloud-deployment.md）"
}

# ---------------- 调度 ----------------
run_one() {
  case "$1" in
    host)   check_host ;;
    dns)    check_dns ;;
    vip)    check_vip ;;
    pod)    check_pod ;;
    svc)    check_svc ;;
    lb)     check_lb ;;
    egress) check_egress ;;
    *)      echo "[!] 未知检查: $1"; exit 2 ;;
  esac
}

if [ "$TARGET" = "all" ]; then
  check_host; check_dns; check_vip; check_pod; check_svc; check_lb; check_egress
else
  run_one "$TARGET"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "[+] 网络验收通过（WARN/SKIP 项请按提示确认）"
else
  echo "[!] 网络验收存在失败项"
fi
exit "$FAIL"
