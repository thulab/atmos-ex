# case_state_common.sh 使用说明

## 1. 职责

集中重置单个 Benchmark case 的全局状态，避免上一 case 的指标和时间泄漏到下一 case。

## 2. 主要函数

- `init_benchmark_metrics`：重置成功/失败点、吞吐和全部延迟分位。
- `init_monitor_metrics`：重置文件、WAL、线程、CPU 和磁盘指标。
- `init_case_timestamps`：重置开始、结束、耗时和监控 epoch。
- `init_case_state`：依次调用上述函数，再调用可选 `init_scenario_state` hook。

## 3. 调用示例

```bash
init_scenario_state() {
  custom_metric=0
}
source "${SCRIPT_DIR}/../common/runtime_common.sh"
init_case_state
```

## 4. 注意事项

函数直接创建或修改全局变量，不返回对象；因此 case 最好在 `run_isolated_case` 子 Shell 中执行。新增标准指标时需要同步修改初始化逻辑，否则会出现脏值。

## 5. 排查

结果沿用上一轮时，确认每个 case 开头调用了 `init_case_state/init_items`，以及自定义字段是否由 `init_scenario_state` 重置。
