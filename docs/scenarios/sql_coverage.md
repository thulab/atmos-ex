# SQL Coverage 场景操作说明

## 1. 场景概览

`sql_coverage.sh` 使用 `/data/atmos/zk_test/iotdb-sql` 工具和 `iotdb-sql-testcase` 执行 SQL 覆盖测试，结果写入 `ex_sql_coverage`，任务状态来自 `ex_commit_history.sql_coverage`。当前主流程显式设置协议 `223`（Ratis/Ratis/IoT）并执行 tablemode。

## 2. 运行前准备

检查 IoTDB 待测包、`iotdb-sql` 工具、testcase 仓库、JDK/编译脚本、`/data/nginx` UDF 依赖目录和 `conf/sql_coverage/license`。确认工具目录可被覆盖，测试账号可创建 UDF/数据库，设置 `ATMOS_DB_PASSWORD`。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/sql_coverage.sh 2>&1 | tee /data/atmos/zk_test/log_sql_coverage
```

## 4. 自动流程

脚本领取任务、同步 testcase，重建 IoTDB 和 SQL 工具，启动并先记录一条 FirstInsertSQL 基线；复制 UDF/driver/scripts，切换 table dialect，编译并后台运行 SQL 测试，最长等待 7200 秒生成 `result.xml`，统计 PASS/FAIL 后入库，停止服务并归档到 `/nasdata/repository/sql_coverage/master`。

## 5. 验收与排查

检查 FirstInsertSQL 与 tablemode 两类记录、`fail_num=0`、`result.xml` 完整及归档存在。不要把脚本顶部声明的四协议和四类型当作本轮实际矩阵。启动失败为 `-3`，超时通常 `fail_num=-1`。
