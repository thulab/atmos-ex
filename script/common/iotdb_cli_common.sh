#!/usr/bin/env bash

# 功能：使用原始参数调用当前安装目录中的 IoTDB CLI
iotdb_cli_run() {
    "${TEST_IOTDB_PATH}/sbin/start-cli.sh" "$@"
}

# 功能：使用统一连接参数执行 SQL
iotdb_cli_exec() {
    local sql="$1"
    local host="${2:-${IOTDB_CLI_HOST:-127.0.0.1}}"
    local port="${3:-${IOTDB_CLI_PORT:-6667}}"
    local user="${4:-${IOTDB_CLI_USER:-root}}"
    local password="${5:-${IOTDB_PASSWORD:-root}}"
    iotdb_cli_run -h "${host}" -p "${port}" -u "${user}" -pw "${password}" -e "${sql}"
}

# 功能：执行 SQL 并隐藏 CLI 标准错误
iotdb_cli_query() {
    iotdb_cli_exec "$@" 2>/dev/null
}
