# result_common.sh 使用说明

## 1. 职责

封装 MySQL 执行、SQL 字符串转义、任务领取和状态收尾，统一 `ex_commit_history` 生命周期。

## 2. 必需变量

`MYSQL_HOST/PORT/USERNAME/PASSWORD`、`DBNAME`、`TASK_TABLENAME`、`TEST_TYPE`。领取后写入全局 `commit_id/author/commit_date_time`；可用 `TASK_AUTHOR_FILTER_SQL` 限定作者。

## 3. 主要函数

- `mysql_exec SQL`：使用 `MYSQL_PWD` 执行无表头批量查询。
- `sql_quote VALUE`：转义反斜杠和单引号。
- `fetch_next_commit`：优先最新 `retest`，否则最新 `NULL`。
- `claim_next_task`：领取后标记 `ontesting`。
- `finish_task_success/failure`：写 `done/RError`，可跳过旧提交。
- `run_task_lifecycle FUNCTION`：执行一次完整任务。
- `run_task_loop FUNCTION`：轮询任务，受 `TASK_RUN_ONCE/TASK_POLL_INTERVAL_SECONDS` 控制。

## 4. 调用示例

```bash
claim_next_task || exit 0
if run_suite; then
  finish_task_success
else
  finish_task_failure
fi
```

## 5. 副作用与排查

函数会直接更新共享任务表；它不是带锁的原子 claim，多执行器并发领取同一场景时需额外协调。所有动态字符串应经过 `sql_quote`。查不到任务时检查作者过滤、字段名、`NULL/retest` 状态及数据库时区。
