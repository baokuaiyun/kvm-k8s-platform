#!/usr/bin/env bash
# 导出本集群 kubeconfig 并【合并】进 ~/.kube/config（绝不覆盖既有配置）
# context/cluster 名由 K8S_CONTEXT 定义（默认 kvm-$(DOMAIN 首段)）
# 用法: export-kubeconfig.sh [cp-ip]
set -euo pipefail

CP1_IP="${1:-${CP_IPS%% *}}"
CP1_IP="${CP1_IP:-192.168.124.10}"
CONTEXT="${K8S_CONTEXT:-kvm-test}"

mkdir -p ~/.kube
TMPKC="$(mktemp)"
trap 'rm -f "$TMPKC"' EXIT

scp -o StrictHostKeyChecking=no root@"${CP1_IP}":/etc/kubernetes/admin.conf "$TMPKC" 2>/dev/null || \
  scp -o StrictHostKeyChecking=no root@"${CP1_IP}":/root/.kube/config "$TMPKC"

# 重命名 cluster/user/context 为唯一名
sed -i \
  -e "s/^  name: kubernetes-admin@kubernetes$/  name: ${CONTEXT}/" \
  -e "s/^  name: kubernetes-admin$/  name: ${CONTEXT}-admin/" \
  -e "s/^- name: kubernetes-admin$/- name: ${CONTEXT}-admin/" \
  -e "s/^  name: kubernetes$/  name: ${CONTEXT}/" \
  -e "s/^    cluster: kubernetes$/    cluster: ${CONTEXT}/" \
  -e "s/^    user: kubernetes-admin$/    user: ${CONTEXT}-admin/" \
  -e "s/^current-context: kubernetes-admin@kubernetes$/current-context: ${CONTEXT}/" \
  "$TMPKC"
cp "$TMPKC" ~/.kube/"${CONTEXT}.config"

# 合并（--raw 保留证书；先备份）
if [ -f ~/.kube/config ]; then
  # 清理同名 cluster/context/user，避免旧集群（重建前）残留导致 CA 冲突
  kubectl --kubeconfig ~/.kube/config config delete-context "$CONTEXT" >/dev/null 2>&1 || true
  kubectl --kubeconfig ~/.kube/config config delete-cluster "$CONTEXT" >/dev/null 2>&1 || true
  kubectl --kubeconfig ~/.kube/config config unset "users.${CONTEXT}-admin" >/dev/null 2>&1 || true
  cp ~/.kube/config ~/.kube/config.bak.$(date +%s)
  KUBECONFIG=~/.kube/config:"$TMPKC" kubectl config view --flatten --raw > ~/.kube/config.merged
  mv ~/.kube/config.merged ~/.kube/config
else
  cp "$TMPKC" ~/.kube/config
fi
kubectl config use-context "${CONTEXT}" >/dev/null 2>&1 || true

echo "[+] kubeconfig 已合并进 ~/.kube/config，context=${CONTEXT}（当前已切换）"
echo "    独立文件: ~/.kube/${CONTEXT}.config"
