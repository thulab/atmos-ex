# iotdb_service_common.sh 使用说明

## 1. 职责

封装单机 ConfigNode/DataNode 的后台启停、重启、就绪检测、失败回调和 root 改密。

## 2. 调用契约

必须定义 `TEST_IOTDB_PATH`，并加载 CLI、进程轮询和日志函数。可通过 `STARTUP_GRACE_SECONDS`、`IOTDB_READY_*`、`IOTDB_STOP_*` 调整时序；若定义 `before_iotdb_start`，启动前自动调用。

## 3. 主要函数

- `start_iotdb/start_iotdb_and_wait`：先 CN 后 DN，DN 带 heap dump 路径。
- `stop_iotdb/restart_iotdb_and_wait`：停止或重启，支持重试。
- `iotdb_is_ready/wait_iotdb_ready`：用多种候选密码执行 `show cluster`，要求 `Total line number = 2`。
- `start_iotdb_or_handle_failure CALLBACK`：失败后回调。
- `change_root_password`：已是目标密码则成功，否则用 root/root 修改。

## 4. 调用示例

```bash
start_iotdb_and_wait 10 5 || die "IoTDB not ready"
change_root_password
restart_iotdb_and_wait
stop_iotdb
```

## 5. 副作用与排查

服务以 nohup 后台启动且输出丢弃，诊断依赖 IoTDB 自身日志。就绪判断固定期望单机 2 行，不适合多节点集群。失败时函数会打印 CN/DN error log 最后 20 行。停止脚本本身后台执行，重试参数过小可能留下进程。
