#!/usr/bin/env bash
# 按 gitops/repo-split.yaml 生成"三分仓（fleet/infra/apps）"拆分计划。
# 默认 --dry-run：打印映射并生成可执行脚本 gitops/locks/repo-split.generated.sh（不执行）。
#   --apply：真正拆分（需 git-filter-repo；在独立克隆上操作，避免损伤当前仓库）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC="${ROOT}/gitops/repo-split.yaml"
OUT="${ROOT}/gitops/locks/repo-split.generated.sh"
APPLY=0; for a in "$@"; do [ "$a" = "--apply" ] && APPLY=1; done

[ -f "$SPEC" ] || { echo "[!] 缺少 $SPEC"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "[!] 需要 python3"; exit 1; }

mkdir -p "$(dirname "$OUT")"
python3 - "$SPEC" "$OUT" "$ROOT" <<'PY'
import sys, yaml
spec_path, out_path, root = sys.argv[1:4]
spec = yaml.safe_load(open(spec_path))
print("[+] 拓扑:", spec.get("topology", "?"), " 当前:", spec.get("current","?"))
lines = ["#!/usr/bin/env bash",
         "# 由 scripts/repo-split.sh 生成：按 repo-split.yaml 拆分（git-filter-repo）",
         "set -euo pipefail",
         'command -v git-filter-repo >/dev/null 2>&1 || { echo "[!] 需要 git-filter-repo: pip install git-filter-repo"; exit 1; }',
         ""]
for name, r in spec["repos"].items():
    paths = r.get("paths", [])
    print(f"  - {name:6s} owner={r.get('owner')} paths={len(paths)}")
    for p in paths:
        print(f"        {p}")
    # 生成：克隆 → filter-repo 保留路径
    pargs = " ".join(f"--path '{p.rstrip('/*')}'" if p.endswith("/**") else f"--path '{p}'" for p in paths)
    lines += [
        f"# ---- {name} ({r.get('owner')}) ----",
        f"git clone --no-local {root} ../{name}",
        f"( cd ../{name} && git filter-repo --force {pargs} )",
        f"# 远端: git -C ../{name} remote add origin <gitlab>/<group>/{name}.git && git -C ../{name} push -u origin main",
        ""]
open(out_path, "w").write("\n".join(lines))
print(f"[+] 拆分命令已生成: {out_path}")
print("    执行(需 git-filter-repo): bash gitops/locks/repo-split.generated.sh")
PY

if [ "$APPLY" = 1 ]; then
  echo "[+] --apply：执行生成的拆分脚本（在 ../ 下创建 fleet/infra/apps 克隆）"
  bash "$OUT"
else
  echo "[=] dry-run：仅生成计划/脚本，未做任何改动。加 --apply 执行。"
fi
