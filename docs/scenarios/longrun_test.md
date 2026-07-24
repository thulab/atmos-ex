# Longrun Test 场景操作说明

## 1. 场景概览

`longrun_test.sh` 是长稳场景，默认测试机 `11.101.17.112`、协议 `223`。它维护长期运行的写入 Benchmark，周期执行查询、TTL/删除/统计及数据一致性检查，并采集资源、文件、WAL、合并和错误信息。结果写入 `ex_longrun_test(_T)`。

脚本按作者和本机 IP 路由任务，Timecho 任务固定到 `.112`；大量时长、数据规模和路径可由 `LONGRUN_*` 环境变量影响，运行记录必须保存环境快照。

## 2. 运行前准备

1. 完成[通用准备](common-operations.md#3-运行前步骤)，确认测试机至少能承受完整长稳周期的 CPU、内存和磁盘增长。
2. 检查 `conf/longrun_test/{aligned,aligned_query,tablemode,tablemode_query,env,license}`。
3. 确认 IoT-Benchmark、Prometheus、NTP、归档盘和告警/日志轮转正常。
4. 核对所有 `LONGRUN_*` 覆盖值，尤其运行时长、轮询间隔、TTL、目标数据量和测试 IP。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/longrun_test.sh 2>&1 | tee /data/atmos/zk_test/log_longrun_test
```

## 4. 自动流程

脚本领取匹配作者的任务，重建并配置 IoTDB，启动 aligned/tablemode 长时间写入，维护 Benchmark 起始时间；运行期间按阶段执行查询与校验，观察进程和 CSV，采集 Prometheus 窗口指标、文件数、错误日志与业务断言。结束后停止进程、写入汇总结果并归档到 `/nasdata/repository/longrun_test`。

## 5. 验收与排查

验收必须覆盖：实际持续时间达到配置值、写入进度连续、查询和 TTL/删除断言通过、无数据倒退、资源无异常趋势、错误日志为空、归档完整。进程仍活着不代表长稳成功；若中途重启、时间漂移、磁盘满或 CSV 停止增长，应保留时间线后重测。
