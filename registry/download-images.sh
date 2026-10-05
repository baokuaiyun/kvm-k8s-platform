#!/usr/bin/env bash
# 预下载镜像并推送到 Harbor（解决国内网络问题）
# 用法: bash download-images.sh
set -euo pipefail

HARBOR_FQDN="${HARBOR_FQDN:-harbor.test.baokuaiyun.com}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-admin123}"
HARBOR_PROJECT="${HARBOR_PROJECT:-k8s-library}"

IMAGES_FILE="$(dirname "$0")/images-list.txt"
HARBOR_PREFIX="${HARBOR_FQDN}/${HARBOR_PROJECT}"

# 检查 docker
command -v docker >/dev/null 2>&1 || { echo "[!] 需要 docker"; exit 1; }

echo "[+] 登录 Harbor: ${HARBOR_FQDN}"
docker login "${HARBOR_FQDN}" -u "${HARBOR_USER}" -p "${HARBOR_PASS}" 2>/dev/null || \
  echo "[!] 登录失败，继续尝试（可能需先跳过）"

# 确保项目存在
curl -sk -u "${HARBOR_USER}:${HARBOR_PASS}" \
  -X POST "https://${HARBOR_FQDN}/api/v2.0/projects" \
  -H "Content-Type: application/json" \
  -d "{\"project_name\":\"${HARBOR_PROJECT}\",\"public\":false}" >/dev/null 2>&1 || true

SUCCESS=0
FAILED=0

while IFS= read -r line; do
  [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue

  src_img="$line"
  img_path="${src_img%%:*}"
  img_tag="${src_img##*:}"
  flat_name=$(echo "$img_path" | sed 's|/|.|g')
  dst_img="${HARBOR_PREFIX}/${flat_name}:${img_tag}"

  echo "--- 拉取: ${src_img}"
  if docker pull "${src_img}" 2>/dev/null; then
    docker tag "${src_img}" "${dst_img}"
    echo "    推送: ${dst_img}"
    if docker push "${dst_img}" 2>/dev/null; then
      SUCCESS=$((SUCCESS+1))
    else
      echo "[!] 推送失败: ${dst_img}"
      FAILED=$((FAILED+1))
    fi
    docker rmi "${src_img}" "${dst_img}" >/dev/null 2>&1 || true
  else
    echo "[!] 拉取失败: ${src_img}"
    FAILED=$((FAILED+1))
  fi
done < "$IMAGES_FILE"

echo ""
echo "[+] 完成。成功: ${SUCCESS}, 失败: ${FAILED}"
