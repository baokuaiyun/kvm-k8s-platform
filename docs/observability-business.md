# 可观测 · 业务说明与价值

> 面向业务方 / 管理方 / 客户：可观测**解决什么业务问题**、**由谁用**、**如何映射到业务影响**。
> 技术实现见 [`observability.md`](observability.md)，规范见 [`observability-best-practices.md`](observability-best-practices.md)。

## 一、为什么需要可观测（业务价值）

平台承载 Harbor（镜像）、GitLab（代码/CI）、数据库、业务应用等。没有可观测时，故障只能"等用户报障"，定位靠登录机器翻日志。可观测带来：

| 价值 | 说明 |
|---|---|
| **缩短 MTTD**（发现） | 告警在用户感知前触发（节点宕机、磁盘将满、备份中断） |
| **缩短 MTTR**（定位） | 指标看趋势、日志看现场、探测看入口，快速圈定范围 |
| **可用性保障** | 入口探测 + 服务指标，衡量与守护 SLA/SLO |
| **容量与成本** | 磁盘/PVC/日志增长趋势，提前扩容，避免写满宕机 |
| **合规与审计** | 日志集中留存，满足审计/追溯需求 |
| **降本** | 自动告警替代人工巡检；问题早发现，减少事故损失 |

## 二、能力矩阵：能回答哪些业务问题

| 业务问题 | 用哪个信号 | 入口 |
|---|---|---|
| Harbor 拉镜像是否正常？慢不慢？ | Probe（入口）+ Harbor 指标 | Grafana / Prometheus |
| GitLab 登录/CI 是否可用？ | Probe + Pod 指标 + 日志 | Grafana |
| 节点/应用是否宕机？ | Metrics（`up`、重启数） | 告警 → 通知 |
| 磁盘/PVC 会不会写满？ | PVC 指标 + 预测告警 | 告警 |
| 备份到底在不在跑？ | Velero/CNPG 指标 | 告警 |
| 某个服务为什么报错 500？ | Loki 日志检索（按 namespace/app） | Grafana Explore |
| 入口（grafana/flux/harbor…）是否可访问？ | blackbox Probe | Prometheus/Grafana |
| 证书会不会过期导致中断？ | 证书到期告警 | 告警 |

## 三、角色与职责

| 角色 | 关注 | 典型动作 |
|---|---|---|
| 平台运维 / SRE | 全部信号、告警处置 | 值班、看告警→按 runbook 处置 |
| 平台管理员 | 入口可用性、资源容量 | 看 Grafana 总览、扩容 |
| 业务/租户 | 自己命名空间的日志与应用指标 | Grafana 限定 namespace 查询（见隔离边界） |
| 管理方 | SLA 达成、事故复盘 | 看 SLO、告警统计、周报 |

## 四、告警分级 → 业务影响

| 级别 | 含义（业务） | 期望响应 | 示例 |
|---|---|---|---|
| **critical** | 业务已中断或即将中断 / 数据有风险 | 立即（页/电话） | NodeDown、PV Failed、备份中断、Longhorn 卷故障 |
| **warning** | 隐患/降级，未直接影响业务 | 工作时间内处理 | CPU/内存高、PVC>85%、证书将到期 |

- 可达性信号（Probe）与资源信号（CPU/内存）分属不同维度：**入口不可用=直接影响用户**；资源高=先兆。
- 告警必须"可执行、可定位"：每条附带摘要与 runbook（见 [`observability-runbooks.md`](observability-runbooks.md)）。
- 建议在此基础上定义 **SLO/Error Budget**（见最佳实践篇 §SLO），把"用户可感知"的份额与告警挂钩。

## 五、值班与通知流程

```
PrometheusRule 触发 → Alertmanager(platform-alerting)
   ├─ critical → 通知渠道（当前 drill：alert-sink；生产：webhook/邮件/钉钉…）
   └─ warning  → 可选仅邮件
        │
        └─▶ 值班按 runbook 处置 → 必要时静默/升级
```

- 渠道配置见 [`alert-notification.md`](alert-notification.md)。
- 维护窗口/已知变更前先 **silence**，避免误报。
- 同一原因多个告警应**抑制**（如 NodeDown 抑制该节点上的 Pod 告警），减少噪声。

## 六、多租户视角与隔离

- 租户可查**自身命名空间**的日志与指标（查询按 `namespace` 过滤）。
- 平台侧保留全量与集群级视图；跨租户数据在查询与 Grafana 权限层隔离。
- 日志采集**不采集敏感字段**（口令/token/PII），见最佳实践。

## 七、drill 与生产差异

| 维度 | drill（本环境） | 生产 |
|---|---|---|
| 证书 | 自签通配（`*.test.baokuaiyun.com`） | 受信任证书 / 内网 SLB |
| 副本 | 单副本（Prometheus/Alertmanager/Loki/Grafana） | 多副本 HA |
| 通知渠道 | `alert-sink`（验证链路） | webhook / 邮件 / 钉钉 / 企微 |
| 存储 | app-storage（ZFS+iSCSI 模拟云盘） | 云盘/SSD + 长期存储（Thanos/Mimir） |
| 域名 | `*.test.baokuaiyun.com` | `*.baokuaiyun.com`（见域名迁移） |

## 八、容量与成本（关注点）

| 资源 | 现状 | 说明 |
|---|---|---|
| Prometheus | 10Gi / 15d 保留 | 指标随对象数量增长 |
| Loki | 20Gi / 30d 保留 | 日志量随服务与级别变化 |
| Grafana | 5Gi | 面板/用户数据（面板建议 as code） |
| Alertmanager | 2Gi | 静默/告警状态 |

- 日志成本大头在**量**：控制日志级别、避免噪声、保留期按合规要求设定。
- 指标成本在**标签基数**：禁止高基数标签（见最佳实践）。

## 九、典型业务场景 Playbook（摘要）

1. **用户报"入口打不开"**：查 blackbox `Probe` → 若无流量确认 DNS/网关；再看对应服务 Pod/日志。
2. **节点宕机**：NodeDown 告警 → 确认节点状态 → 工作负载是否迁移 → restore（见 runbook）。
3. **磁盘将满**：PVCNearlyFull/PredictFull → 扩容 PVC（自动扩容见云盘方案）或清理。
4. **备份中断**：VeleroBackupStale/CNPGBackupStale → 检查对象存储连通与备份任务。
5. **应用报错排查**：Grafana Explore → Loki 查 `{namespace="x", app="y"}` → 结合指标定位。

> 详细处置步骤见 [`observability-runbooks.md`](observability-runbooks.md)。

## 十、如何衡量"可观测做得好不好"

- 告警**可执行率**（收到即能行动）高、误报率低。
- **MTTD/MTTR** 持续下降。
- 每个重要故障都有**复盘**且产生规则/面板改进。
- 关键业务都有对应 **SLO** 与告警。