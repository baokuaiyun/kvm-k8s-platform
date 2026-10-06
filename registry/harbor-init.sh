#!/usr/bin/env bash
# Harbor 初始化：建项目(私有) + 建 robot(pushpull) + 改 admin 密码
# 通过 kubectl exec harbor-core 调 Harbor API（无需对外暴露）
# 用法: harbor-init.sh
set -euo pipefail

NS="${HARBOR_NS:-harbor}"
PROJECT="${HARBOR_PROJECT:-baokuaiyun}"
NEW_ADMIN="${HARBOR_ADMIN_PASS:-$(openssl rand -hex 12)}"
# 当前(安装时)的 admin 密码，用于鉴权
CUR_ADMIN="${HARBOR_ADMIN_CURRENT:-admin123}"
ROBOT_NAME="pushpull"
ENVFILE="${ENVFILE:-/root/k8s/acr.env}"

api() { kubectl -n "$NS" exec deploy/harbor-core -- curl -s "$@"; }

echo "[+] 1) 建项目 ${PROJECT}（私有）"
api -u "admin:${CUR_ADMIN}" -H 'Content-Type: application/json' \
  -X POST "http://localhost:8080/api/v2.0/projects" \
  -d "{\"project_name\":\"${PROJECT}\",\"metadata\":{\"public\":\"false\"}}" \
  -o /dev/null -w '    HTTP %{http_code}\n' || true

echo "[+] 2) 建 robot ${ROBOT_NAME}（push+pull）"
BODY=$(cat <<EOF
{"name":"${ROBOT_NAME}","description":"pushpull for ${PROJECT}","duration":-1,"level":"project",
 "permissions":[{"kind":"project","namespace":"${PROJECT}",
   "access":[{"resource":"repository","action":"push"},{"resource":"repository","action":"pull"}]}]}
EOF
)
RESP=$(api -u "admin:${CUR_ADMIN}" -H 'Content-Type: application/json' \
  -X POST "http://localhost:8080/api/v2.0/robots" -d "$BODY")
echo "    resp: $(echo "$RESP" | head -c 200)"
ROBOT_FULL=$(echo "$RESP" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('name',''))" 2>/dev/null || true)
ROBOT_SECRET=$(echo "$RESP" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('secret',''))" 2>/dev/null || true)

echo "[+] 3) 修改 admin 密码"
api -u "admin:${CUR_ADMIN}" -H 'Content-Type: application/json' \
  -X PUT "http://localhost:8080/api/v2.0/users/1/password" \
  -d "{\"old_password\":\"${CUR_ADMIN}\",\"new_password\":\"${NEW_ADMIN}\"}" \
  -o /dev/null -w '    HTTP %{http_code}\n' || true

echo "[+] 4) 写入凭据到 ${ENVFILE}"
touch "$ENVFILE"
upsert() { # key value
  local k="$1" v="$2"
  if grep -qE "^${k}=" "$ENVFILE"; then
    sed -i "s|^${k}=.*|${k}=${v//|/\\|}|" "$ENVFILE"
  else
    echo "${k}=${v}" >> "$ENVFILE"
  fi
}
upsert HARBOR_PROJECT "$PROJECT"
upsert HARBOR_ADMIN_PASS "$NEW_ADMIN"
upsert HARBOR_PASS "$NEW_ADMIN"
[ -n "$ROBOT_FULL" ] && upsert HARBOR_ROBOT_USER "$ROBOT_FULL"
[ -n "$ROBOT_SECRET" ] && upsert HARBOR_ROBOT_PASS "$ROBOT_SECRET"

echo ""
echo "[+] 完成。"
echo "    项目:   ${PROJECT} (private)"
echo "    robot:  ${ROBOT_FULL:-robot\$${PROJECT}+${ROBOT_NAME}}"
echo "    admin 密码已更新（见 ${ENVFILE} 的 HARBOR_ADMIN_PASS）"
