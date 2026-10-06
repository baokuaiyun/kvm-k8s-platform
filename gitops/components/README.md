# components/（共享组件，DRY）

每个组件一次定义，含 `base/` + `overlays/{drill,prod,enterprise}/`。
CI 将其打包为 OCI Artifact 推入 Harbor（`oci://harbor.../baokuaiyun/<name>`）并 cosign 签名。

## 分类与现有目录映射
| 分类 | 组件 | 现有实现（drill） |
|---|---|---|
| `infra/` | cilium, longhorn, cert-manager, kgateway, monitoring(prometheus/loki/blackbox), kyverno, sealed-secrets, velero | `kubernetes/`, `platform/monitoring/`, `platform/kyverno/`, `platform/velero/` |
| `platform/` | harbor, gitlab(+runner), casdoor | `platform/harbor`, `platform/gitlab`, `platform/casdoor` |
| `data/` | cnpg, redis, object-store(minio), crossplane | `platform/platform-data/`, `platform/gitlab/minio.yaml`, `infrastructure/crossplane/` |
| `apps/` | 平台/演示应用 | （待定） |

## 约定
- `base/`：与集群无关的清单；`overlays/<env>/`：环境差异（域名/SC/副本/镜像）。
- 组件通过**稳定接口**交互（见 implementation-matrix §3），不直接依赖彼此内部资源。
- 由 `fleet/<mode>` 的 `ResourceSet` 引用（`inputs{tenant, tag, environment}`）。

> 现阶段：drill 仍是 Makefile/helm 直接安装（见 `state-ledger.md`）；本目录随 Flux 纳管逐步填充。
