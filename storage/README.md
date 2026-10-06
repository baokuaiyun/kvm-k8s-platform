# 存储层（StorageClass / 备份目标）

本目录定义**存储契约**：所有平台 PVC 统一引用规范 StorageClass `app-storage`，
后端按环境切换，应用清单无需改动。

## 目录

```
storage/
├── apply.sh                       # 渲染并应用 SC + 备份凭据
├── longhorn/
│   ├── storageclass.yaml          # app-storage -> driver.longhorn.io（drill）
│   └── values-overlay.yaml        # Longhorn 生产化设置（副本/备份目标/控制面调度）
└── alicloud/
    └── storageclass.yaml          # app-storage -> diskplugin.csi.alibabacloud.com（prod）
```

## 环境矩阵

| | drill（本机 KVM） | prod（阿里云 ECS） |
|---|---|---|
| `STORAGE_BACKEND` | `longhorn` | `alicloud` |
| 后端 | Longhorn（2 副本） | 云盘 ESSD（`cloud_essd`，加密） |
| `SNAPSHOT_CLASS` | `longhorn` | `alicloud-disk` |
| 异地备份目标 | 宿主机 NFS | 阿里云 OSS |

## 用法

```bash
# drill
make storage            # 安装 Longhorn（自动带 values-overlay）
make storage-class      # 应用 app-storage SC
make storage-class STORAGE_BACKEND=alicloud   # 生产切云盘
```

完整规划与数据分级见 `docs/storage-plan.md`、`docs/application-data.md`。
