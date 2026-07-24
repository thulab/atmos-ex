# TS Performance 场景操作说明

## 1. 场景概览

`ts_performance.sh` 在 `11.101.17.115` 上测试协议 `223`，类型 `common/aligned/tempaligned/tablemode`，数据方向 `sequence/unsequence`，共 8 个 TsFile 工具性能组合。结果写入 `ex_ts_performance(_T)`。

## 2. 运行前准备

完成[通用准备](common-operations.md#3-运行前步骤)，检查 `/data/atmos/DataSet/<sequence|unsequence>/<ts_type>` 的 TsFile 数据、`conf/ts_performance/metadata/dump_test_g_0.sql`、license 和待测包内 `tools`。确认数据盘和归档盘能容纳工具转换前后文件。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/ts_performance.sh 2>&1 | tee /data/atmos/zk_test/log_ts_performance
```

## 4. 自动流程

每个组合重建 IoTDB并应用协议/配置，定位对应源 TsFile，调用发行包工具执行数据或元数据相关操作，记录处理前后文件数量/大小、耗时、失败标志和资源指标；每轮工具日志改名保存，最终归档到 `/nasdata/repository/ts_performance/<ts_type>/<commit_date_time>_<commit_id>_223/`。

## 5. 验收与排查

预期 8 行并覆盖两种数据方向。核对工具退出状态、处理前后统计和日志，而非只看耗时；tablemode 数据结构、metadata SQL、源路径缺失或版本工具参数变化是主要失败点。
