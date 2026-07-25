# Routine Test 场景操作说明

## 1. 场景概览

`routine_test.sh` 在 `11.101.17.156` 执行常规回归，写入接口声明为 `SESSION_BY_TABLET/RECORDS/RECORD/JDBC`，实际写入模式包含 `seq_w/unseq_w/seq_rw/unseq_rw`，并执行 Q1 至 Q10 的标准查询组合。结果写入 `ex_routine_test(_T)`。

脚本按作者和本机 IP 路由任务：Timecho 任务固定到 `.156` 和 `_T` 表，普通任务使用作者过滤。运行前必须确认本机能领取目标任务。

## 2. 运行前准备与启动步骤

检查 `conf/routine_test` 的 env、license、四类写入配置和全部 Q 配置，确认 IoT-Benchmark、测试 IP 和任务作者过滤正确。然后执行：

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/routine_test.sh 2>&1 | tee /data/atmos/zk_test/log_routine_test
```

## 3. 自动流程

脚本领取匹配作者的提交，重建并配置 IoTDB；执行写入/读写 Benchmark，随后基于生成数据逐项运行查询，解析 CSV、采集资源指标并入库；每阶段日志、配置和 CSV 归档到 `${BACKUP_ROOT}/<scenario>/<commit_id>/<run_id>/cases/<case_id>/`。

## 4. 验收与排查

按日志中的实际 case 核对结果，不能简单用数组笛卡尔积估算。重点检查写入失败点、各查询结果标签、作者路由、`RError` 和负值字段；普通任务在错误测试机上查不到是路由问题，不应通过修改任务状态绕过。
