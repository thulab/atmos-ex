# Delete Test 场景操作说明

## 1. 场景概览

`delete_test.sh` 在默认测试机 `172.20.31.31` 上，以协议 `223`、`common`、`SESSION_BY_TABLET` 执行删除专项：准备前后两阶段数据，执行删除语句，校验查询/文件统计，重启验证持久性，并开启合并后再次检查。结果写入 `ex_delete_test(_T)`。

该脚本大量参数支持 `DELETE_TEST_*` 环境变量覆盖；运行记录必须保存实际展开值。

## 2. 运行前准备

完成[通用准备](common-operations.md#3-运行前步骤)，检查 `conf/delete_test/env`、`write_first.properties`、`write_second.properties` 和 license；确认默认或覆盖后的测试 IP、IoTDB/Benchmark/归档路径，测试账号可执行删除 SQL，Prometheus target 可用。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/delete_test.sh 2>&1 | tee /data/atmos/zk_test/log_delete_test
```

## 4. 自动流程

脚本准备全新实例，完成第一、第二批写入及基线查询，执行配置中的删除范围并收集删除前后点数和 TsFile/mods 信息；随后重启数据库验证删除不回生，再启用三类合并、等待合并安静、flush 并做最终校验，记录功能断言和资源指标，保存运行现场。

## 5. 验收与排查

必须逐项检查断言结果、删除范围内/外点数、重启后结果、合并后结果和错误备注。即使 Benchmark 性能字段正常，只要删除数据回生、范围外数据误删、mods/TsFile 状态异常或合并超时，都应判失败并保留完整归档。
