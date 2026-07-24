#!/usr/bin/env bash

# 功能：在远程主机上执行受控的部署或检查操作
remote_target() {
    local host="$1"
    printf '%s@%s' "${REMOTE_ACCOUNT:-${ACCOUNT:?ACCOUNT is required}}" "${host}"
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_exec() {
    local host="$1"
    shift
    ssh "$(remote_target "${host}")" "$@"
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_path_is_safe() {
    local path="$1"
    local allowed_root=""
    [ -n "${path}" ] || return 1
    case "${path}" in
        /|/data|/nasdata|/root|/home) return 1 ;;
        "${TEST_INIT_PATH:-__unset__}"|"${TEST_INIT_PATH:-__unset__}"/*|"${INIT_PATH:-__unset__}"|"${INIT_PATH:-__unset__}"/*|"${BACKUP_PATH:-__unset__}"|"${BACKUP_PATH:-__unset__}"/*|"${TEST_PATH:-__unset__}"|"${TEST_PATH:-__unset__}"/*|"${BM_PATH:-__unset__}"|"${BM_PATH:-__unset__}"/*) return 0 ;;
    esac
    IFS=: read -r -a allowed_roots <<< "${REMOTE_EXTRA_SAFE_ROOTS:-}"
    for allowed_root in "${allowed_roots[@]}"; do
        [ -n "${allowed_root}" ] || continue
        case "${path}" in
            "${allowed_root}"|"${allowed_root}"/*) return 0 ;;
        esac
    done
    return 1
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_safe_rm() {
    local host="$1"
    local path="$2"
    local quoted_path=""
    remote_path_is_safe "${path}" || die "refuse to remove unexpected remote path: ${host}:${path}"
    printf -v quoted_path '%q' "${path}"
    remote_exec "${host}" "rm -rf -- ${quoted_path}"
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_copy() {
    local source="$1"
    local host="$2"
    local destination="$3"
    scp -r -- "${source}" "$(remote_target "${host}"):${destination}"
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_copy_contents() (
    local source_dir="$1"
    local host="$2"
    local destination_dir="$3"
    local -a source_entries=()

    [ -d "${source_dir}" ] || die "missing local directory: ${source_dir}"
    remote_exec "${host}" "mkdir -p -- $(printf '%q' "${destination_dir}")"
    shopt -s dotglob nullglob
    source_entries=("${source_dir}"/*)
    [ "${#source_entries[@]}" -gt 0 ] || die "local directory is empty: ${source_dir}"
    scp -r -- "${source_entries[@]}" "$(remote_target "${host}"):${destination_dir}/" ||
        die "failed to copy directory contents to ${host}:${destination_dir}"
)

# 功能：在远程主机上执行受控的部署或检查操作
remote_reset_dir() {
    local host="$1"
    local path="$2"
    local quoted_path=""
    remote_safe_rm "${host}" "${path}"
    printf -v quoted_path '%q' "${path}"
    remote_exec "${host}" "mkdir -p -- ${quoted_path}"
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_clear_dir_contents() {
    local host="$1"
    local path="$2"
    local quoted_path=""
    remote_path_is_safe "${path}" || die "refuse to clear unexpected remote path: ${host}:${path}"
    printf -v quoted_path '%q' "${path}"
    remote_exec "${host}" "find ${quoted_path} -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +"
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_clear_configured_roots() {
    local host="$1"
    local root=""
    local roots="${2:-${REMOTE_CLEAR_ROOTS:-}}"
    IFS=: read -r -a clear_roots <<< "${roots}"
    for root in "${clear_roots[@]}"; do
        [ -n "${root}" ] || continue
        remote_clear_dir_contents "${host}" "${root}"
    done
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_reboot() {
    local host="$1"
    remote_exec "${host}" "${REMOTE_REBOOT_COMMAND:-sudo reboot}" || true
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_is_available() {
    remote_exec "$1" "true" >/dev/null 2>&1
}

# 功能：轮询等待指定条件成立或达到超时
wait_for_remote() {
    local host="$1"
    wait_for_attempts "${REMOTE_READY_RETRIES:-60}" "${REMOTE_READY_INTERVAL_SECONDS:-5}" remote_is_available "${host}"
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_reboot_and_wait() {
    local host="$1"
    remote_reboot "${host}"
    sleep "${REMOTE_REBOOT_GRACE_SECONDS:-30}"
    wait_for_remote "${host}"
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_append_property() {
    local host="$1"
    local properties_file="$2"
    local key="$3"
    local value="$4"
    local line="${key}=${value}"
    remote_exec "${host}" "printf '%s\\n' $(printf '%q' "${line}") >> $(printf '%q' "${properties_file}")"
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_start_background() {
    local host="$1"
    local command="$2"
    remote_exec "${host}" "nohup ${command} >/dev/null 2>&1 </dev/null &"
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_java_process_count() {
    local host="$1"
    local process_name="$2"
    remote_exec "${host}" "jps | awk -v name=$(printf '%q' "${process_name}") '\$2 == name {count++} END {print count + 0}'"
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_java_process_running() {
    [ "$(remote_java_process_count "$1" "$2")" -ge 1 ]
}

# 功能：轮询等待指定条件成立或达到超时
wait_for_remote_java_process() {
    local host="$1"
    local process_name="$2"
    wait_for_attempts "${REMOTE_PROCESS_RETRIES:-4}" "${REMOTE_PROCESS_INTERVAL_SECONDS:-30}" remote_java_process_running "${host}" "${process_name}"
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_iotdb_cluster_ready() {
    local host="$1"
    local cli_path="$2"
    local expected_nodes="$3"
    local output=""
    output="$(remote_exec "${host}" "$(printf '%q' "${cli_path}") -h $(printf '%q' "${host}") -p 6667 -e 'show cluster'" 2>/dev/null || true)"
    grep -Fq "Total line number = ${expected_nodes}" <<< "${output}"
}

# 功能：轮询等待指定条件成立或达到超时
wait_for_remote_iotdb_cluster() {
    local host="$1"
    local cli_path="$2"
    local expected_nodes="$3"
    wait_for_attempts "${REMOTE_IOTDB_READY_RETRIES:-21}" "${REMOTE_IOTDB_READY_INTERVAL_SECONDS:-3}" remote_iotdb_cluster_ready "${host}" "${cli_path}" "${expected_nodes}"
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_clean_benchmark_runtime() {
    local host="$1"
    local benchmark_path="${2:-${BM_PATH}}"
    remote_safe_rm "${host}" "${benchmark_path}/logs"
    remote_safe_rm "${host}" "${benchmark_path}/data"
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_deploy_benchmark() {
    local host="$1"
    local benchmark_path="${2:-${BM_PATH}}"
    remote_reset_dir "${host}" "${benchmark_path}"
    remote_copy_contents "${benchmark_path}" "${host}" "${benchmark_path}"
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_start_benchmark() {
    local host="$1"
    local benchmark_path="${2:-${BM_PATH}}"
    remote_start_background "${host}" "cd $(printf '%q' "${benchmark_path}") && ./benchmark.sh"
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_windows_reboot() {
    remote_exec "$1" "shutdown /f /r /t 0" || true
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_windows_is_available() {
    local host="$1"
    local drive="${2:-D:}"
    remote_exec "${host}" "dir ${drive}" >/dev/null 2>&1
}

# 功能：轮询等待指定条件成立或达到超时
wait_for_remote_windows() {
    local host="$1"
    local drive="${2:-D:}"
    wait_for_attempts "${REMOTE_WINDOWS_READY_RETRIES:-60}" "${REMOTE_WINDOWS_READY_INTERVAL_SECONDS:-5}" remote_windows_is_available "${host}" "${drive}"
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_windows_reset_dir() {
    local host="$1"
    local path="$2"
    remote_exec "${host}" "if exist \"${path}\" rmdir /s /q \"${path}\" & md \"${path}\""
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_windows_copy_contents() {
    local source_dir="$1"
    local host="$2"
    local destination_dir="$3"

    [ -d "${source_dir}" ] || die "missing local directory: ${source_dir}"
    [ -n "$(find "${source_dir}" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
        die "local directory is empty: ${source_dir}"
    scp -T -r -- "${source_dir}/." "$(remote_target "${host}"):${destination_dir}" ||
        die "failed to copy directory contents to ${host}:${destination_dir}"
}

# 功能：在远程主机上执行受控的部署或检查操作
remote_windows_run_task() {
    local host="$1"
    local task_name="$2"
    remote_exec "${host}" "schtasks /Run /TN \"${task_name}\""
}
