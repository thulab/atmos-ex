# monitor_common.sh 使用说明

## 1. 职责

解析 IoTDB 数据/WAL 路径对应的物理磁盘，通过 Prometheus 即时查询采集文件、线程、WAL、CPU 和磁盘 I/O 指标，并提供数值转换工具。

## 2. 调用契约

通常需要 `TEST_IOTDB_PATH/TEST_IP/METRIC_SERVER`，可设置 `DEFAULT_DISK_ID`。依赖 `awk/curl/jq/findmnt/lsblk/readlink` 和 `trim/require_command/log`。采集函数读写一组全局指标及 `disk_id_regex`。

## 3. 主要函数

- `get_monitor_disk_target_paths/resolve_monitor_disk_id`：从 `dn_data_dirs/dn_wal_dirs` 推导顶层块设备，失败回退默认盘。
- `prometheus_value/get_single_index`：调用 `/api/v1/query`，无结果返回 0。
- `begin_monitor_window/end_monitor_window`：维护 epoch 和有效窗口长度。
- `collect_standard_monitor_snapshot [IP] [WINDOW]`：采集标准指标。
- `bytes_to_gib/to_int/file_size_bytes`：数值与文件工具。

## 4. 调用示例

```bash
resolve_monitor_disk_id
begin_monitor_window
# run workload
end_monitor_window
collect_standard_monitor_snapshot "${TEST_IP}" "${monitor_window_seconds}"
```

## 5. 指标与排查

标准采集写入 `dataFileSize/numOfSe0Level/numOfUnse0Level/maxNumofThread/maxNumofOpenFiles/walFileSize/maxCPULoad/avgCPULoad` 和四项磁盘 I/O。全为 0 时检查 Prometheus target、label、时间窗口和指标名；磁盘 I/O 为 0 时查看日志中的解析磁盘或回退盘。
