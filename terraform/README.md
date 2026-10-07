# Terraform（基础设施平面引导）

按 D2 架构，**Terraform 只负责"把 Flux 引导进集群"**（安装 Flux Operator、创建 FluxInstance、
拉取密钥、runtime-info），**不管理 k8s/应用**（分别归 kubeadm 与 Flux）。

## 结构

```
terraform/
└── envs/drill/
    ├── versions.tf      # provider 版本（kubernetes/helm ~>3.0）
    ├── providers.tf     # 读取 ~/.kube/config
    ├── variables.tf     # cluster_name/region、Harbor 凭据、cosign 公钥
    ├── main.tf          # module flux-operator-bootstrap（官方）
    └── outputs.tf
```

- 复用官方模块 `controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes`：
  读取 `gitops/clusters/<cluster>/flux-system/flux-instance.yaml` 与 `platform/flux/values.yaml`，
  创建 `harbor-auth`（dockerconfigjson）、用 SSA 给 `flux-runtime-info` 追加 `CLUSTER_REGION`。
- FluxInstance 的 `sync.path = clusters/<cluster>`；`tenants/*` 用 `${ARTIFACT_TAG}`/`${ENVIRONMENT}`（postBuild 注入）。

## 用法

```bash
terraform -chdir=terraform/envs/drill init
terraform -chdir=terraform/envs/drill validate
# 需集群就绪 + Harbor 可达（Flux Operator 镜像/制品来自 Harbor）
terraform -chdir=terraform/envs/drill apply \
  -var harbor_robot_pass="$HARBOR_ROBOT_PASS" \
  -var cluster_name="all-in-one" -var cluster_region="local"
```

Makefile 封装：`make tf-init` / `tf-validate` / `tf-plan` / `tf-apply` / `tf-fmt`（`TF_ENV=drill`）。

## 边界

| 层 | 工具 |
|---|---|
| 基础设施（云资源/引导 Flux）| **Terraform**（本目录）|
| 集群（kubeadm/kube-vip/CNI/CSI）| Makefile + 脚本 |
| 应用/组件（Harbor/GitLab/可观测…）| Flux（OCI 制品 + cosign）|

> prod 可另加 alicloud provider 管 VPC/ECS/OSS/RAM/DNS（扩展，不在 drill 范围）。
