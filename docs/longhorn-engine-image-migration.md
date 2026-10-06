# Longhorn 引擎镜像迁移与故障恢复（Runbook）

本页记录把 Longhorn 引擎镜像从旧项目 `k8s-library` 迁移到 `baokuaiyun`（scheme C）
的**正确流程**，以及一次真实踩坑后的恢复步骤。适用于单机 KVM 演练集群
（2 个存储节点：`k8s-worker-1` / `k8s-worker-2`，各 50G 盘）。

## 背景

镜像方案 C 要求所有镜像统一到 Harbor 单项目 `baokuaiyun`。Longhorn 的数据面
（Engine/Replica 进程）由「引擎镜像」驱动，迁移涉及三类 CR：

| 资源 | 字段 | 说明 |
| --- | --- | --- |
| `volumes.longhorn.io` | `spec.image` / `spec.engineImage` | 卷期望的引擎镜像 |
| `engines.longhorn.io` | `spec.image` | 运行中的引擎实例 |
| `replicas.longhorn.io` | `spec.image` | 副本实例 |
| `engineimages.longhorn.io` | `spec.image` | 集群内已部署引擎镜像（名字 `ei-<sha8>`） |

**关键点**：`EngineImage` 的 `metadata.name` 是镜像字符串的哈希（`ei-` + sha256 前 8 位），
不能随意命名；只有 `spec.image` 完全一致时名字才匹配。

## 错误做法（本次故障根因）

直接删除旧 `EngineImage`、并把运行中 `Volume/Engine/Replica` 的 `spec.image`
原地改成新镜像，导致：

1. 卷 attach 预检 `failed to get engine image ... ei-0d40be51 not found`（旧 EI 已删）。
2. 卷已在旧引擎下挂载，引擎被切换/重挂后，**消费方 Pod 的挂载变为陈旧挂载**，
   表现为文件系统层 `Input/output error`：
   - PG：`could not open file "global/pg_filenode.map": Input/output error`
   - Registry：`open /storage/docker/registry/.../link: input/output error`
3. 消费方需从 Harbor 拉镜像，而 Harbor 认证依赖 `platform-pg` → PG 卷损坏/陈旧
   → Harbor 401 → **死锁**（PG 起不来、Harbor 认证失败、新 Pod 全部 ImagePullBackOff）。

## 正确迁移流程

> 原则：**先停消费方、让卷 detached，再换引擎镜像**，绝不在挂载状态下原地改 image。

1. **停消费方**：把使用 Longhorn 卷的工作负载 scale 到 0（或删除 Pod），确保卷 detached。

   ```bash
   kubectl -n platform-data scale sts platform-redis --replicas=0
   kubectl -n harbor scale deploy harbor-registry --replicas=0   # 含 PVC 的组件
   ```

2. **确认卷已 detached**：

   ```bash
   kubectl -n longhorn-system get volumes.longhorn.io \
     -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.state}{"\n"}{end}'
   ```

3. **改卷期望镜像**（detached 时才生效）：

   ```bash
   NEW=harbor.test.baokuaiyun.com/baokuaiyun/longhornio-longhorn-engine:v1.7.0
   for v in $(kubectl -n longhorn-system get volumes.longhorn.io -o name); do
     kubectl -n longhorn-system patch "$v" --type=merge -p "{\"spec\":{\"image\":\"$NEW\"}}"
   done
   ```

4. **部署新 EngineImage**（通常由 Longhorn 自动创建；确认 `ei-f2d02cde` 为 `deployed`）。

5. **删除旧 EngineImage**（确认没有卷引用旧镜像后再删）。

6. **拉起消费方**：`scale` 回 1。新 Engine/Replica 会以新镜像重建，数据在副本目录上保留。

7. **校验**：`kubectl -n longhorn-system get volumes.longhorn.io` 全部 `healthy`。

## 死锁恢复（本次采用）

当已经卡在「PG 起不来 + Harbor 认证失败」时，用**本地 tar 离线导镜像**破环：

```bash
# 1) 在需要拉起 Pod 的节点导入组件镜像并补 scheme-C 别名
ctr -n k8s.io images import /tmp/<tar>            # tar 内部可能仍是旧名
ctr -n k8s.io images tag --force \
  harbor.test.baokuaiyun.com/k8s-library/<old> \
  harbor.test.baokuaiyun.com/baokuaiyun/<new>:<tag>

# 2) 重启因陈旧挂载报 I/O 错误的 Pod（PG / registry / jobservice ...）
kubectl -n platform-data delete pod platform-pg-1
```

本次用到的镜像 tar 均位于 `/data/kvm/images/registry/`，例如：

- `..._cloudnative-pg-postgresql_16.4.tar`
- `..._goharbor-harbor-core_v2.11.0.tar` / `..._goharbor-registry-photon_v2.11.0.tar`
- `..._goharbor-harbor-jobservice_v2.11.0.tar` / `..._goharbor-harbor-registryctl_v2.11.0.tar`

> 注意：导入后的镜像名可能是 tar 内部的旧 `k8s-library` 名，需要再 `tag` 成
> `baokuaiyun/<scheme-C>` 才能匹配 Pod spec。

## 容量注意

仅 2 个存储节点时：

- `default-replica-count` 应设为 **2**（否则 3 副本永远 `ReplicaSchedulingFailure`）。
- 每个盘默认 `storageReserved` 为 30%，50G 盘下容易触发
  `insufficient storage; precheck new replica failed`。可下调预留：

  ```bash
  kubectl -n longhorn-system patch nodes.longhorn.io k8s-worker-1 --type=merge \
    -p '{"spec":{"disks":{"<disk-name>":{"storageReserved":5368709120}}}}'
  ```

- 副本补充由 `replica-replenishment-wait-interval`（默认 600s）节流，降级后需等待重试。

## 教训清单

- 迁移引擎镜像前**必须先卸载卷**，否则消费方出现陈旧挂载 + I/O error。
- 删除旧 `EngineImage` 前确认无卷/引擎/副本引用。
- Harbor 是平台自举依赖：维护 Harbor 时优先保证 `platform-pg` 与 registry 存储健康，
  否则形成「PG↔Harbor」拉镜像死锁；用本地 tar 离线导入是最快的破环手段。
