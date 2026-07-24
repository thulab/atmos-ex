# Weekly Test Insert 场景操作说明

## 1. 场景概览

`weeklytest_insert.sh` 在 `11.101.17.111` 执行协议 `223/224` 与 `seq_w/unseq_w/tablemode_seq_w/tablemode_unseq_w` 的写入周测，共 8 个组合，结果写入 `ex_weeklytest_insert(_T)`。

## 2. 运行前准备与启动步骤

检查 `conf/weeklytest_insert` 中四类配置、license、IoT-Benchmark 和 `11.101.17.111:9091`，完成[通用准备](common-operations.md#3-运行前步骤)后执行：

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/weeklytest_insert.sh 2>&1 | tee /data/atmos/zk_test/log_weeklytest_insert
```

## 3. 自动流程

每个组合重建 IoTDB、应用协议、运行 `INGESTION` Benchmark，最长等待 7200 秒，采集 CSV 和监控指标并入库；停止服务后将安装目录及 CSV 归档到 `/nasdata/repository/weeklytest_insert/<ts_type>/<commit_date_time>_<commit_id>_<protocol>/`。

## 4. 验收与排查

预期 8 行。对照 `223/224` 时确认协议配置确实不同；表模型与树模型配置不可混用。检查失败点、吞吐、延迟分位、错误日志、WAL 和完整归档。
