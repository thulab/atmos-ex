# SE Insert 场景操作说明

## 1. 场景概览

`se_insert.sh` 在 `11.101.17.116` 上执行标准写入性能矩阵：协议 `223`，序列类型 `common`、`aligned`、`tempaligned`、`tablemode`，API 为 `SESSION_BY_TABLET`，共 4 个 case。结果写入 `ex_se_insert` 或 `ex_se_insert_T`。

## 2. 运行前准备

完成[通用运行前步骤](common-operations.md#3-运行前步骤)，确认 `conf/se_insert/<ts_type>_SESSION_BY_TABLET`、`conf/se_insert/license`、IoT-Benchmark 和 `11.101.17.116:9091` 指标完整。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/se_insert.sh 2>&1 | tee /data/atmos/zk_test/log_se_insert
```

## 4. 自动流程

每种序列类型均重建 IoTDB，应用协议 `223`，启动服务并修改密码；安装对应 Benchmark 配置，预热 60 秒，等待 `INGESTION` CSV，采集吞吐、延迟、文件、WAL、CPU 和磁盘指标后入库；最后归档到 `/nasdata/repository/se_insert/<ts_type>_SESSION_BY_TABLET/<commit_date_time>_<commit_id>_223/`。

## 5. 验收与排查

预期 4 行，四种 `ts_type` 各一行。表模型 case 还应确认配置使用 table dialect。`-2/-3/-4`、失败点和错误日志不为 0 均需排查后重测。
