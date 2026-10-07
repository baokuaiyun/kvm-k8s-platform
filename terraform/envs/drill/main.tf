locals {
  # Harbor 拉取密钥（dockerconfigjson）
  harbor_auth = jsonencode({
    auths = {
      (var.harbor_host) = {
        username = var.harbor_robot_user
        password = var.harbor_robot_pass
        auth     = base64encode("${var.harbor_robot_user}:${var.harbor_robot_pass}")
      }
    }
  })

  cluster_dir = "${path.root}/../../../gitops/clusters/${var.cluster_name}"
}

# 官方引导模块：安装 Flux Operator（Helm）、创建 FluxInstance、拉取密钥、runtime-info
module "flux_operator_bootstrap" {
  source   = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"
  revision = var.bootstrap_revision

  gitops_resources = {
    instance_yaml = file("${local.cluster_dir}/flux-system/flux-instance.yaml")
    operator_chart = {
      values_yaml = file("${path.root}/../../../platform/flux/values.yaml")
    }
  }

  managed_resources = {
    secrets_yaml = <<-YAML
      apiVersion: v1
      kind: Secret
      metadata:
        name: harbor-auth
      type: kubernetes.io/dockerconfigjson
      stringData:
        .dockerconfigjson: '${replace(local.harbor_auth, "'", "''")}'
    YAML
    runtime_info = {
      data = {
        CLUSTER_REGION = var.cluster_region
      }
    }
  }
}
