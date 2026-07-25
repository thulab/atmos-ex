# Cluster Insert 2 场景操作说明

## 1. 场景概览

`cluster_insert_2.sh` 复用集群框架，由控制机 `11.101.17.210` 编排 `11.101.17.211-215` 五台节点，Benchmark 位于 `.211`。结果表为 `ex_cluster_insert_2(_T)` 和 `ex_cluster_insert_2_query(_T)`，集群名为 `Apache-IoTDB-2`。

实际执行 common、aligned、tablemode 的写入/读写组合，主要协议 `223`，aligned 增加 `224` 对照。脚本允许清理远端 `/data/datanode`、`/data1/datanode`、`/ssd/datanode`，风险高于普通场景。

## 2. 运行前准备

在完成[通用准备](common-operations.md#3-运行前步骤)后，逐台验证 `.211-.215` SSH、sudo、磁盘挂载和目录归属；确认 `.210` 控制机、`.211` Benchmark、五节点端口及 Prometheus target 正常，并检查 `conf/cluster_insert_2`。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/cluster_insert_2.sh 2>&1 | tee /data/atmos/zk_test/log_cluster_insert_2
```

## 4. 自动流程与验收

脚本分发安装包、构建五节点集群、运行各实际写入 case，并解析写入和查询结果入库，归档到 `${BACKUP_ROOT}/<scenario>/<commit_id>/<run_id>/cases/<case_id>/`。验收须同时检查五节点 `show cluster`、`223/224` 协议 case、两类结果表、远端 CSV 和归档；特别确认允许清理的三个数据根目录未指向非测试数据。
