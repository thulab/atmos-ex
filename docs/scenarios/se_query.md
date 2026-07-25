# SE Query 场景操作说明

## 1. 场景概览

`se_query.sh` 在 `11.101.17.152` 上测试 sequence 数据。协议 `211`，类型为 `tablemode/common/aligned/tempaligned`，每种执行 Q1、Q2-1 至 Q10 共 25 个查询，总计 100 个 case。结果写入 `ex_se_query` 或 `_T` 表。

## 2. 运行前准备

完成[通用运行前步骤](common-operations.md#3-运行前步骤)，确认 `conf/se_query/<ts_type>/<Q*>` 共四套配置，以及 `/data/atmos/DataSet/211/<ts_type>/data`。脚本会把数据目录从数据集仓库移动到 IoTDB，异常中断可能需要人工移回。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/se_query.sh 2>&1 | tee /data/atmos/zk_test/log_se_query
```

## 4. 自动流程

每种类型先重建 IoTDB并移入预置数据；随后每个查询均启动 IoTDB、运行 Benchmark、解析对应结果标签、采集指标、入库、保存为 `logs_<Q>` 并停库。全部查询后把 `data` 移回数据集目录，再归档 IoTDB 和 CSV 到 `${BACKUP_ROOT}/<scenario>/<commit_id>/<run_id>/cases/<case_id>/`。

## 5. 验收与排查

预期 100 行，按 `ts_type × query_type` 核对；Q2/Q3/Q4/Q6/Q7/Q9 的子项不可遗漏。若数据集目录突然为空，先检查 `/data/atmos/apache-iotdb/data`，不要重新复制一份造成重复数据。
