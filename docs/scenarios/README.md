# 场景脚本操作说明索引

本文档目录与 `script/scenarios` 一一对应。首次执行任何场景前，先阅读[通用操作说明](common-operations.md)，再进入对应场景文档核对测试矩阵、专用依赖和归档规则。公共函数的调用契约参见[公共脚本说明索引](../common/README.md)。

| 场景 | 用途 | 文档 |
| --- | --- | --- |
| `api_insert.sh` | 多种 Java API 写入 | [api_insert](api_insert.md) |
| `api_insert_cts.sh` | CTS 环境 Java API 写入 | [api_insert_cts](api_insert_cts.md) |
| `cluster_insert.sh` | 三节点集群写入与查询 | [cluster_insert](cluster_insert.md) |
| `cluster_insert_2.sh` | 五节点集群写入与查询 | [cluster_insert_2](cluster_insert_2.md) |
| `compaction.sh` | 顺序、乱序和跨空间合并 | [compaction](compaction.md) |
| `config_insert.sh` | 配置参数写入性能 | [config_insert](config_insert.md) |
| `count_ts.sh` | 时间序列创建、统计和展示 | [count_ts](count_ts.md) |
| `delete_test.sh` | 删除功能、重启和合并校验 | [delete_test](delete_test.md) |
| `insert_records.sh` | `SESSION_BY_RECORDS` 写入 | [insert_records](insert_records.md) |
| `last_cache_query.sh` | 写入负载下 Last Cache 查询 | [last_cache_query](last_cache_query.md) |
| `longrun_test.sh` | 长稳写入、查询和校验 | [longrun_test](longrun_test.md) |
| `native_api_test.sh` | Native API 自动化测试 | [native_api_test](native_api_test.md) |
| `pipe_test.sh` | Linux 双端 Pipe 性能 | [pipe_test](pipe_test.md) |
| `pipe_test_win.sh` | Windows 双端 Pipe 性能 | [pipe_test_win](pipe_test_win.md) |
| `python_api.sh` | Python API 测试 | [python_api](python_api.md) |
| `restart_db.sh` | 预置数据重启恢复 | [restart_db](restart_db.md) |
| `routine_test.sh` | 常规写入与查询回归 | [routine_test](routine_test.md) |
| `se_insert.sh` | 顺序写入性能 | [se_insert](se_insert.md) |
| `se_query.sh` | 顺序数据查询性能 | [se_query](se_query.md) |
| `se_query_test.sh` | 精简顺序查询与 QA 用户 | [se_query_test](se_query_test.md) |
| `sql_coverage.sh` | SQL 覆盖率测试 | [sql_coverage](sql_coverage.md) |
| `treeview_query.sh` | 树模型查询专项 | [treeview_query](treeview_query.md) |
| `ts_performance.sh` | TsFile 工具读写性能 | [ts_performance](ts_performance.md) |
| `tsfile_api_test.sh` | Java/C++/Python TsFile API | [tsfile_api_test](tsfile_api_test.md) |
| `unse_insert.sh` | 乱序写入性能 | [unse_insert](unse_insert.md) |
| `unse_query.sh` | 乱序数据查询性能 | [unse_query](unse_query.md) |
| `weeklytest_insert.sh` | 周测写入性能 | [weeklytest_insert](weeklytest_insert.md) |
| `weeklytest_query.sh` | 周测查询性能 | [weeklytest_query](weeklytest_query.md) |
| `windows_test.sh` | Windows 写入与查询 | [windows_test](windows_test.md) |

所有脚本都要求 Bash；不要使用 `sh script/scenarios/<name>.sh`。脚本无显式命令行参数时，测试提交来自 `QA_ATM.ex_commit_history`。
