# API Insert CTS 场景操作说明

## 1. 场景概览

`api_insert_cts.sh` 在 `11.101.17.143` 上测试 `tempaligned` 的 `SESSION_BY_TABLET`、`SESSION_BY_RECORDS`、`SESSION_BY_RECORD` 和 `JDBC` 写入。默认协议 `223`，共 4 个 case，结果写入 `ex_api_insert_cts` 或其 `_T` 表。

## 2. 运行前准备

完成[通用运行前步骤](common-operations.md#3-运行前步骤)，检查 `conf/api_insert_cts/tempaligned_<API>`、`conf/api_insert_cts/license`、IoT-Benchmark 及 `11.101.17.143:9091` 指标。该场景没有 `SESSION_BY_TABLET_TABLE`，验收时不要按 5 行计算。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/api_insert_cts.sh 2>&1 | tee /data/atmos/zk_test/log_api_insert_cts
```

## 4. 自动流程

脚本按 API 逐项重建 IoTDB，设置协议和指标，运行写入 Benchmark，最长等待 7200 秒，解析 `INGESTION` CSV，采集资源指标并入库；随后停止进程，将安装目录和 CSV 归档到 `/nasdata/repository/api_insert_cts/tempaligned_<API>/<commit_date_time>_<commit_id>_223/`。

## 5. 验收与排查

预期 4 行结果和 4 个归档目录。检查接口集合完整、`failPoint=0`、吞吐为正、错误日志大小为 0，并排除 `-2/-3/-4`。重测前保留 CTS 专用配置和旧 CSV。
