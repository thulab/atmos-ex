# config_common.sh 使用说明

## 1. 职责

统一定位、安装场景配置，并更新 Benchmark 与 IoTDB 运行配置。场景脚本只描述配置维度，不再自行拼接旧目录或实现 `mv_config_file`。

## 2. 目录规范

```text
conf/<scenario>/
├── benchmark/cases/<case_id>.properties
├── iotdb/activation/license
├── iotdb/env/.env
├── nodes/<role>/iotdb/activation/license
├── nodes/<role>/iotdb/env/.env
└── assets/<asset_type>/...
```

`benchmark/cases` 保存 IoT-Benchmark 完整配置；`iotdb` 保存单节点运行配置；`nodes` 仅用于 Pipe 等多节点场景；非运行配置放入 `assets`。

## 3. Case 命名

Case ID 使用 `key=value` 维度，多个维度以 `__` 连接，例如：

```text
model=aligned__api=SESSION_BY_TABLET.properties
model=common__data=seq_w.properties
model=aligned__workload=query__query=Q4a-1.properties
scope=more__workload=query__query=Q4-a1.properties
```

维度值保留原始大小写和格式。查询编号不做归一化，`Q4-a1`、`Q4a-1` 等名称按各场景现状保存和查找。

## 4. 主要函数

- `config_build_case_id KEY VALUE...`：生成统一 Case ID。
- `benchmark_case_config_path CASE_ID`：返回当前场景 Case 文件路径。
- `install_benchmark_case_config CASE_ID [BM_PATH]`：原子安装 Case 到 Benchmark 的 `conf/config.properties`。
- `apply_benchmark_overrides BM_PATH KEY=VALUE...`：安装后应用 HOST、SQL 方言等运行时覆盖项。
- `install_iotdb_runtime_config [COPY_ENV]`：安装当前场景的 license 和可选 `.env`。
- `install_iotdb_runtime_config_to TARGET_ROOT [COPY_ENV]`：安装到集群等场景指定的 IoTDB 目录。
- `install_iotdb_node_runtime_config ROLE TARGET_ROOT`：安装指定节点角色的运行配置。
- `install_config_file SOURCE TARGET`：安装任意单个配置文件。
- `apply_iotdb_profile no_compaction|metrics|base`：应用标准 IoTDB 配置组。
- `set_iotdb_heap_memory DN [CN]`：修改 CN/DN 堆内存。

## 5. 调用示例

```bash
case_id="$(config_build_case_id model "${ts_type}" workload query query "${query_type}")"
install_benchmark_case_config "${case_id}"
apply_benchmark_overrides "${BM_PATH}" "HOST=${TEST_IP}"
install_iotdb_runtime_config
```

## 6. 校验

修改配置目录或场景引用后执行：

```bash
bash script/common/check_config_layout.sh
```

检查会验证 Benchmark 文件位置和扩展名、路径中的 IP、重复 properties key，以及已废弃的 `mv_config_file` 引用。
