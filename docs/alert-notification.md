# 告警通知配置（Alertmanager 多渠道）

> 目标：把告警按渠道参数化投递到 企微/钉钉/Slack/邮件/通用 webhook。
> **现状（GitOps）**：告警规则与默认路由已纳入可观测组件（`monitoring`），默认 receiver 指向
> `alert-sink`（drill 验证）。通知渠道参数属运维可变项，建议经 **Secret + 组件 postBuild 注入** 或按需在
> 集群内 patch `AlertmanagerConfig`，不再走命令式 `make alerts`。
> 关联 [`observability.md`](observability.md)、[`observability-runbooks.md`](observability-runbooks.md)、
> [`parameters.md`](parameters.md)、[`secret-management.md`](secret-management.md)。

## 一、总流程

```
GitOps（组件 monitoring）
  → PrometheusRule/cluster-alerts（规则）
  → AlertmanagerConfig/platform-alerting（默认路由 → alert-sink）
       └─ 运维可变项（渠道：webhook/邮件/钉钉…）经 Secret 注入 / 手动 patch
  → Alertmanager 按 severity 路由投递
```

- 规则与默认路由真源：`gitops/components/infra/monitoring/base/{alert-rules,alertmanagerconfig}.yaml`。
- 渠道密钥（webhook/secret、SMTP 口令）放 `ops.env`→Secret，不进 Git；参数默认值见 `variables.mk`。
- 前置：组件 `monitoring` 已就绪（提供 `monitoring.coreos.com` CRD 与 `alertmanagerConfigSelector`）。
- **legacy**：`observability/apply-alerts.sh` / `make alerts` / `make alert-adapter` 为历史命令式路径，已不进入主流程。

## 二、运维客户端环境参数导入

优先级：**`ops.env`（或 `ALERT_ENV_FILE`）> `acr.env`/`variables.mk` 默认**。

```bash
cp ops.env.example ops.env && vim ops.env     # 填通知参数（勿提交）
make alerts                                   # 自动导入 ops.env
# 或指定文件
ALERT_ENV_FILE=/path/to/ops.env bash observability/apply-alerts.sh
# 或先导出再执行
source ops.env && make alerts
```

- `ops.env` 为 shell `KEY=VALUE`；含空格的值请加引号。
- `make` 通过 `-include ops.env` 读取，脚本另用 `set -a; source` 导入，两条路径一致。

## 三、渠道对照

| 渠道 | `ALERT_WEBHOOK_TYPE` | 必填 | 说明 |
|---|---|---|---|
| Slack | `slack` | `ALERT_WEBHOOK_URL`（incoming webhook）| 原生 `slackConfigs` |
| 通用 webhook | `generic` | `ALERT_WEBHOOK_URL` | 原生 `webhookConfigs`，投递 Alertmanager JSON |
| 钉钉 | `dingtalk` | `ALERT_WEBHOOK_URL` **或** 集群内适配器 | 见 §四 |
| 企业微信 | `wecom` | `ALERT_WEBHOOK_URL`（中转）| Alertmanager 无原生格式，需中转 |
| 邮件 | —（`ALERT_EMAIL_ENABLED=1`）| `ALERT_EMAIL_TO` + `SMTP_SMARTHOST` | 原生 `emailConfigs` |

多渠道可并存：webhook + 邮件同时开时，critical 全发，`ALERT_WARNING_CHANNELS=email` 可让 warning 只发邮件。

### 参数示例

```bash
# Slack
ALERT_WEBHOOK_ENABLED=1
ALERT_WEBHOOK_TYPE=slack
ALERT_WEBHOOK_URL=https://hooks.slack.com/services/XXX/YYY/ZZZ

# 通用 webhook（自建接收端）
ALERT_WEBHOOK_ENABLED=1
ALERT_WEBHOOK_TYPE=generic
ALERT_WEBHOOK_URL=http://my-receiver.monitoring.svc:8080/alerts

# 邮件（推荐 587 + STARTTLS）
ALERT_EMAIL_ENABLED=1
ALERT_EMAIL_TO=ops@baokuaiyun.com
ALERT_EMAIL_FROM=alertmanager@baokuaiyun.com
SMTP_SMARTHOST=smtp.exmail.qq.com:587
SMTP_AUTH_USERNAME=alertmanager@baokuaiyun.com
SMTP_AUTH_PASSWORD=<授权码>       # 写入 Secret monitoring/alertmanager-smtp
```

## 四、钉钉 / 企业微信

Alertmanager 只发自己的 webhook JSON，钉钉/企微需要「中转」把 JSON 转成各自格式：

**钉钉（集群内适配器，推荐）**
```bash
# ops.env / acr.env
ALERT_DINGTALK_WEBHOOK=https://oapi.dingtalk.com/robot/send?access_token=xxx
ALERT_DINGTALK_SECRET=SECxxxx          # 机器人「加签」密钥，可空
# 部署适配器 + 配置 Alertmanager
make alert-adapter                      # 部署 prometheus-webhook-dingtalk
# 然后：ALERT_WEBHOOK_ENABLED=1 ALERT_WEBHOOK_TYPE=dingtalk（URL 留空自动指向适配器）
make alerts
```

**企业微信 / 外部中轉**
```bash
# 部署任一企微中转（自建 webhook relay 或开源 relay），把 Alertmanager JSON 转企微 markdown
ALERT_WEBHOOK_ENABLED=1
ALERT_WEBHOOK_TYPE=wecom
ALERT_WEBHOOK_URL=http://<企微中转地址>/wecom/send   # 必填
```

> 适配器镜像需先进 Harbor：见 `registry/images/tier3-observability.txt`
> （`ghcr.io/timonwong/prometheus-webhook-dingtalk`），`make registry` 同步。

## 五、应用与验证

```bash
# 规则/默认路由已由 GitOps 下发；核对：
kubectl -n monitoring get prometheusrule cluster-alerts
kubectl -n monitoring get alertmanagerconfig platform-alerting -o yaml

# [legacy] 渲染预览/命令式应用（历史路径）
make alerts-print          # 只打印 AlertmanagerConfig，核对渠道与路由
make alerts                # 应用

# 核对渲染是否生效
kubectl -n monitoring get alertmanagerconfig platform-alerting -o yaml
kubectl -n monitoring get secret alertmanager-monitoring-alertmanager-generated \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | sed -n '/receivers:/,/route:/p'

# UI 与测试告警
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093
# 浏览器 http://localhost:9093 → Status/Config/Silence
curl -s -XPOST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"Test","severity":"critical","namespace":"test"}}]'
```

## 六、常见坑

- 未部署可观测组件（缺 `monitoring.coreos.com` CRD / `AlertmanagerConfig` 未被选中）：先 `make observability`。
- 未设 `alertmanagerConfigSelector`：CR 存在但不被选中（组件内 values 已设）。
- 邮件端口：`587 + requireTLS` 最稳；465 隐式 TLS 常不兼容。
- 钉钉/企微无原生格式，必须中转；适配器与 Alertmanager 网络要通。
- 密钥只放 `ops.env`/`acr.env`，不要写进 `variables.mk`。
- 修改参数后需重跑 `make alerts`（AlertmanagerConfig 不会自动热更参数）。
