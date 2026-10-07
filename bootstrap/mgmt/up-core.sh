#!/usr/bin/env bash
# 引导面：集群核心（CNI/存储/证书/网关）
set -euo pipefail
source "$(dirname "$0")/../lib.sh"

log "Cilium CNI"
m cni
log "存储后端（按 STORAGE_BACKEND，默认 host-zfs-iscsi 云盘模拟）"
m storage
log "规范 StorageClass (app-storage)"
m storage-class
log "cert-manager"
m cert
log "kgateway（Gateway API 控制器，chart 走 Harbor）"
bypass helm upgrade --install kgateway "oci://${HARBOR_HOST}/${HARBOR_PROJECT}/kgateway" \
  --version 2.4.5 -n kgateway-system --create-namespace 2>/dev/null || \
  warn "kgateway 安装失败（检查 chart/CRD）"
log "自签 Issuer/通配证书 + Gateway（platform/gateway）"
kubectl apply -f "$BOOT_ROOT/platform/gateway/namespace.yaml" 2>/dev/null || true
kubectl apply -f "$BOOT_ROOT/platform/gateway/selfsigned-issuer.yaml" 2>/dev/null || true
kubectl apply -f "$BOOT_ROOT/platform/gateway/wildcard-cert.yaml" 2>/dev/null || true
kubectl apply -f "$BOOT_ROOT/platform/gateway/gateway.yaml" 2>/dev/null || true
log "核心就绪"
