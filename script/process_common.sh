#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    printf '[ERROR] process_common.sh requires bash\n' >&2
    return 1 2>/dev/null || exit 1
fi

process_pids_by_name() {
    local process_name="$1"
    jps | awk -v name="${process_name}" '$2 == name {print $1}'
}

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
