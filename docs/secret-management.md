# 凭据管理规划（Secrets）

> 现状：密码在 `acr.env`（已 gitignore）明文保存，部署时注入 Secret。
> 目标：生产用 **Sealed-Secrets** 或 **External-Secrets**，可安全入 Git。

## 一、涉及凭据

| 凭据 | 变量 | 用途 |
|---|---|---|
| PG 角色密码 | `PG_HARBOR_PASS` / `PG_GITLAB_PASS` / `PG_CASDOOR_PASS` | CNPG managed.roles |
| Redis 密码 | `REDIS_PASS` | platform-redis |
| Harbor admin | `HARBOR_ADMIN_PASS`（别名 `HARBOR_PASS`，两者同步） | Harbor（`harborAdminPassword`） |
| Harbor robot | `HARBOR_ROBOT_USER` / `HARBOR_ROBOT_PASS` | CI 推拉镜像 |
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

## 六、Harbor admin 凭据与轮换

- **用户名**：`admin`（`HARBOR_USER`）；另有 robot `robot$<project>+pushpull`（CI 推拉）。
- **密码**：规范变量 `HARBOR_ADMIN_PASS`（别名 `HARBOR_PASS`，两者自动同步）；默认占位 `admin123`，**真实值在 `acr.env`**（S 层）。
- **注入**：`kubernetes/configs/harbor-values.yaml` 的 `harborAdminPassword: __HARBOR_ADMIN_PASS__`，由 `make harbor` 渲染；**仅首次安装**用于初始化 admin 密码（之后存于 Harbor DB，改 values 不会改已存在密码）。
- **查看**（避免明文落盘/日志）：
  ```bash
  make harbor-admin-info                    # 只显示账号与来源
  grep -E '^HARBOR_(ADMIN_)?PASS' acr.env   # 源（acr.env，gitignored）
  kubectl -n harbor get secret harbor-core -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d; echo
  ```
- **轮换**：
  ```bash
  make harbor-rotate-admin HARBOR_ADMIN_CURRENT=<旧密码> [HARBOR_ADMIN_NEW=<新密码>]
  # 新密码留空则随机生成；成功后写回 acr.env 的 HARBOR_ADMIN_PASS / HARBOR_PASS
  # 脚本 registry/harbor-rotate-admin.sh：经 kubectl exec harbor-core 调 API，无需对外暴露
  ```
