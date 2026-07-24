# Insert Records 场景操作说明

## 1. 场景概览

`insert_records.sh` 在 `11.101.17.153` 上专项测试 `SESSION_BY_RECORDS`。协议固定为 `223`，矩阵为 `common/aligned/tempaligned × seq_w/unseq_w`，共 6 个 case；结果写入 `ex_insert_records` 或 `_T` 表。

## 2. 运行前准备

1. 完成[通用运行前步骤](common-operations.md#3-运行前步骤)。
2. 检查 `conf/insert_records/{common,aligned,tempaligned}/{seq_w,unseq_w}`、`env` 和 `license`。
3. 确认 `11.101.17.153:9091` 指标和 IoT-Benchmark 版本可用。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/insert_records.sh 2>&1 | tee /data/atmos/zk_test/log_insert_records
```

## 4. 自动流程

脚本把复合 `ts_type` 拆为基础类型和写入模式，安装对应配置，然后按共享写入流程执行。每个 case 完成后删除 IoTDB `data`，将安装目录和 CSV 归档到 `/nasdata/repository/insert_records/<base>_<mode>/<commit_date_time>_<commit_id>_223/`。

## 5. 验收与排查

预期 6 行，且 `common/aligned/tempaligned` 各有一组顺序和乱序结果。重点比较同类型两种模式的吞吐、失败点及 sequence/unsequence 文件数；配置目录缺失会在启动 Benchmark 前直接失败。
