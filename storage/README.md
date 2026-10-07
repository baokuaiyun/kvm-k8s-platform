# 存储层（StorageClass / 备份目标）

本目录定义**存储契约**：所有平台 PVC 统一引用规范 StorageClass `app-storage`，
后端按环境切换（Kustomize base + 每驱动 patch），应用清单无需改动。

## 目录（Kustomize：base 契约 + 每驱动 overlay）

```
storage/
├── apply.sh                       # kubectl apply -k storage/<backend>（+ 备份凭据）
├── base/                          # 契约公共字段：name=app-storage / Retain / 可扩容 / 默认类
│   └── storageclass.yaml
├── host-zfs-iscsi/                # drill 默认：宿主 ZFS+iSCSI（democratic-csi）
│   ├── kustomization.yaml
│   ├── storageclass-patch.yaml    # provisioner=host-zfs-iscsi + secret/params
│   ├── volumesnapshotclass.yaml
│   ├── values.yaml.tmpl / deploy-csi.sh / preload-images.sh
├── longhorn/                      # 可选后端
│   ├── kustomization.yaml
│   ├── storageclass-patch.yaml
│   └── values-overlay.yaml
└── alicloud/                      # prod：云盘 ESSD
    ├── kustomization.yaml
    └── storageclass-patch.yaml
```

## 环境矩阵

| | drill（本机 KVM） | prod（阿里云 ECS） |
|---|---|---|
| `STORAGE_BACKEND` | `host-zfs-iscsi`（可选 `longhorn`）| `alicloud` |
| 后端 | 宿主 ZFS+iSCSI（democratic-csi）| 云盘 ESSD（`cloud_essd`，加密）|
| `SNAPSHOT_CLASS` | `host-zfs-iscsi` | `alicloud-disk` |
| 异地备份目标 | 宿主 MinIO（S3）| 阿里云 OSS |

## 用法

```bash
# drill（云盘模拟）
make host-storage && make csi-storage && make storage-class
# 换驱动只改 STORAGE_BACKEND（契约不变）
make storage-class STORAGE_BACKEND=longhorn
make storage-class STORAGE_BACKEND=alicloud
```

完整规划与数据分级见 `docs/storage-plan.md`、`docs/cloud-disk-data-solution.md`、`docs/application-data.md`。
