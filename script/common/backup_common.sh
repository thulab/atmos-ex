#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    printf '[ERROR] backup_common.sh requires bash\n' >&2
    return 1 2>/dev/null || exit 1
fi

: "${BACKUP_ROOT:=/nasdata/repository}"
: "${BACKUP_LEVEL:=minimal}"
: "${ATMOS_BACKUP_RUN_ID:=$(date '+%Y%m%dT%H%M%S')-${BASHPID}}"
export BACKUP_ROOT BACKUP_LEVEL ATMOS_BACKUP_RUN_ID

BACKUP_RUN_DIR=""
BACKUP_CASE_DIR=""
BACKUP_CASE_STAGING_DIR=""
BACKUP_CASE_FAILED=0

# 功能：将目录名中的不安全字符转换为下划线
backup_safe_component() {
    local value="${1:-}"
    value="$(printf '%s' "${value}" | sed 's/[^A-Za-z0-9._=-]/_/g; s/^_*//; s/_*$//')"
    [ -n "${value}" ] || value="unknown"
    printf '%s' "${value}"
}

# 功能：按 key/value 参数生成稳定、可读的 case 标识
backup_build_case_id() {
    local result=""
    local key=""
    local value=""

    [ $(( $# % 2 )) -eq 0 ] || return 1
    while [ "$#" -gt 0 ]; do
        key="$(backup_safe_component "$1")"
        value="$(backup_safe_component "$2")"
        result="${result:+${result}__}${key}=${value}"
        shift 2
    done
    printf '%s' "${result:-case=default}"
}

# 功能：初始化当前提交的一次测试运行目录和运行清单
backup_begin_run() {
    local scenario=""
    local current_commit=""

    scenario="$(backup_safe_component "${TEST_TYPE:-unknown}")"
    current_commit="$(backup_safe_component "${commit_id:-unknown}")"
    BACKUP_RUN_DIR="${BACKUP_ROOT}/${scenario}/${current_commit}/${ATMOS_BACKUP_RUN_ID}"

    if [ ! -d "${BACKUP_RUN_DIR}" ]; then
        sudo mkdir -p -- "${BACKUP_RUN_DIR}/cases" "${BACKUP_RUN_DIR}/summary" || return 1
        sudo chmod 0777 "${BACKUP_RUN_DIR}" "${BACKUP_RUN_DIR}/cases" "${BACKUP_RUN_DIR}/summary" || return 1
        backup_write_env_file "${BACKUP_RUN_DIR}/manifest.env" \
            format_version 1 \
            scenario "${TEST_TYPE:-unknown}" \
            commit_id "${commit_id:-unknown}" \
            run_id "${ATMOS_BACKUP_RUN_ID}" \
            host "$(hostname 2>/dev/null || printf unknown)" \
            started_at "$(date -Iseconds)" \
            backup_level "${BACKUP_LEVEL}" \
            status running || return 1
    fi
    export BACKUP_RUN_DIR
}

# 功能：创建单个 case 的临时归档目录
backup_begin_case() {
    local case_id=""

    backup_begin_run || return 1
    case_id="$(backup_safe_component "${1:-case=default}")"
    BACKUP_CASE_DIR="${BACKUP_RUN_DIR}/cases/${case_id}"
    BACKUP_CASE_STAGING_DIR="${BACKUP_CASE_DIR}.partial"
    BACKUP_CASE_FAILED=0

    if [ -e "${BACKUP_CASE_DIR}" ] || [ -e "${BACKUP_CASE_STAGING_DIR}" ]; then
        log "backup case already exists: ${BACKUP_CASE_DIR}"
        return 1
    fi
    sudo mkdir -p -- "${BACKUP_CASE_STAGING_DIR}" || return 1
    sudo chmod 0777 "${BACKUP_CASE_STAGING_DIR}" || return 1
    backup_write_env_file "${BACKUP_CASE_STAGING_DIR}/manifest.env" \
        format_version 1 \
        case_id "${case_id}" \
        started_at "$(date -Iseconds)" \
        test_status running \
        backup_status running || return 1
    printf 'type\tsource\ttarget\trequired\tmode\tstatus\n' > "${BACKUP_CASE_STAGING_DIR}/artifacts.tsv"
    export BACKUP_CASE_DIR BACKUP_CASE_STAGING_DIR
}

# 功能：写入 key=value 格式的运行或 case 清单
backup_write_env_file() {
    local target="$1"
    local temp_file=""
    local key=""
    local value=""
    shift

    temp_file="$(mktemp "${TMPDIR:-/tmp}/atmos-backup.XXXXXX")" || return 1
    while [ "$#" -gt 1 ]; do
        key="$(backup_safe_component "$1")"
        value="$(printf '%s' "$2" | tr '\r\n' '  ')"
        printf '%s=%q\n' "${key}" "${value}" >> "${temp_file}"
        shift 2
    done
    if ! sudo cp -- "${temp_file}" "${target}" || ! sudo chmod 0666 "${target}"; then
        rm -f -- "${temp_file}"
        return 1
    fi
    rm -f -- "${temp_file}"
}

# 功能：向当前 case 清单追加元数据
backup_write_metadata() {
    [ -n "${BACKUP_CASE_STAGING_DIR}" ] || return 1
    printf '%s=%q\n' "$(backup_safe_component "$1")" "$2" >> "${BACKUP_CASE_STAGING_DIR}/manifest.env"
}

# 功能：复制或移动单项产物到当前 case 的标准分类目录
backup_add() {
    local artifact_type="$1"
    local source_path="$2"
    local target_name="${3:-$(basename "${source_path}")}"
    local required="${4:-optional}"
    local mode="${5:-copy}"
    local target_dir=""
    local status="archived"

    [ -n "${BACKUP_CASE_STAGING_DIR}" ] || return 1
    artifact_type="$(backup_safe_component "${artifact_type}")"
    target_name="$(backup_safe_component "${target_name}")"
    target_dir="${BACKUP_CASE_STAGING_DIR}/${artifact_type}"

    if [ ! -e "${source_path}" ]; then
        status="missing"
        [ "${required}" != "required" ] || BACKUP_CASE_FAILED=1
    else
        sudo mkdir -p -- "${target_dir}" || return 1
        case "${mode}" in
            copy) sudo cp -a -- "${source_path}" "${target_dir}/${target_name}" || status="failed" ;;
            move) sudo mv -- "${source_path}" "${target_dir}/${target_name}" || status="failed" ;;
            *) log "unsupported backup mode: ${mode}"; status="failed" ;;
        esac
        [ "${status}" = "archived" ] || BACKUP_CASE_FAILED=1
    fi
    printf '%s\t%s\t%s/%s\t%s\t%s\t%s\n' \
        "${artifact_type}" "${source_path}" "${artifact_type}" "${target_name}" \
        "${required}" "${mode}" "${status}" >> "${BACKUP_CASE_STAGING_DIR}/artifacts.tsv"
    [ "${status}" != "failed" ] && { [ "${status}" != "missing" ] || [ "${required}" != "required" ]; }
}

# 功能：按归档级别保存 IoTDB 运行产物
backup_add_iotdb_runtime() {
    local iotdb_path="${1:-${TEST_IOTDB_PATH:-}}"
    [ -n "${iotdb_path}" ] || return 0

    if [ "${BACKUP_LEVEL}" = "full" ]; then
        backup_add iotdb "${iotdb_path}" apache-iotdb optional
        return
    fi
    backup_add iotdb "${iotdb_path}/conf" conf optional
    backup_add iotdb "${iotdb_path}/logs" logs optional
    if [ "${BACKUP_LEVEL}" = "diagnostic" ]; then
        backup_add iotdb "${iotdb_path}/activation" activation optional
        backup_add iotdb "${iotdb_path}/tools/testlog" testlog optional
    fi
}

# 功能：保存 Benchmark 配置、日志和 CSV
backup_add_benchmark_runtime() {
    local benchmark_path="${1:-${BM_PATH:-}}"
    local label="${2:-benchmark}"
    [ -n "${benchmark_path}" ] || return 0
    backup_add "${label}" "${benchmark_path}/conf/config.properties" config.properties optional
    backup_add "${label}" "${benchmark_path}/logs" logs optional
    backup_add "${label}" "${benchmark_path}/data/csvOutput" csv optional
    backup_add "${label}" "${benchmark_path}/TestResult" test-result optional
}

# 功能：按统一默认内容完成单机 IoTDB 与 Benchmark case 归档
backup_standard_case() {
    local case_id="$1"
    local iotdb_path="${2:-${TEST_IOTDB_PATH:-}}"
    local benchmark_path="${3:-${BM_PATH:-}}"
    local test_status="${4:-completed}"

    backup_begin_case "${case_id}" || return 1
    backup_add_iotdb_runtime "${iotdb_path}"
    backup_add_benchmark_runtime "${benchmark_path}"
    backup_finish_case "${test_status}"
}

# 功能：按统一规范保存 API 测试失败报告和 IoTDB 诊断现场
backup_api_failure() {
    local language="$1"
    local revision="$2"
    local failures="$3"
    local report_path="$4"
    local case_id=""

    case_id="$(backup_build_case_id language "${language}" revision "${revision}" failures "${failures}")"
    backup_begin_case "${case_id}" || return 1
    backup_write_metadata language "${language}"
    backup_write_metadata failures "${failures}"
    backup_add result "${report_path}" "${language}-report" required
    BACKUP_LEVEL=diagnostic backup_add_iotdb_runtime
    backup_finish_case failed
}

# 功能：通过 SCP 将远端产物保存到 nodes/host 分类下
backup_add_remote() {
    local host="$1"
    local source_path="$2"
    local target_name="${3:-$(basename "${source_path}")}"
    local required="${4:-optional}"
    local node_dir=""
    local status="archived"

    [ -n "${BACKUP_CASE_STAGING_DIR}" ] || return 1
    node_dir="${BACKUP_CASE_STAGING_DIR}/nodes/$(backup_safe_component "${host}")"
    sudo mkdir -p -- "${node_dir}" || return 1
    sudo chmod 0777 "${node_dir}" || return 1
    if ! scp -r -- "${ACCOUNT:-atmos}@${host}:${source_path}" "${node_dir}/$(backup_safe_component "${target_name}")"; then
        status="failed"
        [ "${required}" != "required" ] || BACKUP_CASE_FAILED=1
    fi
    printf 'remote\t%s:%s\tnodes/%s/%s\t%s\tcopy\t%s\n' \
        "${host}" "${source_path}" "$(backup_safe_component "${host}")" \
        "$(backup_safe_component "${target_name}")" "${required}" "${status}" >> "${BACKUP_CASE_STAGING_DIR}/artifacts.tsv"
    [ "${status}" = "archived" ] || [ "${required}" != "required" ]
}

# 功能：原子完成当前 case 归档
backup_finish_case() {
    local test_status="${1:-unknown}"
    local backup_status="success"

    backup_write_metadata finished_at "$(date -Iseconds)" || return 1
    backup_write_metadata test_status "${test_status}" || return 1
    [ "${BACKUP_CASE_FAILED}" -eq 0 ] || backup_status="failed"
    backup_write_metadata backup_status "${backup_status}" || return 1
    sudo mv -- "${BACKUP_CASE_STAGING_DIR}" "${BACKUP_CASE_DIR}" || return 1
    sudo chmod -R go-w "${BACKUP_CASE_DIR}" || return 1
    BACKUP_CASE_STAGING_DIR=""
    [ "${backup_status}" = "success" ]
}

# 功能：更新运行级清单的最终状态
backup_finish_run() {
    local status="${1:-unknown}"
    [ -n "${BACKUP_RUN_DIR}" ] || backup_begin_run || return 1
    backup_write_env_file "${BACKUP_RUN_DIR}/manifest.env" \
        format_version 1 \
        scenario "${TEST_TYPE:-unknown}" \
        commit_id "${commit_id:-unknown}" \
        run_id "${ATMOS_BACKUP_RUN_ID}" \
        host "$(hostname 2>/dev/null || printf unknown)" \
        finished_at "$(date -Iseconds)" \
        backup_level "${BACKUP_LEVEL}" \
        status "${status}"
}
