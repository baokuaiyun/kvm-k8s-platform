# 基础设施平面：用 Terraform 引导 Flux（对齐 D2）。
# 只做"把 Flux Operator + FluxInstance + 拉取密钥 + runtime-info 装进集群"，
# 不管理 k8s/应用（那些分别归 kubeadm 与 Flux）。集群需已存在（drill=kubeadm 建的 cp-1）。
provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes = {
    config_path = var.kubeconfig_path
  }
}
