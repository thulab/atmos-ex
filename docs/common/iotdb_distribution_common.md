# iotdb_distribution_common.sh 使用说明

## 1. 职责

从提交仓库准备一个全新的待测 IoTDB 安装目录，并复制场景许可证和可选 `.env`。

## 2. 调用契约

必须定义 `REPOS_PATH/commit_id/TEST_IOTDB_PATH/ATMOS_PATH/TEST_TYPE`。依赖 `safe_rm/die/copy_if_exists`。`COPY_IOTDB_ENV=1` 时复制 `conf/<scene>/env`。

## 3. 主要函数

- `prepare_iotdb_distribution`：从 `${REPOS_PATH}/${commit_id}/apache-iotdb` 复制安装包。
- `set_env`：当前只是上述函数的语义别名。

安装后若存在 `after_prepare_iotdb_distribution` hook，会自动调用。

## 4. 调用示例

```bash
after_prepare_iotdb_distribution() {
  cp custom.jar "${TEST_IOTDB_PATH}/ext/"
}
set_env
```

## 5. 副作用与排查

函数会安全删除整个 `TEST_IOTDB_PATH` 后重建；源包缺失会终止。许可证缺失只记录并跳过，可能导致后续启动失败。hook 返回失败会传递给调用方。
