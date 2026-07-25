# runtime_common.sh 使用说明

## 1. 职责

公共运行时聚合入口，提供日志、错误、日期、依赖检查、安全删除、属性修改和调度状态函数，并自动加载进程、结果、文件、Git、配置、CLI 与 case 状态模块。

## 2. 使用前准备

调用方通常必须定义 `INIT_PATH`、`TEST_INIT_PATH`、`TEST_IOTDB_PATH`、`BACKUP_ROOT`、`TEST_TYPE` 及数据库变量。`check_password` 要求 `MYSQL_PASSWORD` 非空；`ensure_runtime_dependencies` 会检查完整命令集。

## 3. 主要函数

- `log`、`die`：带时间日志和立即退出。
- `run_isolated_case`：在子 Shell 中执行函数，隔离变量、环境和工作目录改变。
- `trim/current_datetime/datetime_to_epoch/normalize_datetime`：字符串和时间处理。
- `safe_rm/sudo_safe_rm/path_is_safe`：仅允许在已知根目录下递归删除。
- `copy_if_exists`：源不存在时记录并跳过。
- `set_iotdb_property [FILE] KEY VALUE`：去重更新 properties。
- `mark_test_in_progress/restore_test_type_file`：维护 `test_type_file`。

## 4. 调用示例

```bash
source "${SCRIPT_DIR}/../common/runtime_common.sh"
ensure_runtime_dependencies
check_password
trap restore_test_type_file EXIT
mark_test_in_progress
set_iotdb_property enable_seq_space_compaction false
```

## 5. 副作用与排查

`safe_rm` 和 `sudo_safe_rm` 是破坏性操作；路径不在白名单时会终止。`set_iotdb_property` 会重写目标文件并合并重复键。缺少命令、密码、配置文件或安全路径失败时先检查调用方变量是否在 `source` 前正确设置。
