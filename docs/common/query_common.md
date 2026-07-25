# query_common.sh 使用说明

## 1. 职责

查询类场景的完整框架：领取任务、准备预置数据、逐查询启停 IoTDB、运行 Benchmark、解析不同查询标签、采集指标、入库、保存每个查询日志、恢复数据集和归档。

## 2. 入口契约

在 `source` 前必须定义 `TEST_IP/TEST_TYPE/QUERY_DATA_TYPE`。可预定义：

- `PROTOCOL_LIST`，默认 `211`；
- `QUERY_TS_LIST`，默认 `tablemode common aligned tempaligned`；
- `QUERY_CREATE_QA_USER`，默认 0；
- `QUERY_LIST` 和等长的 `QUERY_RESULT_LABELS`，默认 25 个标准查询。

多数路径、超时、密码和数据库变量支持环境覆盖。数据源为 `${DATA_PATH}/${protocol}/${ts_type}/data`。

## 3. 扩展点

`append_iotdb_case_properties` 追加配置；`before_iotdb_start` 默认清理系统缓存；`prepare_query_users` 可创建 QA 用户。场景可预定义矩阵变量，也可覆盖配置、入库、数据/日志或归档函数。

## 4. 自动流程

`main` 校验查询名与标签等长，检查依赖、同步 Benchmark、claim 任务并遍历协议。每种 ts_type 重建 IoTDB、设置协议，并把数据目录移动进实例；每个查询启动 IoTDB，失败写 `-3`，否则安装配置、运行 Benchmark、等待/解析结果，失败写 `-2`，入库并把日志保存为 `logs_<query>`。类型结束后把 data 移回原位置，再按统一 minimal 级别归档 IoTDB 配置、日志和 Benchmark 产物。最终更新 `done/RError`。

## 5. 使用示例

```bash
readonly TEST_IP="11.101.17.100"
readonly TEST_TYPE="my_query"
readonly QUERY_DATA_TYPE="sequence"
readonly -a QUERY_TS_LIST=(common)
source "${SCRIPT_DIR}/../common/query_common.sh"
main "$@"
```

## 6. 副作用与验收

数据集使用 `mv` 而非复制；异常中断时数据可能停留在 `${TEST_IOTDB_PATH}/data`，不要盲目补复制。每个查询都会启停服务并移动日志。验收按 `协议 × 类型 × 查询` 核对行数、标签、负值和数据恢复。

## 7. 排查

缺数据时先同时检查源目录与 IoTDB data。表模型配置会强制 `IoTDB_DIALECT_MODE=table`。查询标签解析失败时对照 CSV 第一列和 `QUERY_RESULT_LABELS`，尤其检查 Q4/Q9 命名的连字符变体。
