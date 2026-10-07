# KVM 生产集群项目

基于 KVM + kubeadm 的可复现生产级 Kubernetes 集群，支持三模式多租户。

## 快速开始

```bash
make help          # 查看所有目标
make init          # 初始化 KVM 环境
make host-storage  # 宿主 ZFS+iSCSI+MinIO（云盘/对象层，幂等）
make phase1        # 阶段1: 基础集群创建（单节点起步）
make phase2        # 阶段2: 安全及运营监控
make phase3        # 阶段3: 应用部署 + GitOps
make phase4        # 阶段4: 持续升级维护
make verify        # 全量验收
make rebuild       # 删除→重建→平台可用（保留宿主存储）
```

## 目录结构

```
├── Makefile              # 顶层入口
├── variables.mk          # 全局变量（环境差异集中管理）
├── kvm/                  # KVM 虚拟机管理
├── kubernetes/           # kubeadm 集群安装
├── infrastructure/       # 安全/租户/crossplane
├── platform/             # Harbor/GitLab/Backstage
├── registry/             # 镜像清单 + 推 Harbor
├── observability/        # 监控/日志/告警
├── scripts/              # 备份/恢复等运维脚本
├── storage/              # Longhorn 等存储
├── docs/                 # 完整文档
├── backups/              # 备份目标
└── patches/              # 补丁
```

## 文档

- `docs/implementation-playbook.md` — 本机 KVM 四阶段实施手册
- `docs/network-architecture.md` — 网络架构与 LB 设计（分层/路径/三环境差异）
- `docs/network-verification.md` — 网络验证工具与教程（`make verify-network`）
- `docs/environment-differences.md` — 本机 vs 阿里云环境差异
- `docs/alicloud-deployment.md` — 阿里云生产部署（多 ECS + CCM/SLB）
- `docs/baokuaiyun-domain-migration.md` — 域名/证书/镜像迁移
- `docs/tenant-isolation-architecture.md` — 三模式多租户
- `docs/storage-plan.md` — 存储规划（StorageClass/PV/云盘）
- `docs/cloud-disk-data-solution.md` — 云盘数据解决方案（ZFS+iSCSI 云盘/计算分离）
- `docs/alert-notification.md` — 告警通知配置（企微/钉钉/Slack/邮件/webhook，参数导入）
- `docs/application-data.md` — 应用数据说明与备份规划
- `docs/data-classification.md` — 数据分级与 RPO/RTO
- `docs/secret-management.md` — 凭据管理
- `docs/makefile-design.md` — Makefile 设计
- `docs/image-management.md` — 镜像管理

### 本地预览 / 构建文档

> 基于 MkDocs Material（配置见 `mkdocs.yml`），通过 Docker 运行，无需本地装 Python。

```bash
make docs        # 启动预览服务：http://<本机IP>:8000（实时热更新，Ctrl-C 停止）
make docs-build  # 构建静态站点到 site/
make docs-down   # 停止预览容器
```

- 端口可覆盖：`make docs DOCS_PORT=8001`
- 镜像可覆盖：`make docs DOCS_IMAGE=<镜像>`
- `docs/` 为文档源（`docs_dir`），新增文档后在 `mkdocs.yml` 的 `nav` 注册即出现在导航。

## 环境切换

```bash
# 本机演练
make phase1 DOMAIN=test.baokuaiyun.com

# 阿里云生产（改 variables.mk 或环境变量覆盖）
make phase1 DOMAIN=baokuaiyun.com STORAGE_CLASS=alicloud-disk
```
