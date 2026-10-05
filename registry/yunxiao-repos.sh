#!/usr/bin/env bash
# 查询云效制品仓库列表（用于获取 Helm 仓库地址/确认已创建）
# 用法: yunxiao-repos.sh [repoType]   # 如 HELM / DOCKER / MAVEN / NPM / GENERIC
# 依赖: YUNXIAO_TOKEN, YUNXIAO_ORG_ID（见 acr.env）
set -euo pipefail

: "${YUNXIAO_TOKEN:?YUNXIAO_TOKEN 未设置（见 acr.env）}"
: "${YUNXIAO_ORG_ID:?YUNXIAO_ORG_ID 未设置（见 acr.env）}"

DOMAIN="${YUNXIAO_DOMAIN:-openapi-rdc.aliyuncs.com}"
TYPE="${1:-}"

# 子命令: codeup -> 列代码库
if [ "$TYPE" = "codeup" ]; then
  curl -s --max-time 30 -H "x-yunxiao-token: ${YUNXIAO_TOKEN}" \
    "https://${DOMAIN}/oapi/v1/codeup/organizations/${YUNXIAO_ORG_ID}/repositories?perPage=100&page=1" \
    | python3 -c '
import sys, json
d = json.load(sys.stdin)
if not isinstance(d, list):
    print("响应:", json.dumps(d, ensure_ascii=False)); sys.exit(0)
print("共", len(d), "个代码库")
for r in d:
    print("-", (r.get("nameWithNamespace") or r.get("name")), "|", r.get("httpUrlToRepo"))
'
  exit 0
fi

API="https://${DOMAIN}/oapi/v1/packages/organizations/${YUNXIAO_ORG_ID}/repositories"
QUERY="perPage=100&page=1"
[ -n "$TYPE" ] && QUERY="repoTypes=${TYPE}&${QUERY}"

curl -s --max-time 30 -H "x-yunxiao-token: ${YUNXIAO_TOKEN}" "${API}?${QUERY}" \
  | python3 -c '
import sys, json
d = json.load(sys.stdin)
if not isinstance(d, list):
    print("响应:", json.dumps(d, ensure_ascii=False)); sys.exit(0)
if not d:
    print("(无仓库)"); sys.exit(0)
for r in d:
    print("{:8} | {:8} | {:8} | {} | {}".format(
        r.get("repoType",""), r.get("repoCategory",""), r.get("accessLevel",""),
        r.get("repoName",""), r.get("repoId","")))
'
