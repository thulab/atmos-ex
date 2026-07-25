# Count TS 场景操作说明

## 1. 场景概览

`count_ts.sh` 测量协议 `223` 下 `common/aligned/template/tempaligned` 四类时间序列的创建耗时，以及 all/各类型的 `count timeseries` 和 `show timeseries` 耗时。结果写入 `ex_count_ts(_T)`。

## 2. 运行前准备

完成[通用准备](common-operations.md#3-运行前步骤)，检查 `conf/count_ts/benchmark/cases/` 下四类 Benchmark 配置、`conf/count_ts/iotdb/activation/license`、IoT-Benchmark 和 `${BACKUP_ROOT}/<scenario>/<commit_id>/<run_id>/cases/<case_id>/` 空间。该场景会创建大量元数据，需重点确认堆内存、元数据盘和打开文件限制。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/count_ts.sh 2>&1 | tee /data/atmos/zk_test/log_count_ts
```

## 4. 自动流程

脚本重建 IoTDB，协议设为 `223`，启动并改密；依次运行四类 schema Benchmark，执行一次 `flush`，随后执行 5 条 count 和 5 条 show 命令并记录耗时，采集文件/线程/错误日志指标并入库。最终 IoTDB 配置、日志与 Benchmark 产物归档到 `${BACKUP_ROOT}/<scenario>/<commit_id>/<run_id>/cases/<case_id>/`。

## 5. 验收与排查

核对 create/count/show 共 15 个耗时字段均非负且四类创建结果齐全。`-3` 为启动失败、`-4` 为改密失败，单项 `-1` 通常表示 Benchmark 或 CLI 失败。还应检查实际 timeseries 数量是否符合配置，而非只比较耗时。
