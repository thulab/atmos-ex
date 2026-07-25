# Weekly Test Query 场景操作说明

## 1. 场景概览

`weeklytest_query.sh` 在 `11.101.17.113` 上对协议 `223` 执行周测查询。数据维度为 sequence/unsequence × tree/table，传感器规模为 one/more，查询为 Q1 至 Q10 的 26 个配置，每个查询重复 2 次。数据来自 `/data/atmos/original`，结果写入 `ex_weeklytest_query(_T)`。

## 2. 运行前准备与启动步骤

检查 `conf/weeklytest_query/{one,more}/<Q*>`、license，以及 `/data/atmos/original` 下四种数据模式。完成[通用准备](common-operations.md#3-运行前步骤)后执行：

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/weeklytest_query.sh 2>&1 | tee /data/atmos/zk_test/log_weeklytest_query
```

## 3. 自动流程

脚本按数据模式复制预置数据并启动 IoTDB，对 one/more 和每个查询安装配置，连续运行两次 Benchmark，解析对应查询标签入库；每个查询后保存日志，每种数据模式后归档到 `${BACKUP_ROOT}/<scenario>/<commit_id>/<run_id>/cases/<case_id>/`。

## 4. 验收与排查

按 `4 数据模式 × 2 规模 × 26 查询 × 2 次` 核对理论结果 416 行；实际以日志中成功进入的循环为准。检查 `query_num=1/2` 成对出现、tree/table dialect、数据路径、查询标签和负值结果。
