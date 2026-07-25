# Cluster Insert 场景操作说明

## 1. 场景概览

`cluster_insert.sh` 由控制机 `11.101.17.130` 编排 `11.101.17.131-133` 三节点集群，节点同时承担 ConfigNode/DataNode，Benchmark 位于 `11.101.17.131`。结果写入 `ex_cluster_insert(_T)`，查询结果写入 `ex_cluster_insert_query(_T)`。

实际 main 执行 common、aligned、tablemode 的顺序/乱序写入及部分读写混合，协议以 `223` 为主，并包含 aligned 的 `222` 对照；脚本中 template/tempaligned 多数调用已注释，不能按数组声明推断实际 case 数。

> 脚本通过 SSH 清理三台节点的安装目录、数据和进程并重新部署集群，只能在该专用集群运行。

## 2. 运行前准备

1. 完成[通用运行前步骤](common-operations.md#3-运行前步骤)，在控制机验证到三节点的 root 免密 SSH/SCP。
2. 检查 `/data/atmos/zk_test/first-rest-test/{CN,DN}/apache-iotdb` 的临时空间和三节点 `10710/6667/9081/9091` 端口。
3. 检查 `conf/cluster_insert` 下实际调用组合、license 以及远端 Benchmark。
4. 确认三副本资源足够，三节点时钟同步，Prometheus 能按节点采集。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/cluster_insert.sh 2>&1 | tee /data/atmos/zk_test/log_cluster_insert
```

## 4. 自动流程

脚本领取任务、同步 Benchmark，向三台主机分发 CN/DN 包并写入种子节点、三副本、协议和指标配置，启动集群并创建 QA 用户；逐个实际 case 在远端运行 Benchmark，解析写入及查询 CSV，按节点采集指标并写入两类结果表，最后归档至 `${BACKUP_ROOT}/<scenario>/<commit_id>/<run_id>/cases/<case_id>/`。

## 5. 验收与排查

验收以日志中的实际 `test_operation` 调用为准，逐项核对写入表和查询表；执行 `show cluster` 确认 3 CN/3 DN 正常。节点缺失、远端 CSV 缺失、三副本无法建区或 SSH 清理失败均应标记重测，不要仅凭任务 `done` 判定成功。
