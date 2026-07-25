# UNSE Insert 场景操作说明

## 1. 场景概览

`unse_insert.sh` 在 `11.101.17.136` 上通过共享写入框架运行协议 `223`、四种序列类型 `common/aligned/tempaligned/tablemode` 和 `SESSION_BY_TABLET` API。结果写入 `ex_unse_insert` 或 `_T` 表。

## 2. 运行前准备

完成[通用运行前步骤](common-operations.md#3-运行前步骤)，确认 `conf/unse_insert/<ts_type>_SESSION_BY_TABLET` 的时间生成策略确为乱序，许可证、Benchmark 以及 `11.101.17.136:9091` target 可用。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/unse_insert.sh 2>&1 | tee /data/atmos/zk_test/log_unse_insert
```

## 4. 自动流程

脚本逐 case 重建并启动 IoTDB、执行 Benchmark、解析 `INGESTION`、采集资源指标、入库和归档。归档路径为 `${BACKUP_ROOT}/<scenario>/<commit_id>/<run_id>/cases/<case_id>/`。

## 5. 验收与排查

预期 4 行结果。除通用指标外，应确认乱序写入后 `numOfUnse0Level` 与预期一致；若始终为 0，优先检查 Benchmark 配置时间策略，而不是仅重跑脚本。
