variable "kubeconfig_path" {
  description = "集群 kubeconfig 路径"
  type        = string
  default     = "~/.kube/config"
}

variable "cluster_name" {
  description = "集群目录名（对应 gitops/clusters/<name>）"
  type        = string
  default     = "all-in-one"
}

variable "cluster_region" {
  description = "集群区域（写入 flux-runtime-info，由 Terraform SSA 追加）"
  type        = string
  default     = "local"
}

variable "bootstrap_revision" {
  description = "引导运行版本（bump 触发重新 bootstrap）"
  type        = number
  default     = 1
}

# Harbor（OCI 制品源）拉取凭据 —— 用于创建 harbor-auth dockerconfigjson
variable "harbor_host" {
  type    = string
  default = "harbor.test.baokuaiyun.com"
}

variable "harbor_robot_user" {
  type    = string
  default = "robot$baokuaiyun+pushpull"
}

variable "harbor_robot_pass" {
  type      = string
  sensitive = true
  default   = ""
}

# key-based cosign 公钥（校验 Flux 拉取的制品）
variable "cosign_pub_path" {
  type    = string
  default = ""
}
