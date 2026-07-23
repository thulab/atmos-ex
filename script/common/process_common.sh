#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    printf '[ERROR] process_common.sh requires bash\n' >&2
    return 1 2>/dev/null || exit 1
fi

# 功能：按 Java 主类名返回匹配的进程 PID
process_pids_by_name() {
    local process_name="$1"
    jps | awk -v name="${process_name}" '$2 == name {print $1}'
}

# 功能：先发送 TERM，等待后对仍存活的 PID 发送 KILL
terminate_pids() {
    local description="$1"
    shift
    local pid=""
    local -a pids=("$@")

    [ "${#pids[@]}" -gt 0 ] || return 0
    for pid in "${pids[@]}"; do
        [ -n "${pid}" ] || continue
        kill -TERM "${pid}" 2>/dev/null || true
    done
    sleep "${PROCESS_STOP_WAIT_SECONDS:-2}"
    for pid in "${pids[@]}"; do
        [ -n "${pid}" ] || continue
        if kill -0 "${pid}" 2>/dev/null; then
            kill -KILL "${pid}" 2>/dev/null || true
        fi
    done
    log "${description} stopped"
}

# 功能：检查当前场景的前置条件、进程状态或结果有效性
check_pid_and_kill() {
    local process_name="$1"
    local description="${2:-$1}"
    local pid=""
    local -a pids=()

    while IFS= read -r pid; do
        [ -n "${pid}" ] && pids+=("${pid}")
    done < <(process_pids_by_name "${process_name}")
    if [ "${#pids[@]}" -eq 0 ]; then
        log "no ${description} process found"
        return 0
    fi
    terminate_pids "${description}" "${pids[@]}"
}

# 功能：检查并终止遗留的 Benchmark 进程
check_benchmark_pid() {
    check_pid_and_kill "App" "Benchmark"
}

# 功能：检查并终止遗留的 IoTDB Java 进程
check_iotdb_pid() {
    check_pid_and_kill "DataNode" "DataNode"
    check_pid_and_kill "ConfigNode" "ConfigNode"
    check_pid_and_kill "IoTDB" "IoTDB"
}

# 功能：统一清理 Benchmark 和 IoTDB 相关进程
cleanup_processes() {
    check_benchmark_pid
    check_iotdb_pid
}

# 功能：轮询等待指定条件成立或达到超时
wait_until() {
    local timeout_seconds="$1"
    local interval_seconds="$2"
    shift 2
    local start_epoch="${SECONDS}"

    while true; do
        if "$@"; then
            return 0
        fi
        if ((SECONDS - start_epoch >= timeout_seconds)); then
            return 1
        fi
        sleep "${interval_seconds}"
    done
}

# 功能：轮询等待指定条件成立或达到超时
wait_for_attempts() {
    local max_attempts="$1"
    local interval_seconds="$2"
    shift 2
    local attempt=0

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if "$@"; then
            return 0
        fi
        [ "${attempt}" -eq "${max_attempts}" ] || sleep "${interval_seconds}"
    done
    return 1
}

# 功能：刷新 IoTDB 相关进程的最大打开文件数和最大线程数
refresh_max_process_metrics() {
    local process_name=""
    local pid=""
    local open_files=0
    local threads=0
    local total_open_files=0
    local total_threads=0

    for process_name in DataNode ConfigNode IoTDB; do
        while IFS= read -r pid; do
            [ -n "${pid}" ] || continue
            open_files="$(lsof -p "${pid}" 2>/dev/null | wc -l | tr -d '[:space:]')"
            threads="$(ps -o nlwp= -p "${pid}" 2>/dev/null | awk '{sum += $1} END {print sum + 0}')"
            total_open_files=$((total_open_files + open_files))
            total_threads=$((total_threads + threads))
        done < <(process_pids_by_name "${process_name}")
    done

    if [ "${maxNumofOpenFiles:-0}" -lt "${total_open_files}" ]; then
        maxNumofOpenFiles="${total_open_files}"
    fi
    if [ "${maxNumofThread:-0}" -lt "${total_threads}" ]; then
        maxNumofThread="${total_threads}"
    fi
}
