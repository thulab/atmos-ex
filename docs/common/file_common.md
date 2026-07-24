# file_common.sh 使用说明

## 1. 职责

提供目录/TsFile 统计、历史目录清理、归档目录准备和 Benchmark 产物归档。

## 2. 主要函数

- `dir_size_gb DIR`：以 GiB 输出两位小数，不存在返回 0。
- `count_tsfiles DIR [PATTERN]`：递归统计，默认 `*.tsfile`。
- `clear_expired_directories ROOT [DAYS]`：删除超过保留期的一级子目录。
- `prepare_archive_directory DIR`：安全校验后 sudo 重建目录。
- `archive_if_exists SOURCE DIR`：存在时 sudo 复制。
- `archive_benchmark_runtime BM DIR`：归档 CSV、日志和配置。
- `count_files_by_pattern/count_tsfiles_by_level`：专项文件统计。

## 3. 调用示例

```bash
size="$(dir_size_gb "${TEST_IOTDB_PATH}/data")"
files="$(count_tsfiles "${TEST_IOTDB_PATH}/data")"
prepare_archive_directory "${BACKUP_PATH}/${commit_id}"
archive_benchmark_runtime "${BM_PATH}" "${BACKUP_PATH}/${commit_id}"
```

## 4. 副作用与注意事项

`clear_expired_directories` 和 `prepare_archive_directory` 会递归删除目录；后者依赖 `path_is_safe`。层级统计函数按路径组件匹配 level，调用方应核对实际 TsFile 布局。

## 5. 排查

大小或数量为 0 时先检查目录存在性和用户权限；归档失败检查 sudo、白名单根目录和目标挂载空间。
