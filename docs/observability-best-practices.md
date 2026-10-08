# 可观测 · 最佳实践（规范 / 反模式 / 清单）

> 结合**本仓可执行**的规范与反模式，通用原则为辅。技术架构见 [`observability.md`](observability.md)。
> 文末有**落地核对清单**与**本仓 Backlog**。

## 0. 总原则

- **信号选择**：服务看 **RED**（Rate/Errors/Duration），资源看 **USE**（Utilization/Saturation/Errors），端到端看 **Golden Signals**。
- **告警面向症状（用户可感知）**，而非内部原因；原因用面板/日志排查。
- **可观测即代码**：规则、面板、采集配置全部进 Git（本仓：组件 `monitoring` + Flux）。
- **成本意识**：指标防高基数、日志防噪声、保留期与合规平衡。

## 1. 指标（Metrics）

**标签规范**
- 统一维度：`namespace / app / container / node / job / instance / release`。
- **禁止高基数**：不要把 `pod` 名（带随机后缀）、请求 ID、时间、URL 原样做 label。用 `app`/`deployment` 级聚合。
- 聚合前设 `honor_labels`/relabel，防止冲突与污染。

```yaml
# 反例：把 pod 名（含随机后缀）当固定维度，基数爆炸
labels: { pod: {{ $labels.pod }} }
# 正例：按 workload 聚合
sum by (namespace, deployment) (rate(http_requests_total{code=~"5.."}[5m]))
```

**采集约定（本仓）**
- ServiceMonitor/PodMonitor/Probe 统一标签 `release: monitoring`（kube-prometheus-stack 选择器要求）。
- 统一 `interval: 30s`、`scrapeTimeout` 小于 interval。
- 有 exporter 的组件用 ServiceMonitor，不要手写 static_configs。

**查询与预聚合**
- 昂贵/常用查询用 **Recording Rules** 预聚合（本仓暂缺 → Backlog）。
- 避免大窗口 `max_over_time`/全量 scan；优先 `rate`/`increase` + 子查询。

**保留与容量**
- 保留期统一由变量驱动（`PROMETHEUS_RETENTION`），避免 values 与变量漂移。

## 2. 日志（Logs）

**应用侧**
- **结构化日志（JSON）**，字段固定：`time/level/msg/service/request_id/trace_id`。
- 级别规范：`error` 仅用于需处理的错误；避免把正常流程打 `error` 制造噪声。
- **绝不记录**：口令、token、密钥、身份证/手机号等 PII（见 [`secret-management.md`](secret-management.md)）。

**Loki 标签策略（关键）**
- **低基数才做 label**：`namespace/app/container/level/cluster`。
- 高基数（用户 ID、路径、IP）放 **structured metadata**，不是 label。
- **禁止动态 label**；否则 Loki 会退化甚至 OOM。

```logql
# 反例：把 request_id 当 label
{app="api", request_id="..."}        # ❌ 基数爆炸
# 正例：固定 label + 行过滤
{namespace="prod", app="api"} |= "request_id=abc"   # ✅
```

**采集（本仓 Alloy）**
- `loki.source.kubernetes` 经 API 采集，RBAC 默认含 `pods/log`。
- 排除噪声（健康检查/探针日志）、开启多行合并（异常栈）。
- 设置 **retention_period + compactor**（本仓已设 30d），避免无限增长。

## 3. 链路（Traces，预留）
- Alloy 用 `otelcol.receiver.otlp` 接收，写 Tempo；应用透传 `trace_id` 并与日志关联。

## 4. 告警（Alerting）

**面向症状 + 可执行**
- 每条必须有：`summary`（一句现象）、`description`（影响/范围）、`runbook_url`（处置）、`severity`。
- `for` 给足缓冲（抖动不报）；阈值要有依据。

```yaml
# 反例
- alert: HighCPU
  expr: cpu > 50
  annotations: {}
# 正例
- alert: NodeHighCPUUsage
  expr: 100 - avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m]))*100 > 85
  for: 10m
  labels: { severity: warning }
  annotations:
    summary: "节点 {{ $labels.instance }} CPU>85%"
    description: "持续 10 分钟，可能影响在该节点的服务延迟"
    runbook_url: "https://baokuaiyun.com/observability-runbooks/#node-high-cpu"
```

**分级 / 抑制 / 分组 / 静默**
- 分级：critical（业务中断/数据风险）→ 立即；warning → 工作时段。
- **抑制**：NodeDown 时抑制其上的 Pod 告警（本仓暂缺 → Backlog）。
- 分组：按 `namespace+alertname`；变更前先 silence。

**避免告警疲劳**
- 只保留"收到能行动"的告警；定期回顾删除无效项。
- 用 **SLO burn-rate** 替代大量阈值告警（见 §6）。

## 5. 仪表盘（Dashboards as Code）
- 每服务/每层一张，突出 Golden Signals；统一单位与时间范围变量。
- 支持 drilldown：告警 → 面板 → 日志/追踪。
- 面板用 ConfigMap/CRD 版本化管理，不手改 UI。

## 6. SLO / Error Budget
- 选代表性 **SLI**：可用性、延迟、成功率（如入口可用率、API p99）。
- 设 **SLO**（如 99.9%）→ 计算 **error budget** → 用 **burn-rate** 告警（快速燃烧立即报，慢速燃烧工时内报）。
- 与业务影响对齐：预算耗尽即暂停高风险变更。

## 7. GitOps / 声明式
- 一切进 Git；组件 `base + overlays/<env>`；禁止 `kubectl edit`。
- 制品 **cosign 签名**、Flux 验签；tag 晋升 `latest → latest-stable`。
- 变动走 PR；drift 由 Flux 自动纠正。

## 8. 安全与多租户
- 观测面 RBAC 最小权限（只读）；Grafana 组织/数据源按租户隔离。
- 日志/指标**不跨租户泄漏**；查询按 namespace 约束。
- 敏感字段不入日志（见 §2）。

## 9. 可靠性与容量
- drill 单副本；**prod 建议多副本**（Prometheus/Alertmanager HA）+ 长期存储（Thanos/Mimir）。
- PVC 规划 + 备份；面板/规则 as code 便于重建。
- 升级/回滚走组件制品 tag（见 observability.md §十）。

## 10. On-call
- 值班分级、升级路径、通知渠道、**runbook 索引**（本仓 [`observability-runbooks.md`](observability-runbooks.md)）。
- 每周回顾：告警数量、误报、处置时长，持续改进。

---

## 11. 落地核对清单（Checklist）

- [ ] 所有采集对象带统一 label（尤其 `release: monitoring`）
- [ ] 无高基数 label（指标与 Loki）
- [ ] 应用输出结构化日志、无敏感字段
- [ ] Loki 已设 retention + compactor
- [ ] 每条告警有 summary/description/runbook_url/severity
- [ ] 有抑制规则（Node 级抑制 Pod 级）
- [ ] 有 recording rules（高频/昂贵查询）
- [ ] 关键业务有 SLO 与 burn-rate 告警
- [ ] 面板 as code、可 drilldown
- [ ] 制品签名 + tag 晋升流程可用
- [ ] 观测面 RBAC 最小权限、租户隔离
- [ ] runbook 覆盖所有 critical 告警

## 12. 本仓 Backlog（最佳实践落地项）

| # | 项 | 现状 | 目标 |
|---|---|---|---|
| 1 | 告警注解 | 缺 `description/runbook_url` | 全部补齐（本批已加） |
| 2 | Prometheus 保留 | values 7d vs 变量 15d 漂移 | 统一 15d（本批已对齐） |
| 3 | Loki 保留 | 无限增长 | `retention_period=30d`+compactor（本批已加） |
| 4 | Recording rules | 无 | 常用查询预聚合 |
| 5 | 抑制规则 | 无 | NodeDown 抑制 Pod 告警 |
| 6 | SLO/burn-rate | 无 | 关键入口/服务 |
| 7 | 生产面板 as code | 仅默认面板 | 每服务 Golden Signals |
| 8 | prod HA / 长期存储 | drill 单副本 | 多副本 + Thanos/Mimir |
| 9 | OTel/Tempo | 未接 | Alloy OTLP → Tempo |