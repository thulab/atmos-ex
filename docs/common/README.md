# 公共脚本说明索引

`script/common` 共 20 个 Bash 公共脚本。场景入口通常先定义变量，再 `source` 这些脚本；除 `check_shell_style.sh` 外，不应把公共脚本当作独立命令执行。各入口脚本的完整运行步骤参见[场景脚本说明索引](../scenarios/README.md)。

## 依赖关系

```text
runtime_common.sh
├─ process_common.sh
├─ result_common.sh
├─ file_common.sh
├─ git_common.sh
├─ config_common.sh
├─ iotdb_cli_common.sh
└─ case_state_common.sh

iotdb_common.sh
├─ iotdb_distribution_common.sh
└─ iotdb_service_common.sh

insert_common.sh / query_common.sh
├─ runtime_common.sh
├─ iotdb_common.sh
├─ benchmark_common.sh
├─ remote_common.sh
└─ monitor_common.sh
```

## 文档导航

| 脚本 | 主要职责 | 文档 |
| --- | --- | --- |
| `api_test_common.sh` | 多语言 API 测试编排 | [说明](api_test_common.md) |
| `benchmark_common.sh` | Benchmark 启动、等待和解析 | [说明](benchmark_common.md) |
| `case_state_common.sh` | case 指标状态初始化 | [说明](case_state_common.md) |
| `check_shell_style.sh` | Shell 静态检查入口 | [说明](check_shell_style.md) |
| `config_common.sh` | 配置安装和 IoTDB profile | [说明](config_common.md) |
| `file_common.sh` | 文件统计和归档 | [说明](file_common.md) |
| `backup_common.sh` | 统一运行与 case 归档 | [说明](backup_common.md) |
| `git_common.sh` | Git 版本读取与同步 | [说明](git_common.md) |
| `insert_common.sh` | 写入类场景完整框架 | [说明](insert_common.md) |
| `iotdb_cli_common.sh` | IoTDB CLI 包装 | [说明](iotdb_cli_common.md) |
| `iotdb_common.sh` | 标准单机 IoTDB 配置 | [说明](iotdb_common.md) |
| `iotdb_distribution_common.sh` | 安装包准备 | [说明](iotdb_distribution_common.md) |
| `iotdb_service_common.sh` | IoTDB 启停与就绪检查 | [说明](iotdb_service_common.md) |
| `monitor_common.sh` | Prometheus 和磁盘指标 | [说明](monitor_common.md) |
| `platform_common.sh` | Linux/Windows 环境分派 | [说明](platform_common.md) |
| `process_common.sh` | 进程清理、等待和峰值采集 | [说明](process_common.md) |
| `protocol_common.sh` | 三位协议编码转换 | [说明](protocol_common.md) |
| `query_common.sh` | 查询类场景完整框架 | [说明](query_common.md) |
| `remote_common.sh` | Linux/Windows 远端操作 | [说明](remote_common.md) |
| `result_common.sh` | MySQL 和任务生命周期 | [说明](result_common.md) |
| `runtime_common.sh` | 公共运行时聚合入口 | [说明](runtime_common.md) |

## 调用原则

1. 入口脚本必须使用 Bash，并在 `source` 前设置被公共库要求的变量。
2. 公共函数大量读写场景全局变量；单个 case 建议通过 `run_isolated_case` 隔离。
3. 删除、移动、远端清理和 Git 同步函数存在明显副作用，调用前必须核对路径白名单。
4. 可选扩展点使用 `declare -F` 探测；同名函数覆盖应在文档标明，避免静默改变框架行为。
