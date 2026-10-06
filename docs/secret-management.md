# 凭据管理规划（Secrets）

> 现状：密码在 `acr.env`（已 gitignore）明文保存，部署时注入 Secret。
> 目标：生产用 **Sealed-Secrets** 或 **External-Secrets**，可安全入 Git。

## 一、涉及凭据

| 凭据 | 变量 | 用途 |
|---|---|---|
| PG 角色密码 | `PG_HARBOR_PASS` / `PG_GITLAB_PASS` / `PG_CASDOOR_PASS` | CNPG managed.roles |
| Redis 密码 | `REDIS_PASS` | platform-redis |
| Harbor admin | `HARBOR_PASS` | Harbor |
| ACR 凭据 | `ACR_USER` / `ACR_PASS` | 镜像同步 |
| 云 AK/SK | `ALIYUN_ACCESS_KEY` / `ALIYUN_SECRET_KEY`（`S3_ACCESS_KEY`/`S3_SECRET_KEY`） | OSS、DNS、云盘、Velero |
| Longhorn 备份 | `LONGHORN_ACCESS_KEY` / `LONGHORN_SECRET_KEY` | backupTarget S3 |

## 二、方案对比

| 方案 | 适用 | 优点 | 缺点 |
|---|---|---|---|
| `acr.env` 明文（现状） | 本地演练 | 简单 | 不可入 Git，轮换难 |
| **Sealed-Secrets** | 单集群/少量密钥 | 密文可入 Git，无需外部依赖 | 按集群绑定 |
| **External-Secrets** | 多集群/云 | 与 KMS/Secrets Manager 同步，集中轮换 | 需外部 Secret 存储 |

**建议**：drill 继续 `acr.env`；prod 用 **External-Secrets + 阿里云 KMS**，
或先用 Sealed-Secrets 过渡。

## 三、Sealed-Secrets 样板

安装 controller：

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  -n kube-system --set fullnameOverride=sealed-secrets-controller
```

生成密文（本地，不提交明文）：

```bash
kubectl -n platform-data create secret generic harbor-pg-cred \
  --from-literal=username=harbor --from-literal=password='<REAL>' \
  --dry-run=client -o yaml \
  | kubeseal --controller-name=sealed-secrets-controller \
      --controller-namespace=kube-system -o yaml > sealed/harbor-pg-cred.yaml
```

示例见 `infrastructure/security/sealed-secret.example.yaml`（占位密文）。

## 四、External-Secrets 样板（生产）

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata: {name: aliyun-kms}
spec:
  provider:
    alibaba:
      regionID: cn-hangzhou
      auth:
        secretRef:
          accessKeyIDSecretRef: {name: aliyun-ak, key: access-key}
          accessKeySecretSecretRef: {name: aliyun-ak, key: secret-key}
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata: {name: harbor-pg-cred, namespace: platform-data}
spec:
  refreshInterval: 1h
  secretStoreRef: {name: aliyun-kms, kind: ClusterSecretStore}
  target: {name: harbor-pg-cred}
  data:
    - secretKey: username
      remoteRef: {key: prod/pg/harbor, property: username}
    - secretKey: password
      remoteRef: {key: prod/pg/harbor, property: password}
```

## 五、迁移步骤

1. 把 `acr.env` 各密码预置进 KMS / Secrets Manager。
2. 部署 Sealed-Secrets 或 External-Secrets。
3. 逐个把 `deploy.sh`/values 注入的 Secret 替换为密文清单或 ExternalSecret。
4. 轮换一次全部凭据，确认无明文残留。
