# 可观测（Observability）· 架构与运维

> 本文是可观测栈的**技术总纲**：架构、组件、GitOps 交付、配置、告警、验证与运维。
> 面向上手与排障；业务视角见 [`observability-business.md`](observability-business.md)，
> 规范与反模式见 [`observability-best-practices.md`](observability-best-practices.md)，
> 告警处置见 [`observability-runbooks.md`](observability-runbooks.md)。
> 关联：[`gitops-fleet.md`](gitops-fleet.md)、[`alert-notification.md`](alert-notification.md)、
> [`parameters.md`](parameters.md)、[`access-gateway.md`](access-gateway.md)。

## 一、范围与信号

| 信号 | 组件 | 用途 |
|---|---|---|
| **Metrics** | Prometheus + kube-state-metrics + node-exporter | 资源/服务/集群指标、告警数据源 |
| **Visualization** | Grafana | 面板、Explore（指标/日志）、告警查看 |
| **Logs** | Loki（存储/查询） + Grafana Alloy（采集） | 全集群 Pod 日志检索 |
| **Probe** | blackbox-exporter + `Probe` CR | 入口/URL 可用性探测 |
| **Alerting** | Alertmanager + AlertmanagerConfig → alert-sink | 告警路由与投递 |
| Traces（预留） | Alloy OTLP（→ 后续 Tempo） | 链路追踪 |

## 二、架构与数据流

```
                 ┌─────────────── GitOps（Flux）───────────────┐
                 │ 组件 gitops/components/infra/monitoring      │
                 │  → OCIRepository(cosign 验签) + Kustomization │
                 └───────────────┬──────────────────────────────┘
                                 ▼  server-side apply
   ┌─────────────────────────── monitoring namespace ───────────────────────────┐
   │                                                                            │
   │  kube-prometheus-stack                       Loki (SingleBinary, app-storage)│
   │   - Prometheus ──scrape──▶ kube-state-metrics / node-exporter / SMs         │
   │   - Prometheus ──scrape──▶ Probe(blackbox) ──▶ blackbox-exporter :9115      │
   │   - Prometheus ──rules──▶ Alertmanager ──webhook──▶ alert-sink :8080        │
   │   - Grafana ──datasource──▶ Prometheus / Loki / Alertmanager                │
   │                                                                            │
   │  Alloy (DaemonSet) ──loki.source.kubernetes──▶ Loki :3100                   │
   └────────────────────────────────────────────────────────────────────────────┘
                                 ▲
              Grafana UI  https://grafana.test.baokuaiyun.com  (Gateway/HTTPS)
```

- 采集：Prometheus 主动 `scrape`（ServiceMonitor/PodMonitor/Probe 选择器统一要求标签 `release: monitoring`）。
- 日志：Alloy 以 DaemonSet 运行，用 `loki.source.kubernetes`（经 API 读 `pods/log`）采集，推送 `loki.monitoring.svc:3100`。
- 告警：PrometheusRule(带 `release: monitoring`) 触发 → Alertmanager → `AlertmanagerConfig/platform-alerting` → `alert-sink`。
- 入口：Grafana 经平台 kgateway `HTTPRoute/monitoring/grafana` 暴露；域名解析由 `make ingress-dns` 统一注入。

## 三、组件清单

| 组件 | Chart / 版本 | App | 镜像（Harbor） | 说明 |
|---|---|---|---|---|
| kube-prometheus-stack | 65.5.1 | v0.77.2 | 见下 | 指标栈伞图 |
| ├ Prometheus | — | v2.55.0 | `prometheus-prometheus:v2.55.0` | 15d 保留、app-storage 10Gi |
| ├ Alertmanager | — | v0.27.0 | `prometheus-alertmanager:v0.27.0` | app-storage 2Gi |
| ├ Grafana | — | 11.2.2-security-01 | `grafana-grafana:11.2.2-security-01` | app-storage 5Gi、`root_url` 已配、接 Loki 数据源 |
| ├ operator / kube-state / node-exporter | — | v0.77.2 / v2.13.0 / v1.8.2 | — | — |
| Loki | 6.21.0 | 3.3.0 | `grafana-loki:3.3.0` | SingleBinary、app-storage 20Gi |
| Alloy | 1.13.0 | v1.20.0 | `grafana-alloy:v1.20.0` | DaemonSet 日志采集 |
| blackbox-exporter | 11.19.1 | v0.28.0 | `prometheus-blackbox-exporter:v0.28.0` | `Probe` 探测入口 |
| alert-sink | — | busybox | `busybox:1.37.0` | drill webhook 接收端 |

> 全部镜像走本域 Harbor `baokuaiyun/<flat-name>:<tag>`（scheme C）；chart 以 OCI 存入 Harbor，Flux 经 `OCIRepository(insecure+cosign verify)` 拉取。

## 四、仓库结构与 GitOps 交付

```
gitops/components/infra/monitoring/
├── component.yaml                     # name/plane/fleet/env + images 清单（制品解析用）
├── base/
│   ├── kustomization.yaml
│   ├── ocirepository-chart.yaml        # kube-prometheus-stack chart
│   ├── helmrelease.yaml                # monitoring（含 grafana root_url + Loki datasource）
│   ├── grafana-route.yaml              # HTTPRoute
│   ├── ocirepository-loki.yaml / helmrelease-loki.yaml
│   ├── ocirepository-alloy.yaml / helmrelease-alloy.yaml
│   ├── ocirepository-blackbox.yaml / helmrelease-blackbox.yaml
│   ├── blackbox-probes.yaml            # Probe/ingress-endpoints
│   ├── alert-rules.yaml                # PrometheusRule/cluster-alerts（label release: monitoring）
│   ├── alertmanagerconfig.yaml         # AlertmanagerConfig/platform-alerting
│   └── alert-sink.yaml                 # drill webhook sink
└── overlays/drill/kustomization.yaml   # namespace: monitoring
```

- **fleet layer**：`gitops/fleet/layers/observability/components.yaml` → 组件 `monitoring`。
- **交付链**：`component.yaml.images` → `resolve-artifacts/sync-artifacts`（镜像+签名入 Harbor）→ `build-component`（base+overlays 打包并 cosign 签名）→ `render-stack`（生成 ResourceSet，按组件建 `OCIRepository`+`Kustomization`）→ Flux 收敛。
- **接管既有 release**：HelmRelease `releaseName` 与既有一致（`monitoring`/`loki`/`alloy`/`blackbox`），Flux 就地升级接管。

## 五、部署（一个阶段）

```bash
# 推荐：一条命令完成“chart+镜像+组件制品 → Flux 收敛”
make observability

# 等价的手工步骤
make push-charts                                        # chart 推入 Harbor OCI（幂等）
make publish-artifacts FLEET_MODES=observability        # 镜像按需入 Harbor + cosign 签名
make build-component C=infra/monitoring TAG=latest SIGN=--sign
make render-stack FLEET_MODES=observability             # 生成并 apply ResourceSet
```

- `phase2` 已改为走 `observability`（GitOps）；旧 `make monitoring/agents/alerts/alert-adapter` 标记 **legacy**，不再进入主流程。
- 前置：Flux 已就绪（`make flux-operator`）；入口域名已由 `make ingress-dns` 注入。

## 六、配置要点

- **Grafana 对外 URL**：`grafana.ini.server.root_url=https://grafana.test.baokuaiyun.com/`（缺省会退化为 `http://localhost:3000`，导致登录/跳转异常）。
- **Grafana 日志数据源**：`additionalDataSources` 内建 Loki（`http://loki.monitoring.svc.cluster.local:3100`）。
- **Prometheus 保留**：`retention: 15d`（与 `variables.mk:PROMETHEUS_RETENTION` 对齐）。
- **Loki 保留**：`limits_config.retention_period: 30d` + compactor `retention_enabled`（避免无限增长）。
- **Alloy 采集**：`alloy.configMap.content`（River）——`discovery.kubernetes` → `discovery.relabel` → `loki.source.kubernetes` → `loki.write`；默认 RBAC 已含 `pods/log`。
- **blackbox 模块**：`http_2xx`（标准）与 `http_2xx_insecure`（自签，drill 用）。
- **告警选择器**：kube-prometheus-stack 默认 `ruleSelector/probeSelector/serviceMonitorSelector` 需标签 `release: monitoring`。

## 七、访问入口

| 入口 | 地址 | 凭据/说明 |
|---|---|---|
| Grafana | https://grafana.test.baokuaiyun.com/ | `admin` /（secret `monitoring/monitoring-grafana` 的 `admin-password`，drill 默认 `prom-operator`） |
| Alertmanager UI | `kubectl -n monitoring port-forward svc/monitoring-alertmanager 9093` | 只读查看/静默 |
| Loki API | 集群内 `http://loki.monitoring.svc:3100` | `/loki/api/v1/query_range` |
| Prometheus UI | `kubectl -n monitoring port-forward svc/monitoring-prometheus 9090` | — |

## 八、告警规则（PrometheusRule/cluster-alerts）

| 组 | 告警 | 级别 | 触发 |
|---|---|---|---|
| node | NodeDown | critical | `up == 0` 5m |
| node | HighCPUUsage | warning | CPU>85% 10m |
| node | HighMemoryUsage | warning | 内存>90% 10m |
| pod | PodCrashLooping | warning | 1h 重启>5 |
| pod | PodPending | warning | Pending>15m |
| certificate | CertificateExpiring | warning | 证书 7d 内到期 |
| storage | PVCNearlyFull | warning | PVC>85% |
| storage | PVCCriticalFull | critical | PVC>95% |
| storage | PVCPredictFull | warning | 预测 24h 写满 |
| storage | PVCInodesNearlyFull | warning | inode>85% |
| storage | PVCResizeStuck | warning | requested>capacity 30m |
| storage | PersistentVolumeFailed | critical | PV Failed |
| storage | LonghornVolumeDegraded | warning | robustness=2 |
| storage | LonghornVolumeFaulted | critical | robustness=3 |
| storage | LonghornNodeStorageHigh | warning | 节点存储>80% |
| storage | LonghornBackupTargetUnreachable | critical | 备份目标不可达 |
| storage | VeleroBackupFailure | warning | 6h 内有失败 |
| storage | VeleroBackupStale | critical | >48h 无成功备份 |
| storage | CNPGBackupStale | critical | CNPG >48h 无可用备份 |

路由：`platform-alerting` 按 `severity`（critical 1h 重发 / warning）分组 `namespace+alertname` → `webhook → alert-sink`。通知渠道见 [`alert-notification.md`](alert-notification.md)。

## 九、验证 / 验收

```bash
# 组件收敛
kubectl -n monitoring get kustomization component            # READY=True
kubectl -n monitoring get helmrelease                         # 4 个均 Ready
kubectl -n monitoring get pods                                # 全部 Running

# 指标/探测
kubectl -n monitoring port-forward svc/monitoring-prometheus 9090 &
curl -s localhost:9090/api/v1/rules?type=alert | grep cluster-alerts
curl -s localhost:9090/api/v1/targets | grep -i probe          # probe/* up

# 日志
kubectl -n monitoring port-forward svc/loki 3100 &
curl -s 'localhost:3100/loki/api/v1/labels'
curl -sG localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="monitoring"}' --data-urlencode 'limit=1'

# 入口
curl -kI https://grafana.test.baokuaiyun.com/login             # 200
```

## 十、升级 / 回滚

- **升级**：改组件 `base/*` 或 `component.yaml.images` → 提交 → CI/手工 `build-component`（新制品+签名）→ `render-stack`；Flux 自动收敛。
- **drill/prod**：drill 用 tag `latest`；prod 用 `latest-stable` 指针，晋升用 `flux tag` 把 `vX.Y.Z` 指向 `latest-stable`，回滚反向操作。
- **chart/镜像**：版本改动同步更新 `ocirepository-*.yaml` 的 `ref.tag` 与 `component.yaml`。

## 十一、与 legacy 的边界

`Makefile` 的 `monitoring` / `agents` / `alerts` / `alert-adapter` 及 `observability/apply-alerts.sh`、`observability/Makefile`、`platform/monitoring/*.yaml` 为**历史命令式路径**，已被本组件取代；保留仅供回溯，勿在新环境使用。

## 十二、演进

- OTel 链路：Alloy 增加 `otelcol.receiver.otlp` → Tempo；Grafana 加 Tempo 数据源。
- SLO/Error Budget：定义 SLI + burn-rate 告警（见最佳实践篇）。
- HA：prod 多副本 Prometheus/Alertmanager，或远程写 Thanos/Mimir。