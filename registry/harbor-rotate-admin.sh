#!/usr/bin/env bash
# 轮换 Harbor admin 密码：通过 kubectl exec harbor-core 调 Harbor API（无需对外暴露）
# 用法:
#   HARBOR_ADMIN_CURRENT=<旧密码> [HARBOR_ADMIN_NEW=<新密码>] bash registry/harbor-rotate-admin.sh
# 说明:
#   - 旧密码默认 admin123（首次安装默认）；生产请显式传 HARBOR_ADMIN_CURRENT
#   - 新密码留空则随机生成（openssl rand -hex 12）
#   - 成功后写回 ENVFILE（默认 /root/k8s/acr.env）的 HARBOR_ADMIN_PASS / HARBOR_PASS
set -euo pipefail

NS="${HARBOR_NS:-harbor}"
CUR="${HARBOR_ADMIN_CURRENT:-admin123}"
NEW="${HARBOR_ADMIN_NEW:-$(openssl rand -hex 12)}"
ENVFILE="${ENVFILE:-/root/k8s/acr.env}"

[ "$CUR" = "$NEW" ] && { echo "[!] 新旧密码相同，跳过"; exit 2; }

api() { kubectl -n "$NS" exec deploy/harbor-core -- curl -s "$@"; }

echo "[+] 轮换 Harbor admin 密码（ns=$NS）..."
code=$(api -u "admin:${CUR}" -H 'Content-Type: application/json' \
  -X PUT "http://localhost:8080/api/v2.0/users/1/password" \
  -d "{\"old_password\":\"${CUR}\",\"new_password\":\"${NEW}\"}" \
  -o /dev/null -w '%{http_code}' || true)

if [ "$code" != "200" ]; then
  echo "[!] 修改失败（HTTP ${code:-无}）。旧密码是否正确？(HARBOR_ADMIN_CURRENT)"
  exit 1
fi

upsert() { # key value
  local k="$1" v="$2"
  touch "$ENVFILE"
  if grep -qE "^${k}=" "$ENVFILE"; then
    sed -i "s|^${k}=.*|${k}=${v//|/\\|}|" "$ENVFILE"
  else
    echo "${k}=${v}" >> "$ENVFILE"
  fi
}
upsert HARBOR_ADMIN_PASS "$NEW"
upsert HARBOR_PASS "$NEW"

echo "[+] 完成：已写回 ${ENVFILE}（HARBOR_ADMIN_PASS / HARBOR_PASS）"
echo "    Harbor admin: admin / ${NEW}"
