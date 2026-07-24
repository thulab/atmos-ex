# UNSE Query 场景操作说明

## 1. 场景概览

`unse_query.sh` 在 `11.101.17.143` 上对 unsequence 预置数据执行协议 `211`、四种类型和 25 个标准查询，共 100 个 case。结果写入 `ex_unse_query` 或 `_T` 表。

## 2. 运行前准备

完成[通用运行前步骤](common-operations.md#3-运行前步骤)，检查 `conf/unse_query/<ts_type>/<Q*>`、许可证及 `/data/atmos/DataSet/211/<ts_type>/data`。确认预置数据包含乱序文件且与待测版本兼容。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/unse_query.sh 2>&1 | tee /data/atmos/zk_test/log_unse_query
```

## 4. 自动流程

流程与 `se_query` 相同，但结果的 `data_type` 为 `unsequence`。脚本移动数据集、逐查询启停 IoTDB、运行 Benchmark、入库和保存日志，最后恢复数据集并归档到 `/nasdata/repository/unse_query/<ts_type>/<commit_date_time>_<commit_id>/`。

## 5. 验收与排查

预期 100 行。重点核对 `data_type=unsequence`、乱序文件数和查询结果标签；若结果和顺序场景完全一致，应检查是否误用了 sequence 数据或配置。
