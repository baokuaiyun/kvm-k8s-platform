#!/usr/bin/env bash
# 应用告警规则 + 渲染并应用 AlertmanagerConfig（系统参数化，见 docs/alert-notification.md）
#   - alerts.yaml：PrometheusRule（含存储/PV 告警）
#   - AlertmanagerConfig：按 ALERT_* 参数生成，支持渠道：
#       slack（原生）/ generic webhook / dingtalk / wecom / email
# 环境导入：若存在 ops.env（或 ALERT_ENV_FILE 指定）则 source 覆盖，供运维客户端注入参数。
# 用法:
#   bash observability/apply-alerts.sh            # 应用
#   bash observability/apply-alerts.sh --print    # 只打印 AlertmanagerConfig
#   ALERT_ENV_FILE=/path/ops.env bash observability/apply-alerts.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PRINT=0
[ "${1:-}" = "--print" ] && PRINT=1

log()  { echo "[+] $*" >&2; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[x] $*" >&2; exit 1; }

# ---------- 0) 运维客户端环境参数导入 ----------
# 优先级：ALERT_ENV_FILE / ops.env（source 覆盖）> make/环境导出值 > 默认
ENV_FILE="${ALERT_ENV_FILE:-}"
if [ -z "$ENV_FILE" ] && [ -f "$DIR/../ops.env" ]; then
  ENV_FILE="$DIR/../ops.env"
fi
if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
  log "导入运维环境参数: ${ENV_FILE}"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

NS="${ALERT_NAMESPACE:-monitoring}"
command -v kubectl >/dev/null 2>&1 || die "需要 kubectl"
kubectl cluster-info >/dev/null 2>&1 || die "无法连接集群"

# ---------- 1) PrometheusRule ----------
if [ "$PRINT" = 0 ]; then
  log "应用告警规则 alerts.yaml"
  kubectl apply -f "$DIR/alerts.yaml"
fi

# ---------- 2) 读取渠道参数 ----------
WEBHOOK_ENABLED="${ALERT_WEBHOOK_ENABLED:-0}"
WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"
WEBHOOK_TYPE="${ALERT_WEBHOOK_TYPE:-generic}"
EMAIL_ENABLED="${ALERT_EMAIL_ENABLED:-0}"
EMAIL_TO="${ALERT_EMAIL_TO:-}"
EMAIL_FROM="${ALERT_EMAIL_FROM:-alertmanager@localhost}"
SMARTHOST="${SMTP_SMARTHOST:-}"
SMTP_USER="${SMTP_AUTH_USERNAME:-}"
SMTP_PASS="${SMTP_AUTH_PASSWORD:-}"
WARNING_CHANNELS="${ALERT_WARNING_CHANNELS:-all}"

# dingtalk/wecom：无显式 URL 时回落到集群内适配器
if [ "$WEBHOOK_ENABLED" = "1" ] && [ -z "$WEBHOOK_URL" ]; then
  case "$WEBHOOK_TYPE" in
    dingtalk) WEBHOOK_URL="http://alert-adapter-dingtalk.${NS}.svc:8060/dingtalk/default/send"
              warn "未设 ALERT_WEBHOOK_URL，使用集群内钉钉适配器 ${WEBHOOK_URL}（需 make alert-adapter）" ;;
    wecom)    die "ALERT_WEBHOOK_TYPE=wecom 需显式 ALERT_WEBHOOK_URL 指向企微中转（或用邮件）" ;;
  esac
fi

# ---------- 3) 组装 receiver 配置块（缩进 4） ----------
WEBHOOK_CFG=""
EMAIL_CFG=""

if [ "$WEBHOOK_ENABLED" = "1" ]; then
  [ -n "$WEBHOOK_URL" ] || die "ALERT_WEBHOOK_ENABLED=1 但 ALERT_WEBHOOK_URL 为空"
  if [ "$WEBHOOK_TYPE" = "slack" ]; then
    WEBHOOK_CFG="    slackConfigs:
      - apiURL: '${WEBHOOK_URL}'
        sendResolved: true
        title: '[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.summary }}{{ \"\\n\" }}{{ end }}'"
  else
    WEBHOOK_CFG="    webhookConfigs:
      - url: '${WEBHOOK_URL}'
        sendResolved: true"
  fi
fi

if [ "$EMAIL_ENABLED" = "1" ]; then
  [ -n "$EMAIL_TO" ] || die "ALERT_EMAIL_ENABLED=1 但 ALERT_EMAIL_TO 为空"
  [ -n "$SMARTHOST" ] || die "ALERT_EMAIL_ENABLED=1 但 SMTP_SMARTHOST 为空"
  EMAIL_CFG="    emailConfigs:
      - to: '${EMAIL_TO}'
        from: '${EMAIL_FROM}'
        smarthost: '${SMARTHOST}'
        sendResolved: true"
  if [ -n "$SMTP_USER" ]; then
    EMAIL_CFG="${EMAIL_CFG}
        authUsername: '${SMTP_USER}'
        authPassword:
          name: alertmanager-smtp
          key: password
        authIdentity: '${SMTP_USER}'
        requireTLS: true"
  fi
fi

# ---------- 4) receivers 与路由 ----------
RECEIVERS=""
add_recv() { RECEIVERS="${RECEIVERS}$1"$'\n'; }

if [ "$WEBHOOK_ENABLED" = "1" ] && [ "$EMAIL_ENABLED" = "1" ]; then
  add_recv "  - name: all";     add_recv "$WEBHOOK_CFG"; add_recv "$EMAIL_CFG"
  add_recv "  - name: email";   add_recv "$EMAIL_CFG"
  DEFAULT_RECEIVER="all"
  WARN_RECEIVER="all"
elif [ "$WEBHOOK_ENABLED" = "1" ]; then
  add_recv "  - name: webhook"; add_recv "$WEBHOOK_CFG"
  DEFAULT_RECEIVER="webhook"; WARN_RECEIVER="webhook"
elif [ "$EMAIL_ENABLED" = "1" ]; then
  add_recv "  - name: email";   add_recv "$EMAIL_CFG"
  DEFAULT_RECEIVER="email"; WARN_RECEIVER="email"
else
  add_recv "  - name: null-receiver"
  DEFAULT_RECEIVER="null-receiver"; WARN_RECEIVER="null-receiver"
  warn "未启用任何通知渠道（ALERT_WEBHOOK_* / ALERT_EMAIL_* 均关闭），仅保留规则"
fi

# warning 可只发邮件（critical 全发）
if [ "$WARNING_CHANNELS" = "email" ] && [ "$EMAIL_ENABLED" = "1" ]; then
  WARN_RECEIVER="email"
fi

GROUP_WAIT="${ALERT_GROUP_WAIT:-30s}"
GROUP_INTERVAL="${ALERT_GROUP_INTERVAL:-5m}"
REPEAT_INTERVAL="${ALERT_REPEAT_INTERVAL:-4h}"

AMCONFIG="apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: platform-alerting
  namespace: ${NS}
  labels:
    alertmanagerConfig: platform
spec:
  route:
    receiver: ${DEFAULT_RECEIVER}
    groupBy: ['namespace', 'alertname']
    groupWait: ${GROUP_WAIT}
    groupInterval: ${GROUP_INTERVAL}
    repeatInterval: ${REPEAT_INTERVAL}
    routes:
    - matchers:
      - name: severity
        value: critical
        matchType: '='
      receiver: ${DEFAULT_RECEIVER}
      repeatInterval: 1h
    - matchers:
      - name: severity
        value: warning
        matchType: '='
      receiver: ${WARN_RECEIVER}
  receivers:
${RECEIVERS}"

if [ "$PRINT" = 1 ]; then
  printf '%s\n' "$AMCONFIG"
  exit 0
fi

# ---------- 5) SMTP 凭据 Secret ----------
if [ "$EMAIL_ENABLED" = "1" ] && [ -n "$SMTP_USER" ]; then
  log "写入 SMTP 凭据 Secret ${NS}/alertmanager-smtp"
  kubectl -n "$NS" create secret generic alertmanager-smtp \
    --from-literal=username="${SMTP_USER}" \
    --from-literal=password="${SMTP_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

log "应用 AlertmanagerConfig（默认 receiver=${DEFAULT_RECEIVER}, warning=${WARN_RECEIVER}, type=${WEBHOOK_TYPE}）"
printf '%s\n' "$AMCONFIG" | kubectl apply -f -
log "完成。核对: kubectl -n ${NS} get alertmanagerconfig,secret"
