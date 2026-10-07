# 验收证据（Proof）

`make evidence` 产出的证据包目录（生成物，git 忽略；仅保留本 README）。

每个证据包（`evidence/<env>/<timestamp>/`）：

- `report.json` — 机器可读：环境、git commit、K8s 版本、StorageClass 后端、制品 lock 摘要、逐项检查结果。
- `report.md` — 人读摘要（含 pass/fail 表）。
- `<check>.log` — 各检查的原始输出。

证据模型与用途见 [`../docs/evidence-and-acceptance.md`](../docs/evidence-and-acceptance.md)。
