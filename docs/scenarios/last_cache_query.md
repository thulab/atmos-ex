# Last Cache Query 场景操作说明

## 1. 场景概览

`last_cache_query.sh` 在 `11.101.17.141` 上测试持续后台写入时的 `LATEST_POINT` 查询。协议 `223`，类型为 `common`、`aligned`、`tablemode`，共 3 个 case；同时使用写入 Benchmark 和 `/data/atmos/zk_test/query-benchmark`。

## 2. 运行前准备

完成[通用运行前步骤](common-operations.md#3-运行前步骤)，检查 `conf/last_cache_query/{common,aligned,tablemode,Q8}`、许可证及两个 Benchmark 目录。确认 Q8 配置能执行 `LATEST_POINT`，tablemode case 能切换 table dialect。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/last_cache_query.sh 2>&1 | tee /data/atmos/zk_test/log_last_cache_query
```

## 4. 自动流程

脚本同步两份 Benchmark，重建 IoTDB 并显式启用 Last Cache；先启动对应类型的后台写入并预热 60 秒，再启动查询 Benchmark、继续预热并等待结果。随后 `flush`、解析 `LATEST_POINT`、采集指标、入库并停止全部进程。归档目录为 `/nasdata/repository/last_cache_query/<ts_type>/<commit_date_time>_<commit_id>_223/`，包含查询 CSV 和日志。

## 5. 验收与排查

预期 3 行结果。除查询吞吐和延迟外，要确认后台写入进程确实在查询窗口内运行；否则结果不能代表负载下 Last Cache。查询超时为 `-1` 占位，解析失败、启动失败和改密失败分别重点检查 `-2/-3/-4`。
