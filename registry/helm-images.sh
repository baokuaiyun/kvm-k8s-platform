#!/usr/bin/env bash
# 从 Helm chart 提取镜像引用，生成可追加到 registry/images/ 的行
# 用法: helm-images.sh <release> <chart> [-f values.yaml ...]
# 输出: "<src>  <dst>  Tier2"（本域 dst = 全路径 / 换 .）
# 说明: 尽力而为（chart 模板差异大），生成后请人工核对再追加
set -euo pipefail

[ "$#" -ge 2 ] || { echo "用法: helm-images.sh <release> <chart> [-f values...]"; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "[!] 需要 helm"; exit 1; }

helm template "$@" 2>/dev/null \
  | grep -Eo '([a-z0-9-]+\.)+[a-z0-9-]+/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+' \
  | grep -vE '^(localhost|127\.)' \
  | sort -u \
  | while read -r src; do
      path="${src%%:*}"
      dst=$(echo "$path" | tr '/' '.')
      printf '%s\t%s\tTier2\n' "$src" "$dst"
    done
