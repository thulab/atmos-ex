# config_common.sh 使用说明

## 1. 职责

安装配置文件、批量更新 properties、应用标准 IoTDB profile，并统一修改 CN/DN 堆内存。

## 2. 主要函数

- `install_config_file SOURCE TARGET`：检查源并覆盖目标。
- `install_benchmark_config SOURCE [TARGET]`：默认写入 `${BM_PATH}/conf/config.properties`。
- `upsert_properties FILE KEY=VALUE...`：调用 `set_iotdb_property` 去重更新。
- `apply_iotdb_profile no_compaction|metrics|base`：关闭三类合并、启用 9081/9091 指标，或应用完整基础 profile。
- `set_iotdb_heap_memory DN [CN]`：修改 `ON_HEAP_MEMORY`。

## 3. 调用示例

```bash
install_benchmark_config "${ATMOS_PATH}/conf/${TEST_TYPE}/case1"
apply_iotdb_profile base
set_iotdb_heap_memory 20G 4G
```

## 4. 依赖与副作用

依赖 `die/set_iotdb_property` 以及 `TEST_IOTDB_PATH/TEST_TYPE/BM_PATH`。所有安装和 profile 操作都会覆盖或重写配置；`base` 会显式关闭合并并将 `cluster_name` 设为场景名。

## 5. 排查

配置未生效时检查是否有场景代码在之后追加同名属性；IoTDB 通常以后出现的属性为准。堆内存修改要求 env 文件中存在可匹配的 `ON_HEAP_MEMORY` 行。
