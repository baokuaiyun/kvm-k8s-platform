# 计算验证（Compute Verification）

> 目标：把 [`compute-architecture.md`](compute-architecture.md) 的节点规格/节点池/调度/弹性/配额/异构设计，
> 变成 **可执行、可复现、可入库** 的核对。
> 风格与 `make verify-storage` / `make verify-network` 一致：**退出码即结论**；**主要命令逐条回显**，方便讲学与证据留痕。
> 关联 [`compute-architecture.md`](compute-architecture.md)、[`parameters.md`](parameters.md)、[`evidence-and-acceptance.md`](evidence-and-acceptance.md)。

## 一、一键验证

```bash
make verify-compute                          # 只读巡检（8 项，ENV=drill）
make verify-compute TARGET=drill             # 只读 + 完整演练/压测（临时 ns，自清理）
COMPUTE_ENABLE_GPU=1 make verify-compute     # 开 GPU 检查分支
KUBECTL_VERIFY_ECHO=0 make verify-compute    # 静默模式（不回显命令，只留结论）

make compute-drill                           # 等价于 verify-compute TARGET=drill（重演练单独入口）
```

- 退出码：`0`=通过（可含 WARN/SKIP），`1`=存在 FAIL，`2`=前置缺失（无 kubectl / 集群不可达）。
- 默认**逐条回显**实际执行的 `kubectl` 命令（`  $ ...` 前缀）。
- 只读部分纳入 `make verify`（全量验收）与 `make evidence`（check 名 `compute_verify`）；
  **演练/压测不默认执行**（用 `make compute-drill` 显式触发）。

## 二、检查分区（只读，8 项）

| # | 分区 | 关键检查 | 关联命令 |
|---|---|---|---|
| 1 | 节点就绪与规格 | 全部 Ready；capacity/allocatable CPU/内存；KVM 宿主 VM 规格交叉核对 | `kubectl get nodes`、`virsh dominfo` |
| 2 | 分配与超分 | 每节点 Σrequests/allocatable；超分比 ≤ 阈值；预留提示 | `kubectl describe node`、`kubectl get pods -A -o json` |
| 3 | 压力与调度 | `MemoryPressure`/`DiskPressure`/`PIDPressure`；驱逐记录；Pending 原因 | `kubectl get node -o json`、`kubectl get events` |
| 4 | 配额与默认限 | namespace `ResourceQuota` used/hard；`LimitRange`；全集群缺 requests/limits 的 Pod | `kubectl get resourcequota -A`、`kubectl get pods -A -o json` |
| 5 | 弹性能力 | metrics-server、HPA（含 targets）、VPA CRD、descheduler、autoscaler | `kubectl top nodes`、`kubectl get hpa,vpa -A` |
| 6 | 节点池 | 池标签分布；池与污点一致性 | `kubectl get nodes -L $COMPUTE_POOL_LABEL` |
| 7 | 异构/GPU | `nvidia.com/gpu` 容量、device plugin Pod、GPU 节点标签（无则 SKIP） | `kubectl get node -o json` |
| 8 | 计算告警 | PrometheusRule 含 CPU 限流/超分/不可调度/配额告警 | `kubectl -n monitoring get prometheusrule` |

## 三、逐项：命令 / 期望 / 排障

### 1. 节点就绪与规格

```bash
kubectl get nodes -o wide
kubectl describe node <n> | sed -n '/Capacity/,/Allocatable/p'
virsh dominfo <vm>            # 仅 KVM 宿主；核对 vCPU/内存与 NODE_/CP_/WK_*
```

- **期望**：全部节点 `Ready`；capacity 与 `variables.mk` 机型规格一致（drill 单节点 8C/16G）。
- **排障**：NotReady → 看 kubelet/containerd；capacity 与预期不符 → 改 `variables.mk` 后重建/`make scale-out`。

### 2. 分配与超分

```bash
# 每节点 requests 汇总（脚本自动算）
kubectl describe node <n> | grep -A6 "Allocated resources"
kubectl get pods -A -o json    # 脚本聚合 requests
```

- **期望**：CPU 超分比 ≤ `OVERCOMMIT_CPU_MAX`(2.0)、内存 ≤ `OVERCOMMIT_MEM_MAX`(1.5)（超出为 WARN）。
- **排障**：超分过高 → 下调 requests 或加节点；内存超分告警优先处理（OOM 风险）。

### 3. 压力与调度

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="MemoryPressure")].status}{"\n"}{end}'
kubectl get pods -A --field-selector=status.phase=Pending
kubectl get events -A --field-selector reason=Evicted
```

- **期望**：无 `*Pressure=True`；无长期 Pending；无近期驱逐。
- **排障**：压力 → 释放/迁移负载、加内存；Pending → `kubectl describe pod` 看调度失败原因（资源/亲和/污点/PVC）。

### 4. 配额与默认限

```bash
kubectl get resourcequota -A
kubectl get limitrange -A
kubectl get pods -A -o json    # 脚本找缺 requests/limits 的容器
```

- **期望**：租户 ns 有 `ResourceQuota` 且 `used/hard` 未近满；有 `LimitRange`；生产业务容器均设 requests。
- **排障**：配额将满 → 扩容配额或清理；缺 requests → 补清单（否则 BestEffort，易被驱逐）。

### 5. 弹性能力

```bash
kubectl top nodes                       # 需 metrics-server
kubectl get hpa -A
kubectl get crd verticalpodautoscalers.autoscaling.k8s.io
kubectl -n kube-system get pods | grep -E 'descheduler|cluster-autoscaler'
```

- **期望**：`COMPUTE_ENABLE_METRICS_SERVER=1` 时 metrics-server Running（`kubectl top` 有数据）；HPA 有目标值。
- **排障**：`kubectl top` 报 `Metrics API not available` → `make metrics-server`；HPA `<unknown>` → 指标不足或副本已到界。

### 6. 节点池

```bash
kubectl get nodes -L workload.baokuaiyun.com/pool
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" taints="}{.spec.taints}{"\n"}{end}'
```

- **期望**：节点按池打标（drill 默认 `workload`）；污点值与池名一致（若使用）。
- **排障**：未打标 → `make compute-node-pools`；污点与标签不一致 → 重跑脚本（幂等覆盖）。

### 7. 异构 / GPU

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
kubectl -n kube-system get pods | grep -i 'device-plugin\|nvidia'
```

- **期望**：`COMPUTE_ENABLE_GPU=0` 时整项 `SKIP`；为 `1` 时存在 GPU 容量与 device plugin。
- **排障**：无 GPU 资源 → 查 VFIO 直通 / 驱动 / device plugin；见 `compute-architecture.md` 第 7 节。

### 8. 计算告警

```bash
kubectl -n monitoring get prometheusrule cluster-alerts -o yaml | grep -E 'CPUThrottlingHigh|NodeAllocatableOvercommit|QuotaNearFull|UnschedulablePods'
```

- **期望**：计算相关告警规则在位。
- **排障**：缺失 → `make alerts`（重放 `observability/alerts.yaml`）。

## 四、完整演练与压测（`TARGET=drill` / `make compute-drill`）

> 全自动、**幂等**、`trap` 清理；不触碰生产命名空间（默认 `compute-drill`，可用 `COMPUTE_DRILL_NS` 覆盖）。

步骤：
1. 建临时 ns（带 PSA/配额），部署 **stress Pod**（`requests=COMPUTE_STRESS_CPU/COMPUTE_STRESS_MEM`，`limits` 略高）→ 验证 **可调度、Running、QoS=Burstable**。
2. `kubectl top` 观察该 Pod 有指标（验证 metrics-server 通路）。
3. `COMPUTE_ENABLE_HPA=1` 且有 metrics-server 时，创建引用该 Deployment 的 **HPA**，等待 `TARGETS` 出现数值（不保证触发扩容）。
4. 校验 **节点池/污点** 对调度的影响（无池时跳过）。
5. **清理**：删 ns 与所有对象；重复运行结果一致。

```bash
make compute-drill COMPUTE_STRESS_CPU=4 COMPUTE_STRESS_MEM=512Mi COMPUTE_DRILL_TIMEOUT=300
```

- **期望**：各步骤 `[OK]`，退出码 0，结束后 ns 被清除。
- **排障**：Pending → 集群资源不足或镜像未镜像到 Harbor（`COMPUTE_DRILL_IMAGE`）；无指标 → 装 metrics-server。

## 五、drill 与 prod 差异

| 检查 | drill（KVM 单节点） | prod（阿里云多节点） |
|---|---|---|
| 宿主核对 | `virsh dominfo` 可查 VM 规格 | 云控制台/ECS 规格 |
| 节点池 | 默认单池 `workload` | `workload/data/gpu` 多池 |
| 超分 | 起步宽松（可 WARN） | 严控（内存 ≤1.5） |
| 弹性 | metrics-server + HPA | + Cluster-Autoscaler/VPA/descheduler |
| GPU | `SKIP`（`COMPUTE_ENABLE_GPU=0`） | device plugin + GPU 池 |

## 六、证据入库

```bash
make evidence CHECKS="compute_verify"     # 只读巡检
# 产出: evidence/<env>/<ts>/{report.json,report.md,compute_verify.log}
```

因命令已逐条回显，`compute_verify.log` 天然包含「命令 + 输出 + 退出码」，可直接作为验收证据。
演练/压测证据请单独执行 `make compute-drill 2>&1 | tee evidence/<env>/<ts>/compute_drill.log`。

## 七、常见故障定位表

| 现象（脚本输出） | 可能原因 | 处置 |
|---|---|---|
| `节点 N NotReady` | kubelet/containerd/网络异常 | 查节点日志，必要时 cordon/重建 |
| `CPU 超分比 N > 2.0` | requests 过高/节点不足 | 降 requests 或加节点 |
| `内存超分比 N > 1.5` | 内存 requests 超额 | 加内存/降 requests（OOM 风险） |
| `存在 X 个缺 requests 的容器` | 清单未设资源 | 补 requests/limits，避免 BestEffort |
| `MemoryPressure=True` | 内存不足 | 迁移/扩容；查 OOM 源 |
| `Pending Pod N 个` | 资源/亲和/污点/PVC | `kubectl describe pod` |
| `metrics-server 未安装` | 未装 | `make metrics-server` |
| `HPA targets=<unknown>` | 指标缺失/无负载 | 装 metrics-server / 生成负载 |
| `节点未打节点池标签` | 未执行打标 | `make compute-node-pools` |
| `无 GPU 资源` | 未直通/无 device plugin | 见架构文档第 7 节 |
| `缺计算告警规则` | 未重放告警 | `make alerts` |
| 演练 `stress Pod Pending` | 资源不足/镜像缺失 | 调小压力 / 同步镜像到 Harbor |