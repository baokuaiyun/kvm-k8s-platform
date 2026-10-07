#!/usr/bin/env bash
# 验收证据（Proof）：运行一组验收检查，产出可追溯的证据包（report.json + report.md + 原始日志）。
# 证据 = 命令 + 输出 + 退出码 + 环境 + git commit + 时间（+ 制品摘要）。
# 用法: bash scripts/evidence.sh            # 默认 ENV=drill
#       ENV=prod CHECKS="nodes sc storage" bash scripts/evidence.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ENV="${ENV:-${FLEET_ENV:-drill}}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${ROOT}/evidence/${ENV}/${TS}"
mkdir -p "$OUT"

log() { echo "[+] $*"; }

# ---------- 环境元数据 ----------
GIT_COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY="$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
K8S_VER="$(kubectl version -o json 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("serverVersion",{}).get("gitVersion",""))' 2>/dev/null)"
DOMAIN_VAL="${DOMAIN:-}"; STORAGE_BACKEND_VAL="${STORAGE_BACKEND:-}"
LOCK_HASH=""
[ -f "$ROOT/gitops/locks/all-in-one-${ENV}-all.lock" ] && LOCK_HASH="$(sha256sum "$ROOT/gitops/locks/all-in-one-${ENV}-all.lock" | cut -d' ' -f1)"

# ---------- 检查注册 ----------
# 每项: "key|描述|命令"
CHECKS_DEF=(
  "nodes|集群节点就绪|kubectl get nodes -o wide"
  "storage_class|StorageClass 契约|kubectl get sc"
  "csi|CSI 控制器/节点|kubectl -n democratic-csi get pods -o wide"
  "snapshot_class|快照类|kubectl get volumesnapshotclass"
  "storage_verify|存储验收|make -C $ROOT verify-storage"
  "network_verify|网络平面验收|make -C $ROOT verify-network"
  "helm|Helm 发布|helm list -A"
)

# 允许用 CHECKS="nodes sc storage_verify" 过滤
FILTER="${CHECKS:-}"
should_run() { [ -z "$FILTER" ] && return 0; case " $FILTER " in *" $1 "*) return 0;; esac; return 1; }

RESULTS_FILE="$OUT/results.tsv"
: > "$RESULTS_FILE"
log "证据包: $OUT（ENV=$ENV, commit=${GIT_COMMIT:0:10}）"

for def in "${CHECKS_DEF[@]}"; do
  IFS='|' read -r key desc cmd <<< "$def"
  should_run "$key" || continue
  log "  - ${key}: ${desc}"
  start=$(date +%s)
  bash -c "$cmd" >"$OUT/${key}.log" 2>&1
  rc=$?
  dur=$(( $(date +%s) - start ))
  status=pass; [ "$rc" -ne 0 ] && status=fail
  printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$desc" "$status" "$rc" "$dur" >> "$RESULTS_FILE"
done

# ---------- 生成 report.json / report.md ----------
python3 - "$OUT" "$ENV" "$GIT_COMMIT" "$GIT_DIRTY" "$K8S_VER" "$DOMAIN_VAL" "$STORAGE_BACKEND_VAL" "$LOCK_HASH" "$TS" <<'PY'
import sys, os, json
out, env, commit, dirty, k8s, domain, backend, lockhash, ts = sys.argv[1:10]
results = []
with open(os.path.join(out, "results.tsv")) as f:
    for line in f:
        key, desc, status, rc, dur = line.rstrip("\n").split("\t")
        try:
            tail = open(os.path.join(out, key + ".log")).read().splitlines()[-8:]
        except Exception:
            tail = []
        results.append({"check": key, "description": desc, "status": status,
                        "exit_code": int(rc), "seconds": int(dur), "tail": tail})
report = {
    "env": env, "timestamp": ts,
    "git_commit": commit, "git_dirty_files": int(dirty),
    "k8s_server_version": k8s, "domain": domain, "storage_backend": backend,
    "artifact_lock_sha256": lockhash,
    "summary": {
        "total": len(results),
        "pass": sum(1 for r in results if r["status"] == "pass"),
        "fail": sum(1 for r in results if r["status"] == "fail"),
    },
    "results": results,
}
json.dump(report, open(os.path.join(out, "report.json"), "w"), ensure_ascii=False, indent=2)

md = [f"# 验收证据（{env}）", "",
      f"- 时间: {ts}", f"- git commit: `{commit}` (dirty files: {dirty})",
      f"- K8s: {k8s}", f"- DOMAIN: {domain}  STORAGE_BACKEND: {backend}",
      f"- 制品 lock sha256: `{lockhash}`", "",
      f"## 汇总: {report['summary']['pass']}/{report['summary']['total']} 通过", "",
      "| 检查 | 描述 | 结果 | 退出码 | 耗时(s) |", "|---|---|---|---|---|"]
for r in results:
    md.append(f"| {r['check']} | {r['description']} | {'✅' if r['status']=='pass' else '❌'} | {r['exit_code']} | {r['seconds']} |")
open(os.path.join(out, "report.md"), "w").write("\n".join(md) + "\n")
print("pass=%d fail=%d" % (report['summary']['pass'], report['summary']['fail']))
PY

log "证据: $OUT/report.json , $OUT/report.md"
cat "$OUT/report.md" 2>/dev/null | head -20
# 有失败项则返回非零
if grep -q $'\tfail\t' "$RESULTS_FILE"; then echo "[!] 存在失败检查"; exit 1; fi
echo "[+] 证据采集完成"
