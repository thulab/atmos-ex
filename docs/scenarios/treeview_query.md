# Treeview Query 场景操作说明

## 1. 场景概览

`treeview_query.sh` 在默认 `11.101.17.155` 上运行协议 `211` 的树视图查询专项。默认数据套件为 `seq_common/seq_aligned/unseq_common/unseq_aligned`，每套执行 25 个标准查询，默认重复 1 次，共 100 个 case。结果写入 `ex_treeview_query(_T)`。

脚本支持 `TREEVIEW_*` 覆盖测试机、路径、超时（默认 21600 秒）、套件、sensor 类型和重复次数。

## 2. 运行前准备

检查 `conf/treeview_query/query/{seq,unseq}/<Q*>`、license，以及 `/nasdata/se_query/DataSet`、`/nasdata/unse_query/DataSet`。确认覆盖后的数据库名、树前缀 `root.test.g_0`、表名及数据集布局一致，Prometheus target 为实际测试机。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/treeview_query.sh 2>&1 | tee /data/atmos/zk_test/log_treeview_query
```

## 4. 自动流程

脚本校验覆盖参数并同步 Benchmark；对每个套件重建 IoTDB、复制对应顺序/乱序数据，逐查询启停服务并运行 Benchmark，解析标签、入库和归档 `logs_<Q>`。套件完成后把 IoTDB、CSV 和配置归档到 `/nasdata/repository/treeview_query/<protocol>/<suite>/...`。

## 5. 验收与排查

默认预期 100 行；若设置 sensor 列表或重复次数，按 `4 × 25 × sensor数量 × repeat` 计算。检查 `query_suite_type`、sensor、query_num、数据源方向及 `-2/-3`，并记录全部 `TREEVIEW_*` 环境值以便复现。
