# 引导顺序：两平面 + 制品按需导入

> 本文定义**引导面（NOT Flux）**与 **Flux 面** 的边界、启动顺序，以及**由 fleet 模式驱动的按需制品导入**。
> 关联 [`implementation-matrix.md`](implementation-matrix.md)、[`gitops-fleet.md`](gitops-fleet.md)、
> [`data-plane-management.md`](data-plane-management.md)。

## 一、两个平面
| 平面 | 内容 | 管理方式 |
|---|---|---|
| **引导面** | 集群核心（kubeadm/kube-vip、Cilium、Longhorn、cert-manager、kgateway）＋ 数据平面（CNPG/redis-operator + PG/Redis）＋ **Harbor** ＋ **Flux Operator 自身** | 脚本 + Day-0 本地包（**不进 Flux**） |
| **Flux 面** | 其余全部（GitLab、可观测、策略、租户、组件…） | Flux（OCI 制品 + cosign 验签） |

判据：**"要起 Harbor（或集群本身）就必须先有的" → 引导面**。因此 **Harbor 及其依赖的 PG/Redis 属引导面**。

## 二、本集群自启（起步单点，按需扩 HA）
```
0) Day-0 引导包：镜像 tar + chart/manifests 落到"本"宿主机   ★破环（无 registry 也能起）
1) 单点集群（kubeadm + kube-vip；后续 scale-out）
2) 数据平面：CNPG/redis-operator → platform-pg + platform-redis   （Harbor 前置）
3) Harbor（registry 就绪）
4) 制品导入（按 fleet 模式，检测式、增量、签名）——见第四/五节
5) Flux Operator（Helm）+ FluxInstance：接管"非引导面"
6) （后置）Git + CI 作为作者入口；运行时不依赖 Git
```

## 三、成员集群
```
1) 单点集群（按需扩）
2) containerd 指向"本"Harbor（可选本地 proxy cache）
3) 安装 Flux Operator + FluxInstance（源=本 Harbor OCI + 验签）
4) 数据来源【由各自应用决定】：DATA_SOURCE=local|shared（见 data-source.md）
```
- 成员**默认只拉不导**（运行时按需拉取）；离线/边缘才用 lock 做 seed。
- 成员不依赖本集群的 Flux；各自有独立 Flux（或 `ENABLE_FLUX=false` 时用脚本）。

## 四、制品导入：由 fleet 判断（fleet-driven，检测式增量）
```
fleet/<mode>/components.yaml         # 该模式用哪些组件
components/<plane>/<name>/component.yaml   # 组件的 images/artifacts（显式 B）
   │ resolve-artifacts.sh <mode> <env>
   ▼
locks/<mode>-<env>.lock              # 该模式期望制品集（src + Harbor 目标）
   │ sync-artifacts.sh <mode> <env> [--sign]
   ▼
Harbor：检测已存在→跳过；缺失→导入 + cosign 签名
```
命令：
```bash
make resolve-artifacts FLEET_MODE=all-in-one FLEET_ENV=drill
make sync-artifacts    FLEET_MODE=all-in-one FLEET_ENV=drill            # 检测式、幂等
make publish-artifacts FLEET_MODE=all-in-one FLEET_ENV=drill            # resolve + sync + 签名
```

### A+B 解析
- **B（优先）**：`component.yaml` 的 `images:` 显式声明（`<src> <harbor-ref>`）。
- **A（兜底）**：未声明时，对该组件 chart 执行 `helm template` 提取镜像并按 scheme C 生成 Harbor 目标。
- 结果写入 `locks/<mode>-<env>.lock`（可复现、供检测）。

### 检测式（detect-then-import）
| 层 | 检测 | 动作 |
|---|---|---|
| 源 | 有无 `images`？可否渲染？ | 决定 B 还是 A |
| 漂移 | 新解析 vs 已有 lock | 变了重生成，否则跳过 |
| 存在 | Harbor 是否有该 ref | 有跳过；无导入+签名 |
| 消费 | 本地是否已有 | 有跳过；无按需拉取/proxy cache |

## 五、签名（Harbor 侧 + Flux 侧）
1. 推送即签：`sync-artifacts.sh --sign` 对入 Harbor 制品 `cosign sign`（key-based）。
2. 拉取验签：Flux `OCIRepository.verify` + **Harbor 原生 cosign 策略**（项目级强制仅签名制品）。

## 五.1 一键引导命令
```bash
# 本集群（mgmt/all-in-one）自启：Day-0 → 核心 → 数据平面 → Harbor → 制品 → Flux
make mgmt-bootstrap FLEET_MODE=mgmt FLEET_ENV=drill
# 成员集群：指向本 Harbor → Flux → 按需制品
make member-bootstrap FLEET_MODE=biz FLEET_ENV=drill
# 仅准备/校验
bash bootstrap/mgmt/preflight.sh
make verify-bootstrap FLEET_MODE=all-in-one FLEET_ENV=drill
```
脚本：`bootstrap/mgmt/{preflight,import-images,up-core,up-data,up-harbor,up-flux,bootstrap}.sh`、
`bootstrap/member/{configure-registry,up-flux,bootstrap}.sh`、共享 `bootstrap/lib.sh`。

## 六、模式与本平面/Flux 的对应
| 模式 | Harbor | Flux | 参考 `fleet/<mode>` |
|---|---|---|---|
| `all-in-one` | 自启 | 可选 | ✅ |
| `mgmt` | 自启（供成员） | 是 | ✅ |
| `biz` | 消费本 | 是 | ✅ |
| `data` | 消费本（或本地） | 通常否 | ✅ |
