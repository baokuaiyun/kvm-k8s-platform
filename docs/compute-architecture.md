# 计算架构（节点规格 / 节点池 / 调度 / 弹性 / 异构）

> 计算是 **集群平面（`workload` role）的横切图层**，不新增第五平面；覆盖 **宿主 VM → K8s 节点 → 工作负载 → GPU** 四层。
> 关联：[`implementation-matrix.md`](implementation-matrix.md)（四平面/集群平面）、[`parameters.md`](parameters.md)（参数）、
> [`compute-verification.md`](compute-verification.md)（验收）、[`plane-dod.md`](plane-dod.md)（集群平面 DoD）、
> [`cloud-disk-data-solution.md`](cloud-disk-data-solution.md)（计算/存储分离）、[`observability.md`](observability.md)（计算告警）。

## 0. 一句话模型
集群平面保证「单节点↔多节点同契约」；计算图层在其上定义 **节点规格与预留、节点池、调度约束、弹性扩缩、配额与异构**，
让同一套清单在 **单节点 drill、3CP+2W、云上多节点** 上表现一致，且可平滑 scale-out。

---

## 1. 四层模型

```
┌─ 宿主 (KVM/libvirt, 阿里云 ECS/裸机) ────────────────┐
│   vCPU / RAM / 系统盘 (qcow2) / GPU 直通(VFIO)       │  ← 规格与超分发生处
├─ K8s 节点 (kubelet) ────────────────────────────────┤
│   capacity → allocatable = capacity - reserved        │  ← 调度可见的资源池
│   标签/污点 = 节点池；condition = 资源压力             │
├─ 工作负载 (Pod) ─────────────────────────────────────┤
│   requests/limits → QoS；亲和/拓扑/优先级 → 落点       │
└─ 异构 (GPU/设备插件) ────────────────────────────────┘
    nvidia.com/gpu 等扩展资源，独立调度维度
```

配套：**存储与计算分离**（VM 只管运行，数据在云盘/宿主 ZFS，见 `cloud-disk-data-solution.md`），
**节点可重建**，因此计算侧「牲畜化」——扩缩/重建不改契约。

---

## 2. 节点规格与容量

### 2.1 规格（默认值见 `variables.mk`）

| 角色 | 变量 | 默认 | 用途 |
|---|---|---|---|
| 起步单节点 cp-1 | `NODE_VCPU/RAM/DISK` | 8C/16G/120G | 单节点同时承载控制面+存储+平台 |
| 控制面（扩容后） | `CP_VCPU/RAM/DISK` | 2C/4G/30G | 3CP HA |
| Worker（扩容后） | `WK_VCPU/RAM/DISK` | 4C/4G/50G | 业务/平台负载 |

> 单节点起步：`WK_INIT_COUNT=0`，cp-1 用 `NODE_*` 并自动去控制面污点；`make scale-out` 补齐 worker。
> 规格换算：`SINGLE_NODE_SPEC` 自动判定 cp-1 用哪套规格。

### 2.2 capacity vs allocatable

```
allocatable = capacity − kubeReserved − systemReserved − evictionHard
```
- **capacity**：宿主 VM 总资源（`virsh dominfo` / `kubectl describe node` 交叉核对）。
- **allocatable**：调度器真正可分配的资源；验收以 allocatable 为分母。
- **预留**（`RESERVE_CPU/RESERVE_MEM`）：drill 未显式设置 kubelet 预留，视为「无预留」占位；生产建议显式配置，
  否则系统组件与业务争抢，节点易触发驱逐。

### 2.3 超分（overcommit）

| 指标 | 定义 | 阈值变量 | 默认 |
|---|---|---|---|
| CPU 超分比 | Σ `requests.cpu` / Σ `allocatable.cpu` | `OVERCOMMIT_CPU_MAX` | 2.0 |
| 内存超分比 | Σ `requests.memory` / Σ `allocatable.memory` | `OVERCOMMIT_MEM_MAX` | 1.5 |

- **requests 是硬约束**（调度保证），`limits` 可超分（突发）；CPU 可压缩超分，**内存超分有 OOM 风险**，阈值更保守。
- 超分比仅作 **验收预警**（WARN），不阻断；生产按「内存超分 ≤1.5、关键 node pool ≤1.1」控制。

---

## 3. 节点池（Node Pool）

节点池 = **同一角色标签的一组节点**；用标签打点、污点隔离。标签键默认 `COMPUTE_POOL_LABEL=workload.baokuaiyun.com/pool`。

| 节点池（值） | 目标工作负载 | 建议污点 | 对应平面/Role |
|---|---|---|---|
| `workload` | 通用业务（默认） | 无 | 租户/业务 |
| `toolchain` | Harbor/GitLab/CI 构建 | `dedicated=toolchain:NoSchedule` | 工具链 |
| `data` | CNPG/Redis/对象存储 | `dedicated=data:NoSchedule` | 数据 |
| `gpu` | GPU 推理/训练 | `dedicated=gpu:NoSchedule` | 异构 |

- **不破坏不可逆契约**：节点池只加/改标签与污点，不动网段/VIP/SC/Gateway 契约。
- 与 fleet/Role 对齐：`workload` role 落 `workload` 池；`data` role 落 `data` 池（形态 C 专用节点池，见 `data-plane-management.md`）。
- 打标/去标：`make compute-node-pools`（脚本 `scripts/compute-node-pool.sh`，幂等）。

```bash
# 手工示例：把 k8s-worker-2 标为 data 池并加污点
kubectl label node k8s-worker-2 workload.baokuaiyun.com/pool=data --overwrite
kubectl taint node k8s-worker-2 dedicated=data:NoSchedule --overwrite
# 工作负载侧：nodeSelector + toleration
```

调度侧消费：
```yaml
nodeSelector:
  workload.baokuaiyun.com/pool: data
tolerations:
  - key: dedicated
    operator: Equal
    value: data
    effect: NoSchedule
```

---

## 4. 调度约束

| 手段 | 作用 | 典型场景 |
|---|---|---|
| `requests` / `limits` | 决定 QoS 与是否可调度 | 所有业务必填 requests |
| QoS 类 | `Guaranteed`(req=lim) / `Burstable` / `BestEffort`(无) | 有状态/关键用 Guaranteed |
| `nodeSelector` / `nodeAffinity` | 选节点池/机型 | 数据落 `data` 池 |
| `podAntiAffinity` | 分散副本 | CP/DB 跨节点 |
| `topologySpreadConstraints` | 跨节点/可用区均衡 | 多副本业务 |
| `priorityClass` + 抢占 | 关键业务优先调度 | 平台组件 > 业务 |
| `PodDisruptionBudget` | 驱逐保护 | 有状态服务 |

**原则**：生产工作负载必须设 `requests`；`limits` 内存建议设置（防 OOM 波及其他 Pod），CPU `limits` 谨慎（易限流）。

---

## 5. 弹性扩缩（四层，由外到内）

| 层 | 手段 | 粒度 | 变量/目标 | 状态 |
|---|---|---|---|---|
| 宿主/节点 | KVM `scale-out` / 云 ECS 扩容 | 节点 | `make scale-out`；`COMPUTE_ENABLE_AUTOSCALER` | 手工（drill）|
| 集群 | Cluster-Autoscaler / Karpenter（云） | 节点 | `COMPUTE_ENABLE_AUTOSCALER=0` | 待装（prod 云）|
| 工作负载副本 | HPA（CPU/内存/自定义指标） | Pod 副本 | `COMPUTE_ENABLE_HPA=1`（需 metrics-server） | 目标 |
| 工作负载规格 | VPA + Goldilocks（推荐 requests） | Pod 规格 | `COMPUTE_ENABLE_VPA=0` | 可选 |
| 重调度 | descheduler（碎片整理/负载均衡） | Pod 迁移 | `COMPUTE_ENABLE_DESCHEDULER=0` | 可选 |

**依赖**：HPA/VPA/`kubectl top` 都依赖 **metrics-server**（`COMPUTE_ENABLE_METRICS_SERVER=1`）——镜像已在镜像清单（Tier2），
`make metrics-server` 安装。无 metrics-server 时 HPA 无法取值（验收降级为 SKIP）。

不要同时用「HPA 按 CPU」和「VPA 改 CPU requests」于同一负载（互相打架）；VPA 用 `updateMode: Off` 做推荐、HPA 用副本。

---

## 6. 容量与配额

### 6.1 命名空间配额（租户）

`infrastructure/security/tenant-baseline.yaml` + `infrastructure/tenants/create-tenant.sh`：
- `ResourceQuota`：`requests/limits.cpu/memory`、PVC 数、存储、LB 数（占位符由 `TENANT_QUOTA_*` 替换）。
- `LimitRange`：容器默认 request/limit（未填时的兜底）。

```bash
bash infrastructure/tenants/create-tenant.sh team-a 4 8Gi 8 16Gi
# 或走 defaults（variables.mk TENANT_QUOTA_*）
```

### 6.2 容量规划公式（每节点）

```
可调度余量 ≈ allocatable − Σ(existing requests)         # 调度视角
安全水位   ≈ allocatable × (1 − 预留率)                  # 建议预留 10~20%
节点数     ≈ Σ(工作负载峰值 requests) / 单节点安全水位 × 冗余系数(1.3~2)
```
内存以 `requests` 估（OOM 取决于实际使用，需监控），CPU 可用超分但到水位要告警。

### 6.3 金标 profile S/M/L（与 `implementation-matrix.md` 对齐）

| 档 | 集群 | 单节点规格建议 | 弹性 |
|---|---|---|---|
| S | 单节点 | 8C/16G（drill） | HPA 可选 |
| M | 3CP+2W 跨 AZ | CP 2C/4G，WK 4~8C/8~16G | HPA + VPA(Off) + descheduler |
| L | 多集群/多节点池 | 按池分机型（GPU/内存型） | 全弹性 + Cluster-Autoscaler |

---

## 7. 异构 / GPU

**drill 无 GPU**：`COMPUTE_ENABLE_GPU=0`，验收对 GPU 检查 `SKIP`。生产按下列路径：

1. **宿主直通（KVM）**：PCI 设备绑定 `vfio-pci`，VM 配置 `<hostdev>`，见 `kvm/` 的 VM 模板扩展；云上用 GPU ECS。
2. **节点暴露**：厂商 **device plugin** DaemonSet（如 `nvidia-device-plugin`）→ 节点出现扩展资源 `nvidia.com/gpu`。
3. **节点池**：GPU 节点打 `workload.baokuaiyun.com/pool=gpu` + `dedicated=gpu:NoSchedule`；可选 `nvidia.com/gpu.product` 标签区分型号。
4. **调度**：工作负载 `resources.limits[COMPUTE_GPU_RESOURCE]=1` + toleration；GPU 是 **整数扩展资源**，不可超分。

> 镜像/驱动走本域 Harbor（Tier2），device plugin 通过 GitOps 组件交付；drill 不装，验收以「无 GPU 则 SKIP」处理。

---

## 8. 不可逆契约（构建前锁定）

1. **节点池标签键**：`workload.baokuaiyun.com/pool`（值 = 池名），一经发布不改键名。
2. **污点键**：`dedicated=<pool>:NoSchedule`（与标签值一致）。
3. **资源单位**：CPU 用核/毫核，内存用 Mi/Gi；扩展资源用厂商标准名（`nvidia.com/gpu`）。
4. **弹性开关命名**：`COMPUTE_ENABLE_*`，语义为「能力可用」而非「已安装」。
5. 节点池只增标签/污点，**不改** 网段/VIP/SC 名/Gateway 监听名。

---

## 9. 与四平面 / DoD 对应

- 计算属 **集群平面**：DoD 增加「规格/allocatable/超分可核对、节点池可声明、弹性能力可验证」。
- 租户平面消费计算：`ResourceQuota/LimitRange` 由计算侧的容量模型约束。
- 数据平面消费计算：形态 C 为「业务集群专用节点池」。
- 工具链平面提供弹性的制品（metrics-server/VPA/descheduler 镜像与 chart）。

---

## 10. 命令速查

```bash
# 规格与容量
kubectl get nodes -o wide
kubectl describe node <n> | sed -n '/Capacity/,/Allocatable/p'
kubectl get node <n> -o jsonpath='{.status.allocatable}'

# 节点池
make compute-node-pools                    # 幂等打标（按 variables.mk）
kubectl get nodes -L workload.baokuaiyun.com/pool

# 用量与调度
kubectl top nodes; kubectl top pods -A --sort-by=cpu
kubectl get pods -A --field-selector=status.phase=Pending

# 弹性
make metrics-server                        # 安装 metrics-server
kubectl get hpa -A; kubectl get vpa -A; kubectl get pods -n kube-system | grep descheduler

# 验收
make verify-compute                        # 只读巡检
make verify-compute TARGET=drill           # 含完整演练+压测（自清理）
```

> 验收细节、分区、排障见 [`compute-verification.md`](compute-verification.md)。