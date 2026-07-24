# process_common.sh 使用说明

## 1. 职责

按 Java 主类查找和清理进程，提供通用轮询，并统计 IoTDB 的最大打开文件数与线程数。

## 2. 主要函数

- `process_pids_by_name NAME`：用 `jps` 精确匹配第二列。
- `terminate_pids DESC PID...`：先 TERM，默认 2 秒后对仍存活进程 KILL。
- `check_benchmark_pid/check_iotdb_pid/cleanup_processes`：清理 Benchmark 与 IoTDB。
- `wait_until TIMEOUT INTERVAL COMMAND...`：按秒超时轮询。
- `wait_for_attempts COUNT INTERVAL COMMAND...`：按次数轮询。
- `refresh_max_process_metrics`：更新全局 `maxNumofOpenFiles/maxNumofThread`。

## 3. 调用示例

```bash
cleanup_processes
wait_for_attempts 10 5 iotdb_is_ready
refresh_max_process_metrics
```

## 4. 副作用与注意事项

清理函数会终止本机所有主类名为 `App/DataNode/ConfigNode/IoTDB` 的进程，不区分安装目录。只能在专用测试机调用。指标依赖 `jps/lsof/ps`；权限不足会导致统计偏低。

## 5. 排查

未找到进程时确认 `jps` 属于正确 JDK；误杀风险应通过隔离主机消除，不能依赖 PID 文件规避。轮询命令必须以退出码表达状态，不能仅输出文本。
