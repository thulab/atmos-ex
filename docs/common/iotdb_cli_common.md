# iotdb_cli_common.sh 使用说明

## 1. 职责

统一调用待测安装目录中的 IoTDB CLI，封装主机、端口、用户和密码默认值。

## 2. 主要函数

- `iotdb_cli_run ARGS...`：原样调用 `${TEST_IOTDB_PATH}/sbin/start-cli.sh`。
- `iotdb_cli_exec SQL [HOST] [PORT] [USER] [PASSWORD]`：执行一条 SQL。
- `iotdb_cli_query ...`：与 exec 相同，但隐藏标准错误。

默认连接 `127.0.0.1:6667`、用户 root，密码取 `IOTDB_PASSWORD` 或 root；也可用 `IOTDB_CLI_*` 覆盖。

## 3. 调用示例

```bash
iotdb_cli_exec "show cluster"
iotdb_cli_exec "flush" 127.0.0.1 6667 root "${IOTDB_PASSWORD}"
rows="$(iotdb_cli_query 'count timeseries root.**')"
```

## 4. 副作用与安全

函数不限制 SQL 类型，可执行删除、授权等破坏性语句。密码通过命令行参数传递，可能短暂出现在进程列表；运行日志不要打印完整命令。

## 5. 排查

失败时检查 CLI 文件、执行权限、Java、端口、dialect 和密码。`iotdb_cli_query` 隐藏 stderr，诊断时改用 `iotdb_cli_exec`。
