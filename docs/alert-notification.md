# 告警通知配置（Alertmanager 多渠道）

> 目标：把 `observability/alerts.yaml` 的告警，按渠道参数化投递到 企微/钉钉/Slack/邮件/通用 webhook。
> 关联 [`parameters.md`](parameters.md)、[`cloud-disk-data-solution.md`](cloud-disk-data-solution.md)、
> [`data-plane-management.md`](data-plane-management.md)。

## 一、总流程

```
参数（ops.env / acr.env / 环境变量）
  → observability/apply-alerts.sh 渲染 AlertmanagerConfig
  → make alerts 应用（含 PrometheusRule + SMTP Secret）
  → Alertmanager 按 severity 路由投递
```

- 参数真源：默认值 `variables.mk`；密钥与运维值放 `acr.env` 或 `ops.env`（均 gitignored）。
- 前置：先 `make monitoring`（已带 `--set alertmanagerConfigSelector/NamespaceSelector`，
  否则 `AlertmanagerConfig` CR 不会被 Alertmanager 选中）。

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

- 未 `make monitoring`（缺 `monitoring.coreos.com` CRD）：`kubectl apply` 报无匹配 kind。
- 未设 `alertmanagerConfigSelector`：CR 存在但不被选中（Makefile 已内置）。
- 邮件端口：`587 + requireTLS` 最稳；465 隐式 TLS 常不兼容。
- 钉钉/企微无原生格式，必须中转；适配器与 Alertmanager 网络要通。
- 密钥只放 `ops.env`/`acr.env`，不要写进 `variables.mk`。
- 修改参数后需重跑 `make alerts`（AlertmanagerConfig 不会自动热更参数）。
