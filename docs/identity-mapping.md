# 身份映射与 OIDC 对接（Casdoor → Harbor/GitLab/k8s）

> 原则：**一套身份（Casdoor），按组授权，不按人**；保留少量 break-glass 本地管理员；
> 自动化用 robot/service 账号。关联 [`identity-sso-casdoor.md`](identity-sso-casdoor.md)、
> [`implementation-matrix.md`](implementation-matrix.md)（不可逆契约：身份模型）。

## 一、现状（drill）
- Casdoor 已部署：`https://casdoor.test.baokuaiyun.com`，健康，OIDC discovery 可用。
- 应用：`app-built-in`（org `built-in`）。已设置回调：
  - `https://harbor.test.baokuaiyun.com/c/oidc/callback`
  - `https://gitlab.test.baokuaiyun.com/users/auth/openid_connect/callback`
  - `grant_types: ["authorization_code","refresh_token"]`
- client 凭据存于 Casdoor（`application` 表 `client_id`/`client_secret`），**不写入 Git**。

## 二、组 → 权限映射（权威表）
| Casdoor 组 | Harbor | GitLab | k8s |
|---|---|---|---|
| `platform-admin` | Project Admin | Owner | `cluster-admin`（受控） |
| `dev` | Developer | Developer | `edit`（命名空间） |
| `audit` | Guest | Reporter | `view` |

> 落地方式：Harbor `oidc_admin_group=platform-admin`；GitLab 用 `groups` claim 映射到 group membership；
> k8s 用 OIDC 认证（或 Casdoor 组经 IdP 映射）绑定 RoleBinding。

## 三、Harbor OIDC（可切换，含回滚）
```bash
# 用 Harbor admin 调 API 切换（drill 自签，注意 --noproxy）
BASE=https://harbor.test.baokuaiyun.com
curl -sk --noproxy '*' -u admin:$HARBOR_ADMIN_PASS -X PUT "$BASE/api/v2.0/configurations" \
  -H 'Content-Type: application/json' -d '{
    "auth_mode":"oidc",
    "oidc_name":"casdoor",
    "oidc_endpoint":"https://casdoor.test.baokuaiyun.com",
    "oidc_client_id":"<casdoor app client_id>",
    "oidc_client_secret":"<casdoor app client_secret>",
    "oidc_scope":"openid,profile,email,groups",
    "oidc_groups_claim":"groups",
    "oidc_admin_group":"platform-admin",
    "oidc_auto_onboard":true,
    "oidc_user_claim":"preferred_username"
  }'
# 回滚（把本地管理员救回）：
curl -sk --noproxy '*' -u admin:$HARBOR_ADMIN_PASS -X PUT "$BASE/api/v2.0/configurations" \
  -H 'Content-Type: application/json' -d '{"auth_mode":"db_auth"}'
```
> ⚠️ 切 `oidc` 后本地账号登录被关；务必先确认可回滚（上表 API 或改 PG `properties` 表）。
> drill 暂**未切换**，避免锁死（见 implementation-status）。

## 四、GitLab OIDC（保留 root break-glass）
在 GitLab CR（`platform/gitlab/gitlab-cr.yaml`）`global.appConfig.omniauth` 增加：
```yaml
global:
  appConfig:
    omniauth:
      enabled: true
      autoSignInWithProvider: casdoor
      providers:
        - name: openid_connect
          label: Casdoor
          args:
            name: openid_connect
            scope: ["openid","profile","email"]
            response_type: code
            issuer: https://casdoor.test.baokuaiyun.com
            discovery: true
            client_auth_method: query
            uid_field: preferred_username
            client_options:
              identifier: "<casdoor app client_id>"
              secret: "<casdoor app client_secret>"
              redirect_uri: https://gitlab.test.baokuaiyun.com/users/auth/openid_connect/callback
```
> 应用后 GitLab 登录页出现 "Casdoor"；`root` 本地登录保留为 break-glass。

## 五、验证清单
```bash
curl -sk https://casdoor.test.baokuaiyun.com/.well-known/openid-configuration   # discovery
# Harbor UI：登录页出现 OIDC 按钮；用户来源显示 casdoor
# GitLab：登录页出现 Casdoor 按钮
# k8s：--oidc-issuer 认证 + 组 RoleBinding 生效
```

## 六、待办
- [ ] 切换 Harbor `auth_mode=oidc`（含回滚演练）。
- [ ] 应用 GitLab omniauth（会触发 CR reconcile/迁移）。
- [ ] k8s API OIDC 认证（apiserver 参数 + 组 RoleBinding）。
- [ ] Casdoor 建正式组织/组/应用（替换 built-in），client 凭据入 KMS/Sealed。
