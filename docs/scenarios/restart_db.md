# Restart DB 场景操作说明

## 1. 场景概览

`restart_db.sh` 使用协议 `211`、`common`、`sequence` 预置数据验证 IoTDB 启动、停止和再次启动后的恢复能力。单轮最长监控 7200 秒，结果写入 `ex_restart_db(_T)`。

## 2. 运行前准备

完成[通用准备](common-operations.md#3-运行前步骤)，确认 `/data/atmos/DataSet/211/sequence/common` 的实际数据结构、`conf/restart_db/license` 和归档空间。确保数据与待测版本兼容，机器上无其他 IoTDB 实例。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/restart_db.sh 2>&1 | tee /data/atmos/zk_test/log_restart_db
```

## 4. 自动流程

脚本重建 IoTDB、应用协议和配置、复制预置数据，记录重启前文件统计；启动并检查就绪，停止后再次启动，监控恢复状态并记录前后数据大小、sequence/unsequence TsFile 数、耗时和错误日志，入库后仅归档 IoTDB 配置和日志，不归档 `data`。归档目录为 `${BACKUP_ROOT}/<scenario>/<commit_id>/<run_id>/cases/<case_id>/`。

## 5. 验收与排查

确认重启前后文件数和数据规模符合预期、第二次启动成功、`cost_time` 非负、错误日志为空。`-3` 表示启动失败；数据不一致时应检查版本兼容、WAL/共识恢复日志和预置数据是否完整。
