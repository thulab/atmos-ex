# file_common.sh 使用说明

## 1. 职责

提供目录、TsFile 和通用文件统计。运行产物归档统一由 `backup_common.sh` 负责。

## 2. 主要函数

- `dir_size_gb DIR`：以 GiB 输出两位小数，不存在返回 0。
- `count_tsfiles DIR [PATTERN]`：递归统计，默认 `*.tsfile`。
- `clear_expired_directories ROOT [DAYS]`：删除超过保留期的一级子目录。
- `count_files_by_pattern/count_tsfiles_by_level`：专项文件统计。

## 3. 调用示例

```bash
size="$(dir_size_gb "${TEST_IOTDB_PATH}/data")"
files="$(count_tsfiles "${TEST_IOTDB_PATH}/data")"
count_tsfiles_by_level "${TEST_IOTDB_PATH}/data" "0"
```

## 4. 副作用与注意事项

`clear_expired_directories` 会递归删除超过保留期的目录。层级统计函数按路径组件匹配 level，调用方应核对实际 TsFile 布局。

## 5. 排查

大小或数量为 0 时先检查目录存在性和用户权限。归档问题参见 `backup_common.md`。
