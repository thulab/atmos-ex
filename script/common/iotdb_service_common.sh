#!/usr/bin/env bash

# 功能：启动当前安装目录中的 ConfigNode 和 DataNode
start_iotdb() {
    if declare -F before_iotdb_start >/dev/null 2>&1; then
        before_iotdb_start
    fi
    (cd "${TEST_IOTDB_PATH}" && ./sbin/start-confignode.sh >/dev/null 2>&1 &)
    sleep "${STARTUP_GRACE_SECONDS:-10}"
    (cd "${TEST_IOTDB_PATH}" && ./sbin/start-datanode.sh -H "${TEST_IOTDB_PATH}/dn_dump.hprof" >/dev/null 2>&1 &)
}

# 功能：执行一次 DataNode 和 ConfigNode 停止操作
stop_iotdb_once() {
    (cd "${TEST_IOTDB_PATH}" && ./sbin/stop-datanode.sh >/dev/null 2>&1 &)
    sleep "${IOTDB_STOP_DATANODE_WAIT_SECONDS:-${STARTUP_GRACE_SECONDS:-10}}"
    (cd "${TEST_IOTDB_PATH}" && ./sbin/stop-confignode.sh >/dev/null 2>&1 &)
    sleep "${IOTDB_STOP_CONFIGNODE_WAIT_SECONDS:-0}"
}

# 功能：判断 ConfigNode 和 DataNode 进程是否均已退出
iotdb_processes_stopped() {
    [ -z "$(process_pids_by_name DataNode)" ] && [ -z "$(process_pids_by_name ConfigNode)" ]
}

# 功能：按配置的重试次数停止 IoTDB 服务
stop_iotdb() {
    local attempt=0
    local retries="${IOTDB_STOP_RETRIES:-0}"
    [ -d "${TEST_IOTDB_PATH}" ] || return 0
    for ((attempt = 0; attempt <= retries; attempt++)); do
        stop_iotdb_once
        [ "${retries}" -eq 0 ] && return 0
        iotdb_processes_stopped && return 0
    done
    return 1
}

# 功能：执行一次 IoTDB 集群就绪查询
iotdb_is_ready() {
    local output=""
    local -a cli_args=()
    [ -z "${IOTDB_READY_USER:-}" ] || cli_args+=(-u "${IOTDB_READY_USER}")
    [ -z "${IOTDB_READY_PASSWORD:-}" ] || cli_args+=(-pw "${IOTDB_READY_PASSWORD}")
    output="$("${TEST_IOTDB_PATH}/sbin/start-cli.sh" "${cli_args[@]}" -e "show cluster" 2>/dev/null | grep -F 'Total line number = 2' || true)"
    [ "${output}" = "Total line number = 2" ]
}

# 功能：按指定次数和间隔等待 IoTDB 达到就绪状态
wait_iotdb_ready() {
    local retries="${1:-${IOTDB_READY_RETRIES:-10}}"
    local interval="${2:-${IOTDB_READY_INTERVAL_SECONDS:-5}}"
    wait_for_attempts "${retries}" "${interval}" iotdb_is_ready
}

# 功能：使用默认重试参数等待 IoTDB 达到就绪状态
wait_for_iotdb_ready() {
    wait_iotdb_ready "${IOTDB_READY_RETRIES:-10}" "${IOTDB_READY_INTERVAL_SECONDS:-5}"
}

# 功能：检测并设置 IoTDB root 用户密码
change_root_password() {
    if "${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw "${IOTDB_PASSWORD}" -e "show cluster" >/dev/null 2>&1; then
        return 0
    fi
    "${TEST_IOTDB_PATH}/sbin/start-cli.sh" -e "ALTER USER root SET PASSWORD '${IOTDB_PASSWORD}'" >/dev/null 2>&1
}
