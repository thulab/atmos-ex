# benchmark_common.sh 使用说明

## 1. 职责

管理 IoT-Benchmark 运行目录、版本同步、后台启动、CSV 等待、超时占位、标准结果解析和完整生命周期。

## 2. 调用契约

至少定义 `BM_PATH`；同步需要 `BM_REPOS_PATH`，监控可使用 `MONITOR_TIMEOUT_SECONDS/MONITOR_POLL_INTERVAL_SECONDS/BENCHMARK_WARMUP_SECONDS`。依赖运行时、配置、Git、进程和监控函数。解析函数写入全局 Benchmark 指标。

## 3. 主要函数

- `prepare_benchmark_runtime [PATH]/start_benchmark [PATH]`：删除指定 Benchmark 的旧 `logs/data` 后后台运行 `benchmark.sh`；未传路径时使用 `BM_PATH`。
- `find_result_csv [DIR]`：返回第一个 `*result.csv`。
- `wait_for_benchmark_output_dirs TIMEOUT INTERVAL START DIR...`：等待多个 Benchmark 输出目录全部生成。
- `log_benchmark_parse_diagnostics PATH CSV LABEL`：记录 CSV 候选文件、大小和标签匹配详情。
- `sync_benchmark_distribution [SOURCE] [TARGET]`：按 `git.properties` 版本覆盖运行目录。
- `wait_for_benchmark_result [TIMEOUT] [INTERVAL] [CALLBACK] [START]`：等待 CSV并更新 `BENCHMARK_RESULT_CSV/end_time`。
- `create_benchmark_stuck_result_csv CSV ROWS LABEL...`：按标签和行数生成通用失败占位 CSV。
- `create_standard_stuck_result_csv/set_standard_negative_benchmark_metrics/parse_standard_benchmark_result`：标准失败和解析工具。

## 4. 调用示例

```bash
check_standard_benchmark_version
start_benchmark
m_start_time="$(date +%s)"
wait_for_benchmark_result 7200 10 create_standard_stuck_result_csv "${m_start_time}"
parse_standard_benchmark_result "${BENCHMARK_RESULT_CSV}" INGESTION
```

## 5. 副作用与排查

启动前会递归删除 Benchmark 的 `logs/data`；版本不同时会删除并整体复制目标 Benchmark。CSV 多于一个时只取 shell 排序的第一个，调用方应确保目录干净。超时 callback 生成的占位 CSV 不等于测试成功，返回码仍为 1。
