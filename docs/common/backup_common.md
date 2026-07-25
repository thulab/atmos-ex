# backup_common.sh 使用说明

## 1. 职责

为全部测试场景提供统一归档目录、case 标识、原子提交、产物清单、远端节点归档和分级归档能力。

统一目录为：

```text
${BACKUP_ROOT}/<scenario>/<commit_id>/<run_id>/cases/<case_id>/
```

归档先写入 `<case_id>.partial`，完成后原子重命名。已有 case 不会被覆盖。

## 2. 归档级别

- `minimal`：IoTDB 配置和日志、Benchmark 配置、日志与 CSV。
- `diagnostic`：在 minimal 基础上增加 activation 和工具日志。
- `full`：归档完整 IoTDB 目录；适用于 compaction 等依赖数据现场的场景。

通过 `BACKUP_LEVEL` 设置，默认 `minimal`。

## 3. 主要函数

- `backup_build_case_id KEY VALUE ...`：生成稳定的 `key=value__key=value` 标识。
- `backup_begin_run`：初始化运行目录和运行清单。
- `backup_begin_case CASE_ID`：创建 case 临时目录。
- `backup_add TYPE SOURCE [NAME] [required|optional] [copy|move]`：归档单项产物。
- `backup_add_iotdb_runtime [PATH]`：按级别归档 IoTDB。
- `backup_add_benchmark_runtime [PATH] [LABEL]`：归档 Benchmark。
- `backup_add_remote HOST SOURCE [NAME] [required|optional]`：归档远端节点产物。
- `backup_write_metadata KEY VALUE`：写入 case 元数据。
- `backup_finish_case STATUS`：写清单并原子提交 case。
- `backup_finish_run STATUS`：更新运行清单。

## 4. 示例

```bash
case_id="$(backup_build_case_id protocol 223 model aligned api SESSION_BY_TABLET)"
backup_begin_case "${case_id}"
backup_add_iotdb_runtime
backup_add_benchmark_runtime
backup_finish_case success
```

场景只负责声明归档内容，不得自行拼接 `${BACKUP_ROOT}`、覆盖既有归档或直接删除归档目录。
