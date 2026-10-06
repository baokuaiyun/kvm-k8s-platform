# 镜像清单（按 Tier/阶段拆分）

| 文件 | Tier | 内容 |
|---|---|---|
| `tier0-core.txt` | Tier0 | k8s 核心 + kube-vip + Cilium（不齐集群起不来） |
| `tier1-infra.txt` | Tier1 | Longhorn + cert-manager |
| `tier2-platform.txt` | Tier2 | CNPG/redis-operator/redis/harbor/casdoor/gitlab 等平台应用 |
| `tier3-observability.txt` | Tier2(观测) | prometheus/grafana/loki/otel/blackbox/kube-state-metrics |

行格式：`<源镜像>  <旧本域仓库后缀>  <Tier>  [<ACR后缀>]`

- 新目标名由 **scheme C** 规则从 `<源镜像>` 自动生成（`<group>-<name>`；核心 kubeadm=basename；kube-vip=单名）。
- 第二列（旧后缀）用于定位已预载的 tar（`prepare`/`push-tars`）。
- 脚本支持把 `LIST` 指向本目录（自动合并 `tier*.txt`）。

> 由原 `registry/acr-images-list.txt` 拆分而来；`images-list.txt` 已合并。
