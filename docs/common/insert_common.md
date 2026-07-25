# insert_common.sh 使用说明

## 1. 职责

写入类场景的完整框架：任务领取、安装包/Benchmark 同步、协议与 IoTDB 配置、case 矩阵遍历、启动、写入、超时、CSV 解析、监控、结果入库、归档和任务收尾。

## 2. 入口契约

在 `source` 前必须定义 `TEST_IP` 和 `TEST_TYPE`。可预定义数组：

- `PROTOCOL_LIST`，默认 `223`；
- `TS_LIST`，默认 `common aligned tempaligned tablemode`；
- `API_LIST`，默认 `SESSION_BY_TABLET`；
- `ENABLE_BENCHMARK_VERSION_CHECK`，默认 1。

框架使用固定标准路径、MySQL、Prometheus、20G 堆内存及最长 7200 秒等待。入口脚本在 `source` 后调用 `main "$@"`。

## 3. 可扩展点

- 覆盖 `insert_benchmark_case_id/backup_test_data/insert_result_row` 改变 Case 维度、归档和结果表结构。
- 定义 `modify_iotdb_config_for_case(protocol,ts,api)` 追加 case 配置。
- 定义 `insert_custom_result_row` 时替代标准入库。
- 定义 `check_custom_throughput_monitor` 时替代标准吞吐控制限。
- 下层 `append_iotdb_case_properties/init_scenario_state/after_prepare_iotdb_distribution` 仍可使用。

## 4. 自动流程

`main` 检查依赖和密码、同步 Benchmark、claim 任务，并遍历三层矩阵。每个 `test_operation` 在子 Shell 中清理进程、重建 IoTDB、应用配置和协议；启动/改密失败分别写 `-3/-4`。成功后安装 Benchmark 配置、预热 60 秒、等待 CSV、flush、采集监控；解析失败写 `-2`，否则入库并做历史吞吐 3σ 检查。最后停库、归档并汇总 `done/RError`。

## 5. 使用示例

```bash
readonly TEST_IP="11.101.17.100"
readonly TEST_TYPE="my_insert"
readonly -a TS_LIST=(common aligned)
readonly -a API_LIST=(SESSION_BY_TABLET JDBC)
source "${SCRIPT_DIR}/../common/insert_common.sh"
main "$@"
```

## 6. 副作用与验收

每个 case 会终止本机 IoTDB/Benchmark、删除并重建 `${TEST_IOTDB_PATH}`；结束后按统一 minimal 级别复制 IoTDB 配置、日志和 Benchmark 产物。Benchmark 的 logs/data 会在下一 case 前清理。验收应按数组笛卡尔积核对行数、API/类型/协议、负值、失败点和归档。

## 7. 排查

加载即报错时检查 `TEST_IP/TEST_TYPE` 是否在 source 前定义。某定制场景字段错误时确认覆盖函数是在 source 后定义还是 hook 在 source 前定义，并检查子 Shell 是否使预期变量修改无法返回父级。
