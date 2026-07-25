# API Insert 场景操作说明

## 1. 场景概览

`api_insert.sh` 在专用机 `11.101.17.225` 上使用 IoT-Benchmark 测试 `tempaligned` 数据的五种写入接口：`SESSION_BY_TABLET_TABLE`、`SESSION_BY_TABLET`、`SESSION_BY_RECORDS`、`SESSION_BY_RECORD`、`JDBC`。默认协议为 `223`，共执行 5 个 case，结果写入 `ex_api_insert` 或 `ex_api_insert_T`。

> 脚本复用 `insert_common.sh`，每个 case 都会清理进程和 `/data/atmos/apache-iotdb`，并按统一 minimal 级别归档配置、日志和 Benchmark 产物。

## 2. 运行前准备

1. 完成[通用运行前步骤](common-operations.md#3-运行前步骤)，确认主机 IP 为 `11.101.17.225`。
2. 检查五个配置：`conf/api_insert/tempaligned_<API>`。
3. 检查 `conf/api_insert/iotdb/activation/license`、`conf/api_insert/benchmark/cases/`、待测安装包和 `/nasdata/repository/iot-benchmark`。
4. 确认结果表、任务表及 Prometheus 的 `11.101.17.225:9091` target 可用。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/api_insert.sh 2>&1 | tee /data/atmos/zk_test/log_api_insert
```

## 4. 自动流程

1. 领取任务并同步 IoT-Benchmark。
2. 对每个 API 复制全新 IoTDB，应用协议 `223`、指标和 Benchmark 配置。
3. 启动 IoTDB、修改 root 密码、启动 Benchmark，预热 60 秒并等待 CSV，最长 7200 秒。
4. 执行 `flush`，解析 `INGESTION` 的吞吐与延迟，采集进程和 Prometheus 指标并入库。
5. 停止进程，将结果归档到 `${BACKUP_ROOT}/<scenario>/<commit_id>/<run_id>/cases/<case_id>/`。

## 5. 验收与排查

预期 5 行结果，五种 `api_type` 各一行；检查 `failPoint=0`、吞吐为正、无 `-2/-3/-4` 哨兵值且五个归档存在。缺配置、启动失败、CSV 缺失和监控为 0 的处理参见[通用失败与重测](common-operations.md#8-失败与重测)。
