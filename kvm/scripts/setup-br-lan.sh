#!/usr/bin/env bash
# 业务网桥 br-lan：桥接物理网卡（默认 eno1），把宿主 IP 迁到桥上
# 用途：为 KVM 节点提供业务网二层接入（D 方案，192.168.1.0/24 等）
# 幂等：br-lan 已存在则跳过；失败自动回滚到物理口直连
# 注意：会短暂影响宿主网络，请在带外/可控环境下运行
set -euo pipefail

BR="${BIZ_HOST_IFACE:-br-lan}"
UPL="${BIZ_HOST_UPLINK:-eno1}"
GW="${NET_BIZ_GATEWAY:-192.168.1.1}"
HOSTIP="${HOST_LAN_IP:-}"

[ -n "$HOSTIP" ] || HOSTIP="$(ip -o -4 addr show "$UPL" 2>/dev/null | awk '{print $4}' | head -1)"
[ -n "$HOSTIP" ] || { echo "[!] 无法确定宿主 IP（设 HOST_LAN_IP=192.168.1.251/24）"; exit 2; }

if ip link show "$BR" >/dev/null 2>&1; then
  echo "[=] $BR 已存在，跳过"
  exit 0
fi

echo "[+] 创建 $BR（桥接 $UPL，宿主 $HOSTIP，网关 $GW）"
ip link add name "$BR" type bridge
ip link set "$BR" up
ip addr add "$HOSTIP" dev "$BR"
ip link set "$UPL" master "$BR"
ip route replace default via "$GW" dev "$BR" 2>/dev/null || true
ip addr del "$HOSTIP" dev "$UPL" 2>/dev/null || true

sleep 2
if ping -c2 -W2 "$GW" >/dev/null 2>&1; then
  echo "[+] $BR 就绪，网关 $GW 可达"
  echo "    持久化请同步 /etc/network/interfaces（bridge-ports $UPL）"
else
  echo "[!] 网关 $GW 不可达，回滚"
  ip addr add "$HOSTIP" dev "$UPL" 2>/dev/null || true
  ip link set "$UPL" nomaster 2>/dev/null || true
  ip link del "$BR" 2>/dev/null || true
  ip route replace default via "$GW" dev "$UPL" 2>/dev/null || true
  exit 1
fi
