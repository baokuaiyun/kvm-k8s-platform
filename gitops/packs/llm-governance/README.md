# llm-governance-pack

LLM 治理 pack，由**治理城市 `gov`** 的 `llm-governance` rig 承载并执行。
本仓库既是 rig 工作区，也是 gascity schema-2 pack（rig 路径含 `pack.toml` 时隐式展开）。

## 结构
```
pack.toml                       # manifest（schema 2）
agents/{governor,implementer,reviewer}/  # 治理角色 + prompt.template.md
formulas/
  model-catalog.formula.toml    # 第1层：自定义模型目录
  gateway-fallbacks.formula.toml# 第2层：平台模型自动切换
  budget-governance.formula.toml# 第3层：收费治理
orders/
  model-catalog.toml            # manual
  gateway-fallbacks.toml        # manual
  budget-governance.toml        # manual
  audit.toml                    # cron 每日巡检（默认 disabled）
assets/governance-config.yaml   # 运行参数：目标仓/预算档位/昂贵模型策略
```

## 运行模型（重要）
- 治理开发**由城市执行**，不在任何交互会话里做。
- governor 规划 → implementer 产出 GitOps 清单 PR → reviewer 验收。
- 所有变更走 GitOps（Flux），不直连集群 apply。

## 启动
在 `gov` 城市内（rig 已绑定本仓库）：
```
gc order run model-catalog
gc order run gateway-fallbacks
gc order run budget-governance
```
三个 PR 合并、稳定后，把 `orders/audit.toml` 的 `enabled` 改 true 开启每日巡检。

## 校验
```
gc lint .        # 必须 ok
```
