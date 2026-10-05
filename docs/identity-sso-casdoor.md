# 统一用户管理：Casdoor IdP（集群内）

> 目标：**一套身份**登录 Harbor / GitLab / ArgoCD / Backstage（及后续系统）。
> 原则：日常用户走 SSO；仅保留少量 **break-glass 本地管理员**；自动化用 **robot/service 账号**。

## 一、原则

| 类别 | 用途 | 账号 |
|---|---|---|
| SSO 用户 | 人（开发/运维/审计） | Casdoor 用户，按**组**授权 |
| break-glass | 引导 / 应急 | Harbor `admin`、GitLab `root`（强密码，存密钥库） |
| 自动化 | Flux / CI / 拉取 | Harbor robot account、GitLab deploy/project token、k8s SA |

**不要**为每个系统各建“最高权限人类账号”；权限集中在 Casdoor 组织/组里。

## 二、部署（集群内）

```bash
# 变量（variables.mk / acr.env）
#   CASDOOR_HOST=casdoor.test.baokuaiyun.com
#   CASDOOR_VERSION / CASDOOR_DB_USER / CASDOOR_DB_PASS / CASDOOR_DB_NAME

make idp          # = platform/casdoor/deploy.sh：渲染并 apply -k platform/casdoor/
```

清单（`platform/casdoor/`）：
- `namespace.yaml` / `postgres.yaml`（bitnami postgres + Longhorn PVC）
- `casdoor.yaml`（Deployment + ConfigMap `app.conf` + Service）
- `route.yaml`（Gateway API HTTPRoute，host `casdoor.<DOMAIN>`）

依赖：
- StorageClass `longhorn`（阶段 1 已装）
- kgateway（阶段 3）与通配符证书 `*.test.baokuaiyun.com`（cert-manager）
- 镜像 `docker.io.casbin.casdoor` 与 `docker.io.bitnami.postgresql` 已在本域预载（Tier2）

内网 DNS：`casdoor.test.baokuaiyun.com` → 集群入口 VIP（见 `kvm/br-prod.xml` 的 dnsmasq 记录；生产用 PrivateZone）。

登录：`https://casdoor.${DOMAIN}`，初始管理员通常 `admin/123`，**立即改密**。

## 三、Casdoor 配置

1. 组织（Organization）：`baokuaiyun`
2. 应用（Application）：为每个系统建一个（Harbor / GitLab / ArgoCD / Backstage），拿 `Client ID` / `Client Secret` / OIDC Discovery URL：
   `https://casdoor.${DOMAIN}/.well-known/openid-configuration`
3. 组（Group）：如 `platform-admin`、`dev`、`audit`，用户入组
4. 用户：由 Casdoor 管理；下发 `groups`（或 `roles`）claim

## 四、各系统 OIDC 对接

### Harbor（`auth_mode=oidc`）
```yaml
# values
expose: ...
# 在 Harbor 配置（或 helm values）：
#   auth_mode: oidc
#   oidc_name: casdoor
#   oidc_endpoint: https://casdoor.${DOMAIN}
#   oidc_client_id / oidc_client_secret: <Casdoor 应用>
#   oidc_scope: openid,profile,email,groups
#   oidc_groups_claim: groups
#   oidc_admin_group: platform-admin
#   oidc_auto_onboard: true
#   oidc_user_claim: preferred_username
```

### GitLab（OmniAuth OpenID Connect）
```ruby
# gitlab.rb / values
gitlab_rails['omniauth_enabled'] = true
gitlab_rails['omniauth_providers'] = [{
  name: 'openid_connect',
  label: 'Casdoor',
  args: {
    name: 'openid_connect',
    scope: ['openid','profile','email'],
    response_type: 'code',
    issuer: 'https://casdoor.' + ENV['DOMAIN'],
    discovery: true,
    client_auth_method: 'query',
    uid_field: 'preferred_username',
    client_options: { identifier: '<id>', secret: '<secret>', redirect_uri: 'https://gitlab.' + ENV['DOMAIN'] + '/users/auth/openid_connect/callback' }
  }
}]
```
保留 `root` 本地登录作 break-glass。

### ArgoCD
```yaml
# argocd-cm
url: https://argocd.${DOMAIN}
oidc.config: |
  name: Casdoor
  issuer: https://casdoor.${DOMAIN}
  clientID: <id>
  clientSecret: <secret>
  requestedScopes: ["openid","profile","email","groups"]
  requestedIDTokenClaims: {"groups": {"essential": true}}
# argocd-rbac-cm：g, <casdoor-group>, role:admin
```

### Backstage
```yaml
# app-config.yaml
auth:
  environment: production
  providers:
    oidc:
      production:
        metadataUrl: https://casdoor.${DOMAIN}/.well-known/openid-configuration
        clientId: <id>
        clientSecret: <secret>
```

## 五、RBAC 映射（按组，别按人）

| Casdoor 组 | Harbor | GitLab | ArgoCD | k8s |
|---|---|---|---|---|
| platform-admin | Project Admin | Owner | role:admin | cluster-admin(受控) |
| dev | Developer | Developer | role:readonly | edit(命名空间) |
| audit | Guest | Reporter | role:readonly | view |

## 六、自动化账号（最小权限）

- **Harbor robot account**：按项目建，仅 pull/push，k8s Secret 挂给 Flux/CI
- **GitLab deploy token / project access token**：只读仓库或推送镜像
- **Kubernetes ServiceAccount**：工作负载身份，不共享人类凭据
- 所有令牌入密钥库（阿里云 KMS / k8s Secret），**不入 git**

## 七、验证

```bash
kubectl -n casdoor get pods
curl -sk https://casdoor.${DOMAIN}/.well-known/openid-configuration | head
# Harbor UI → Administration → Users 显示来源 casdoor
# GitLab 登录页出现 “Casdoor” 按钮
# ArgoCD 登录页出现 “Log in via Casdoor”
```

## 八、与 .com.cn 一致

`.com.cn` 环境已在用 `casdoor.baokuaiyun.com.cn`；`.com`/test 用同一 Casdoor 组织与组命名（`baokuaiyun`），便于最终合并与统一审计。
