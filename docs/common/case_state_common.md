# case_state_common.sh 使用说明

## 1. 职责

提供所有场景唯一的 `init_items` 入口，按公共状态、工作负载状态、场景状态三层初始化单个 Case，避免上一 Case 的指标泄漏。

## 2. 初始化层级

1. `init_case_state` 重置标准 Benchmark 指标、监控指标和 Case 时间。
2. 若存在 `init_workload_state`，初始化 Insert、Query 等公共工作负载字段。
3. 若存在 `init_scenario_state`，初始化具体场景的专属字段。

场景脚本不得重新定义 `init_items`。

## 3. 主要函数

- `init_benchmark_metrics`：重置成功/失败点、吞吐和延迟分位。
- `init_monitor_metrics`：重置文件、WAL、线程、CPU 和磁盘指标。
- `init_case_timestamps`：重置 Case 开始、结束、耗时和监控 epoch。
- `init_case_state`：只初始化公共 Case 状态，不调用 Hook。
- `init_items`：唯一公共入口，依次执行公共初始化和两个可选 Hook。

## 4. 扩展示例

工作负载公共脚本可以定义：

```bash
init_workload_state() {
    disk_id_regex="^${DEFAULT_DISK_ID}$"
}
```

场景脚本可以定义：

```bash
init_scenario_state() {
    custom_metric=0
    current_model=""
}
```

执行 Case 时统一调用：

```bash
init_items
```

## 5. 生命周期约束

- Run 级字段不在 Hook 中重置，例如 `commit_id`、`commit_date_time`、`test_date_time` 和结果表名。
- Case 级字段由 `init_items` 及 Hook 重置。
- Step 级临时值优先声明为函数 `local`，确需共享时使用专用步骤初始化函数。
- Hook 只修改变量，不执行文件、进程、网络或数据库操作。
- Case 最好通过 `run_isolated_case` 在子 Shell 中执行。
