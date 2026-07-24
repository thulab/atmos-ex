# Config Insert 场景操作说明

## 1. 场景概览

`config_insert.sh` 在 `11.101.17.134` 上比较 IoTDB 配置项对 aligned 写入的影响。协议固定 `111`，共 24 个配置 case：WAL 模式 3 个、数组大小 4 个、时间分区 3 个、Chunk 元数据比例 4 个、合并优先级 3 个、目标 Chunk 大小 3 个、跨空间合并候选文件上限 4 个。

结果写入 `ex_config_insert` 或 `_T` 表，使用 `config_name/config_value` 标识 case。

## 2. 运行前准备

完成[通用运行前步骤](common-operations.md#3-运行前步骤)，确认 `conf/config_insert/aligned_<case_id>` 24 个配置文件和许可证均存在，`11.101.17.134:9091` 可抓取。合并相关 case 会同时开启三类合并，需预留更多磁盘和运行时间。

## 3. 启动步骤

```bash
export ATMOS_DB_PASSWORD='<数据库密码>'
cd /data/atmos/zk_test/atmos-ex
bash script/scenarios/config_insert.sh 2>&1 | tee /data/atmos/zk_test/log_config_insert
```

## 4. 自动流程

每个 case 都使用全新 IoTDB，在通用配置后追加目标属性；合并优先级、目标 Chunk 和候选文件大小 case 会启用所有合并。脚本运行 aligned 写入 Benchmark，解析 `INGESTION`，按配置维度执行历史吞吐控制限检查并入库，随后归档安装目录和 CSV。

## 5. 验收与排查

预期 24 行，按 `config_name,config_value` 核对无缺项和重复。比较配置时必须使用同一提交和相同数据量；WAL `DISABLE`、不同时间单位及小数比例不可按字符串排序直接判断性能趋势。吞吐控制限告警本身不会中断流程。
