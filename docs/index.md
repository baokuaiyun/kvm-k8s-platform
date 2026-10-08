# KVM 生产集群项目

基于 **KVM + kubeadm** 的可复现生产级 Kubernetes 集群，支持三模式多租户。

## 快速开始

```bash
make help          # 查看所有目标
make init          # 初始化 KVM 环境
make phase1        # 阶段1: 基础集群创建
make phase2        # 阶段2: 安全/身份/可观测（GitOps）
make phase3        # 阶段3: 应用部署 + GitOps
make phase4        # 阶段4: 持续升级维护
make verify        # 全量验收
make rebuild       # 删除→重建→平台可用（保留宿主存储）
```

## 文档导航

- [本机 KVM 四阶段实施手册](implementation-playbook.md)
- [网络架构与 LB 设计](network-architecture.md)
- [网络验证（工具/教程）](network-verification.md)
- [服务/业务 IP 设计（固定入口 + 按需池）](service-ip-design.md)
- [计算架构（节点规格/节点池/调度/弹性/异构）](compute-architecture.md)
- [计算验证（工具/教程）](compute-verification.md)
- [本机 vs 阿里云环境差异](environment-differences.md)
- [阿里云生产部署（多 ECS + CCM/SLB）](alicloud-deployment.md)
- [域名/证书/镜像迁移](baokuaiyun-domain-migration.md)
- [三模式多租户隔离架构](tenant-isolation-architecture.md)
- [存储规划（StorageClass/PV/云盘）](storage-plan.md)
- [存储验证（工具/教程）](storage-verification.md)
- [云盘数据解决方案（ZFS+iSCSI 云盘/计算分离）](cloud-disk-data-solution.md)
- [验收与证据（Proof）](evidence-and-acceptance.md)
- [应用数据说明与备份规划](application-data.md)
- [数据分级与 RPO/RTO](data-classification.md)
- [凭据管理](secret-management.md)
- [Makefile 设计](makefile-design.md)
- [镜像管理](image-management.md)

## 环境切换

```bash
# 本机演练（单节点起步；宿主 ZFS+iSCSI 云盘模拟 + 宿主 MinIO）
make host-storage
make phase1 DOMAIN=test.baokuaiyun.com

# 阿里云生产（云盘 ESSD + OSS 异地备份；改 variables.mk 或环境变量覆盖）
make phase1 DOMAIN=baokuaiyun.com STORAGE_BACKEND=alicloud SNAPSHOT_CLASS=alicloud-disk
```
