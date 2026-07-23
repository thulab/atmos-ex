#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
if shopt -oq posix; then
    exec bash "${BASH_SOURCE[0]}" "$@"
fi

set -u
set -o pipefail

readonly TEST_IP="${TREEVIEW_QUERY_TEST_IP:-11.101.17.155}"
readonly TEST_TYPE="treeview_query"
readonly QUERY_DATA_TYPE="treeview"

IOTDB_PASSWORD="${TREEVIEW_IOTDB_PASSWORD:-root}"
INIT_PATH="${TREEVIEW_INIT_PATH:-/data/atmos/zk_test}"
ATMOS_PATH="${TREEVIEW_ATMOS_PATH:-${INIT_PATH}/atmos-ex}"
BM_PATH="${TREEVIEW_BM_PATH:-${INIT_PATH}/iot-benchmark}"
REPOS_PATH="${TREEVIEW_REPOS_PATH:-/nasdata/repository/master}"
BM_REPOS_PATH="${TREEVIEW_BM_REPOS_PATH:-/nasdata/repository/iot-benchmark}"
BACKUP_PATH="${TREEVIEW_BACKUP_PATH:-/nasdata/repository/${TEST_TYPE}}"
TEST_INIT_PATH="${TREEVIEW_TEST_INIT_PATH:-/data/atmos}"
TEST_IOTDB_PATH="${TREEVIEW_TEST_IOTDB_PATH:-${TEST_INIT_PATH}/apache-iotdb}"

MYSQL_HOST="${TREEVIEW_MYSQL_HOST:-111.200.37.158}"
MYSQL_PORT="${TREEVIEW_MYSQL_PORT:-13306}"
MYSQL_USERNAME="${TREEVIEW_MYSQL_USERNAME:-iotdbatm}"
MYSQL_PASSWORD="${ATMOS_DB_PASSWORD:-}"
DBNAME="${TREEVIEW_MYSQL_DBNAME:-QA_ATM}"
TABLENAME="${TREEVIEW_RESULT_TABLE_NAME:-ex_${TEST_TYPE}}"
TABLENAME_T="${TREEVIEW_RESULT_TABLE_NAME_T:-${TABLENAME}_T}"
TASK_TABLENAME="${TREEVIEW_TASK_TABLENAME:-ex_commit_history}"

METRIC_SERVER="${TREEVIEW_METRIC_SERVER:-111.200.37.158:19090}"
MONITOR_TIMEOUT_SECONDS="${TREEVIEW_MONITOR_TIMEOUT_SECONDS:-21600}"
MONITOR_POLL_INTERVAL_SECONDS="${TREEVIEW_MONITOR_POLL_INTERVAL_SECONDS:-10}"
IOTDB_READY_RETRIES="${TREEVIEW_IOTDB_READY_RETRIES:-10}"
IOTDB_READY_INTERVAL_SECONDS="${TREEVIEW_IOTDB_READY_INTERVAL_SECONDS:-5}"
IOTDB_READY_USER="${TREEVIEW_IOTDB_READY_USER:-root}"
IOTDB_READY_PASSWORD="${TREEVIEW_IOTDB_READY_PASSWORD:-${IOTDB_PASSWORD}}"
STARTUP_GRACE_SECONDS="${TREEVIEW_STARTUP_GRACE_SECONDS:-10}"
BENCHMARK_RESULT_WAIT_SECONDS="${TREEVIEW_BENCHMARK_WARMUP_SECONDS:-2}"
BENCHMARK_STOP_WAIT_SECONDS="${TREEVIEW_BENCHMARK_STOP_WAIT_SECONDS:-30}"

readonly QUERY_REPEAT_COUNT="${TREEVIEW_QUERY_REPEAT_COUNT:-1}"
readonly ENABLE_BENCHMARK_VERSION_CHECK="${TREEVIEW_ENABLE_BENCHMARK_VERSION_CHECK:-1}"

readonly -a PROTOCOL_LIST=(211)
readonly -a QUERY_LIST=(
    Q1 Q2-1 Q2-2 Q2-3 Q3-1 Q3-2 Q3-3 Q4a-1 Q4a-2 Q4a-3
    Q4b-1 Q4b-2 Q4b-3 Q5 Q6-1 Q6-2 Q6-3 Q7-1 Q7-2 Q7-3
    Q8 Q9-1 Q9-2 Q9-3 Q10
)
readonly -a QUERY_RESULT_LABELS=(
    PRECISE_POINT TIME_RANGE TIME_RANGE TIME_RANGE VALUE_RANGE VALUE_RANGE VALUE_RANGE
    AGG_RANGE AGG_RANGE AGG_RANGE AGG_RANGE AGG_RANGE AGG_RANGE AGG_VALUE
    AGG_RANGE_VALUE AGG_RANGE_VALUE AGG_RANGE_VALUE GROUP_BY GROUP_BY GROUP_BY
    LATEST_POINT RANGE_QUERY_DESC RANGE_QUERY_DESC RANGE_QUERY_DESC VALUE_RANGE_QUERY_DESC
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/common/query_common.sh
source "${SCRIPT_DIR}/../common/query_common.sh"

readonly SE_QUERY_DATASET_PATH="${TREEVIEW_SE_QUERY_DATASET_PATH:-/nasdata/se_query/DataSet}"
readonly UNSE_QUERY_DATASET_PATH="${TREEVIEW_UNSE_QUERY_DATASET_PATH:-/nasdata/unse_query/DataSet}"

readonly TREEVIEW_DB_NAME="${TREEVIEW_DB_NAME:-test}"
readonly TREEVIEW_GROUP_NAME_PREFIX="${TREEVIEW_GROUP_NAME_PREFIX:-g_}"
readonly TREEVIEW_TABLE_NAME_PREFIX="${TREEVIEW_TABLE_NAME_PREFIX:-table_}"
readonly TREEVIEW_GROUP_INDEX="${TREEVIEW_GROUP_INDEX:-0}"
readonly TREEVIEW_TABLE_DATABASE="${TREEVIEW_TABLE_DATABASE:-${TREEVIEW_DB_NAME}_${TREEVIEW_GROUP_NAME_PREFIX}${TREEVIEW_GROUP_INDEX}}"
readonly TREEVIEW_TABLE_NAME="${TREEVIEW_TABLE_NAME:-${TREEVIEW_TABLE_NAME_PREFIX}0}"
readonly TREEVIEW_TREE_PREFIX="${TREEVIEW_TREE_PREFIX:-root.${TREEVIEW_DB_NAME}.${TREEVIEW_GROUP_NAME_PREFIX}${TREEVIEW_GROUP_INDEX}}"

if [ -n "${TREEVIEW_QUERY_SUITES:-}" ]; then
    IFS=',' read -r -a QUERY_DATA_TYPES <<< "${TREEVIEW_QUERY_SUITES}"
    readonly -a QUERY_DATA_TYPES
else
    readonly -a QUERY_DATA_TYPES=(
        seq_common
        seq_aligned
        unseq_common
        unseq_aligned
    )
fi

if [ -n "${TREEVIEW_QUERY_SENSOR_TYPES:-}" ]; then
    IFS=',' read -r -a QUERY_SENSOR_TYPES <<< "${TREEVIEW_QUERY_SENSOR_TYPES}"
    readonly -a QUERY_SENSOR_TYPES
else
    readonly -a QUERY_SENSOR_TYPES=()
fi

result_table_name="${TABLENAME}"
ts_type=""
data_type=""
query_type=""
query_label_name=""
query_suite_type=""
sensor_type=""
query_num=1

sql_maybe_quote() {
    local value="${1:-}"

    if [ -n "${value}" ]; then
        sql_quote "${value}"
    else
        printf 'NULL'
    fi
}

emit_query_name_candidates() {
    local current_name="$1"
    local alternate_name=""

    printf '%s\n' "${current_name}"
    if [[ "${current_name}" =~ ^(Q[0-9]+)-([ab])([0-9]+)$ ]]; then
        alternate_name="${BASH_REMATCH[1]}${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
    elif [[ "${current_name}" =~ ^(Q[0-9]+)([ab])-([0-9]+)$ ]]; then
        alternate_name="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
    fi

    if [ -n "${alternate_name}" ] && [ "${alternate_name}" != "${current_name}" ]; then
        printf '%s\n' "${alternate_name}"
    fi
}

normalize_query_name() {
    local current_name="$1"

    if [[ "${current_name}" =~ ^(Q[0-9]+)-([ab])([0-9]+)$ ]]; then
        printf '%s%s-%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        return 0
    fi

    printf '%s\n' "${current_name}"
}

resolve_config_from_roots() {
    local config_name="$1"
    shift
    local root=""
    local candidate_name=""
    local candidate_path=""

    for root in "$@"; do
        [ -n "${root}" ] || continue
        while IFS= read -r candidate_name; do
            [ -n "${candidate_name}" ] || continue
            candidate_path="${root}/${candidate_name}"
            if [ -f "${candidate_path}" ]; then
                printf '%s\n' "${candidate_path}"
                return 0
            fi
        done < <(emit_query_name_candidates "${config_name}")
    done

    return 1
}

build_scoped_path() {
    local base_path="${1%/}"
    shift
    local current_segment=""
    local path="${base_path}"

    for current_segment in "$@"; do
        current_segment="$(trim "${current_segment}")"
        [ -n "${current_segment}" ] || continue
        current_segment="${current_segment// /_}"
        current_segment="${current_segment//\//_}"
        path="${path}/${current_segment}"
    done

    printf '%s\n' "${path}"
}

init_items() {
    reset_benchmark_metrics
    numOfSe0Level=0
    numOfUnse0Level=0
    start_time=""
    end_time=""
    cost_time=0
    dataFileSize=0
    maxNumofOpenFiles=0
    maxNumofThread=0
    errorLogSize=0
    walFileSize=0
    m_start_time=0
    m_end_time=0
    ts_type=""
    data_type=""
    query_type=""
    query_label_name=""
    query_suite_type=""
    sensor_type=""
    query_num=1
}

validate_query_settings() {
    [[ "${QUERY_REPEAT_COUNT}" =~ ^[1-9][0-9]*$ ]] || die "QUERY_REPEAT_COUNT must be a positive integer"
    [ "${#QUERY_LIST[@]}" -eq "${#QUERY_RESULT_LABELS[@]}" ] || die "QUERY_LIST and QUERY_RESULT_LABELS length mismatch"
}

check_benchmark_pid() {
    check_pid_and_kill "App" "benchmark"
}

check_iotdb_pid() {
    check_pid_and_kill "DataNode" "DataNode"
    check_pid_and_kill "ConfigNode" "ConfigNode"
    check_pid_and_kill "IoTDB" "IoTDB"
}

copy_benchmark_config() {
    local config_source="$1"
    local config_target="${BM_PATH}/conf/config.properties"

    [ -f "${config_source}" ] || die "missing benchmark config: ${config_source}"
    safe_rm "${config_target}"
    cp -rf -- "${config_source}" "${config_target}"
}

upsert_benchmark_property() {
    local key="$1"
    local value="$2"
    local config_file="${BM_PATH}/conf/config.properties"
    local tmp_file="${config_file}.tmp"

    [ -f "${config_file}" ] || die "missing benchmark config: ${config_file}"
    awk -v key="${key}" -v value="${value}" '
        BEGIN { updated = 0 }
        index($0, key "=") == 1 {
            print key "=" value
            updated = 1
            next
        }
        { print }
        END {
            if (!updated) {
                print key "=" value
            }
        }
    ' "${config_file}" > "${tmp_file}"
    mv -- "${tmp_file}" "${config_file}"
}

copy_query_dataset() {
    local protocol_code="$1"
    local current_suite_type="$2"
    local source_path=""

    source_path="$(resolve_query_dataset_source "${protocol_code}" "${current_suite_type}")"
    [ -d "${source_path}" ] || die "missing query dataset: ${source_path}"
    cp -rf -- "${source_path}" "${TEST_IOTDB_PATH}/"
}

prepare_backup_directory() {
    local backup_dir="$1"
    local backup_parent="${backup_dir%/*}"

    sudo_safe_rm "${backup_dir}"
    path_is_safe "${backup_parent}" || die "refuse to use unexpected backup path: ${backup_parent}"
    sudo mkdir -p -- "${backup_parent}"
    path_is_safe "${backup_dir}" || die "refuse to use unexpected backup path: ${backup_dir}"
    sudo mkdir -p -- "${backup_dir}"
}

archive_test_runtime_artifacts() {
    local backup_dir="$1"
    local csv_source="${BM_PATH}/data/csvOutput"
    local iotdb_target="${backup_dir}/iotdb"

    prepare_backup_directory "${backup_dir}"

    sudo_safe_rm "${TEST_IOTDB_PATH}/data"
    path_is_safe "${TEST_IOTDB_PATH}" || die "refuse to move unexpected path: ${TEST_IOTDB_PATH}"
    sudo mv -- "${TEST_IOTDB_PATH}" "${iotdb_target}"

    if [ -d "${csv_source}" ]; then
        sudo cp -rf -- "${csv_source}" "${backup_dir}/"
    fi
}

backup_test_data() {
    local protocol_code="$1"
    local current_suite_type="$2"
    local backup_dir=""

    backup_dir="$(build_scoped_path \
        "${BACKUP_PATH}" \
        "protocol=${protocol_code}" \
        "suite=${current_suite_type}" \
        "commit=${commit_date_time}_${commit_id}")"
    archive_test_runtime_artifacts "${backup_dir}"
}

treeview_base_suite() {
    local current_suite_type="$1"

    case "${current_suite_type}" in
        seq_common|unseq_common)
            printf 'common\n'
            ;;
        seq_aligned|unseq_aligned)
            printf 'aligned\n'
            ;;
        seq_tempaligned|unseq_tempaligned)
            printf 'tempaligned\n'
            ;;
        *)
            die "unsupported treeview query suite: ${current_suite_type}"
            ;;
    esac
}

treeview_config_suite() {
    local current_suite_type="$1"

    case "${current_suite_type}" in
        seq_*)
            printf 'seq\n'
            ;;
        unseq_*)
            printf 'unseq\n'
            ;;
        *)
            die "unsupported treeview query suite: ${current_suite_type}"
            ;;
    esac
}

treeview_dataset_root() {
    local current_suite_type="$1"

    case "${current_suite_type}" in
        seq_*)
            printf '%s\n' "${SE_QUERY_DATASET_PATH}"
            ;;
        unseq_*)
            printf '%s\n' "${UNSE_QUERY_DATASET_PATH}"
            ;;
        *)
            die "unsupported treeview query suite: ${current_suite_type}"
            ;;
    esac
}

treeview_source_data_type() {
    local current_suite_type="$1"

    case "${current_suite_type}" in
        seq_*)
            printf 'sequence\n'
            ;;
        unseq_*)
            printf 'unsequence\n'
            ;;
        *)
            die "unsupported treeview query suite: ${current_suite_type}"
            ;;
    esac
}

resolve_query_dataset_source() {
    local protocol_code="$1"
    local current_suite_type="$2"
    local base_suite=""
    local dataset_root=""

    base_suite="$(treeview_base_suite "${current_suite_type}")"
    dataset_root="$(treeview_dataset_root "${current_suite_type}")"
    printf '%s/%s/%s/data\n' "${dataset_root}" "${protocol_code}" "${base_suite}"
}

resolve_query_config_source() {
    local current_suite_type="$1"
    local current_query="$2"
    local current_sensor_type="${3:-}"
    local config_suite=""
    local config_root=""
    local resolved_path=""

    config_suite="$(treeview_config_suite "${current_suite_type}")"
    config_root="${ATMOS_PATH}/conf/${TEST_TYPE}/query/${config_suite}"
    resolved_path="$(resolve_config_from_roots "${current_query}" "${config_root}")" || \
        die "missing treeview benchmark config: ${current_query} (suite=${current_suite_type}, sensor=${current_sensor_type:-default})"
    printf '%s\n' "${resolved_path}"
}

prepare_query_context() {
    local current_suite_type="$1"
    local current_query="$2"
    local current_sensor_type="$3"
    local current_repeat="$4"
    local current_query_label="${5:-}"
    local base_suite=""

    base_suite="$(treeview_base_suite "${current_suite_type}")"
    ts_type="treeview_${base_suite}"
    data_type="$(treeview_source_data_type "${current_suite_type}")"
    query_type="$(normalize_query_name "${current_query}")"
    query_label_name="${current_query_label}"
    query_suite_type="${current_suite_type}"
    sensor_type="${current_sensor_type}"
    query_num="${current_repeat}"
}

append_tablemode_config_if_needed() {
    upsert_benchmark_property "IoTDB_DIALECT_MODE" "table"
    upsert_benchmark_property "DB_NAME" "${TREEVIEW_DB_NAME}"
    upsert_benchmark_property "GROUP_NAME_PREFIX" "${TREEVIEW_GROUP_NAME_PREFIX}"
    upsert_benchmark_property "IoTDB_TABLE_NAME_PREFIX" "${TREEVIEW_TABLE_NAME_PREFIX}"
    upsert_benchmark_property "IoTDB_TABLE_NUMBER" "1"
}

treeview_cli_sql() {
    local sql="$1"
    local output=""
    local status=0
    local -a cmd=(
        "${TEST_IOTDB_PATH}/sbin/start-cli.sh"
        -u "${IOTDB_READY_USER}"
        -pw "${IOTDB_READY_PASSWORD}"
        -sql_dialect table
        -h 127.0.0.1
        -p 6667
        -e "${sql}"
    )

    output="$("${cmd[@]}" 2>&1)"
    status=$?
    if [ "${status}" -ne 0 ]; then
        log "failed to execute table sql: ${sql}"
        log "${output}"
        return "${status}"
    fi
    printf '%s\n' "${output}"
}

prepare_tree_to_table_view() {
    local current_suite_type="$1"
    local view_name="${TREEVIEW_TABLE_DATABASE}.${TREEVIEW_TABLE_NAME}"
    local source_path="${TREEVIEW_TREE_PREFIX}.**"

    log "prepare Tree-to-Table view ${view_name} from ${source_path} for ${current_suite_type}"
    treeview_cli_sql "CREATE DATABASE IF NOT EXISTS ${TREEVIEW_TABLE_DATABASE}" >/dev/null || return 1
    treeview_cli_sql "CREATE OR REPLACE VIEW ${view_name} (device_id STRING TAG) AS ${source_path}" >/dev/null || return 1
    treeview_cli_sql "SHOW CREATE VIEW ${view_name}" >/dev/null || return 1
    treeview_cli_sql "SELECT count(s_0) FROM ${view_name} WHERE device_id = 'd_0'" >/dev/null || return 1
}

mv_config_file() {
    local current_suite_type="$1"
    local current_query="$2"
    local current_sensor_type="${3:-}"

    prepare_tree_to_table_view "${current_suite_type}" || die "failed to prepare Tree-to-Table view for ${current_suite_type}"
    copy_benchmark_config "$(resolve_query_config_source "${current_suite_type}" "${current_query}" "${current_sensor_type}")"
    append_tablemode_config_if_needed
}

query_log_dir_suffix() {
    local current_query="$1"

    if [ -n "${sensor_type:-}" ]; then
        printf '%s_%s\n' "${current_query}" "${sensor_type}"
    else
        printf '%s\n' "${current_query}"
    fi
}

insert_result_row() {
    local protocol_code="$1"
    local insert_sql=""

    insert_sql=$(cat <<EOF
insert into ${result_table_name} (
    commit_date_time,test_date_time,commit_id,author,ts_type,data_type,query_type,
    okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,
    MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,
    numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,walFileSize,
    avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,
    protocol_code,query_suite_type,query_sensor_type,query_repeat_no,query_id,query_label,result_kind,remark
) values (
    ${commit_date_time},
    ${test_date_time},
    $(sql_quote "${commit_id}"),
    $(sql_quote "${author}"),
    $(sql_quote "${ts_type}"),
    $(sql_quote "${data_type}"),
    $(sql_quote "${query_type}"),
    ${okPoint},
    ${okOperation},
    ${failPoint},
    ${failOperation},
    ${throughput},
    ${Latency},
    ${MIN},
    ${P10},
    ${P25},
    ${MEDIAN},
    ${P75},
    ${P90},
    ${P95},
    ${P99},
    ${P999},
    ${MAX},
    ${numOfSe0Level},
    $(sql_quote "${start_time}"),
    $(sql_quote "${end_time}"),
    ${cost_time},
    ${numOfUnse0Level},
    ${dataFileSize},
    ${maxNumofOpenFiles},
    ${maxNumofThread},
    ${errorLogSize},
    ${walFileSize},
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    $(sql_quote "${protocol_code}"),
    $(sql_maybe_quote "${query_suite_type}"),
    $(sql_maybe_quote "${sensor_type}"),
    ${query_num},
    $(sql_maybe_quote "${query_type}"),
    $(sql_maybe_quote "${query_label_name}"),
    'query',
    $(sql_quote "${protocol_code}")
)
EOF
)

    mysql_exec "${insert_sql}"
}

archive_query_logs() {
    local current_query="$1"
    local log_suffix=""
    local live_log_dir="${TEST_IOTDB_PATH}/logs"
    local archived_log_dir=""

    log_suffix="$(query_log_dir_suffix "${current_query}")"
    archived_log_dir="${TEST_IOTDB_PATH}/logs_${log_suffix}"

    mkdir -p "${live_log_dir}"
    if [ -d "${BM_PATH}/data/csvOutput" ]; then
        cp -rf -- "${BM_PATH}/data/csvOutput" "${live_log_dir}/"
    fi

    safe_rm "${archived_log_dir}"
    mv -- "${live_log_dir}" "${archived_log_dir}"
}

test_operation() {
    local protocol_code="$1"
    local current_suite_type=""
    local current_query=""
    local current_sensor_type=""
    local current_repeat=0
    local query_label=""
    local query_scope=""
    local csv_file=""
    local index=0
    local monitor_failed=0
    local operation_failed=0
    local -a sensor_types=()

    if [ "${#QUERY_SENSOR_TYPES[@]}" -gt 0 ]; then
        sensor_types=("${QUERY_SENSOR_TYPES[@]}")
    else
        sensor_types=("")
    fi

    for current_suite_type in "${QUERY_DATA_TYPES[@]}"; do
        log "start protocol=${protocol_code}, suite=${current_suite_type}"
        cleanup_processes
        set_env
        modify_iotdb_config

        if ! set_protocol_class "${protocol_code}"; then
            log "invalid protocol code: ${protocol_code}"
            return 1
        fi

        copy_query_dataset "${protocol_code}" "${current_suite_type}"

        for current_sensor_type in "${sensor_types[@]}"; do
            for ((index = 0; index < ${#QUERY_LIST[@]}; index++)); do
                current_query="${QUERY_LIST[${index}]}"
                query_label="${QUERY_RESULT_LABELS[${index}]}"
                query_scope="${current_query}"
                if [ -n "${current_sensor_type}" ]; then
                    query_scope="${query_scope}/${current_sensor_type}"
                fi

                log "start ${current_suite_type} ${query_scope}"
                check_iotdb_pid
                sleep 1
                start_iotdb
                sleep "${STARTUP_GRACE_SECONDS}"

                if ! wait_for_iotdb_ready; then
                    init_items
                    prepare_query_context "${current_suite_type}" "${current_query}" "${current_sensor_type}" 1 "${query_label}"
                    log "IoTDB is not ready; write failed result"
                    start_time="$(current_datetime)"
                    end_time="${start_time}"
                    cost_time=-3
                    set_negative_benchmark_metrics -3
                    insert_result_row "${protocol_code}"
                    operation_failed=1
                    stop_iotdb || true
                    sleep "${BENCHMARK_STOP_WAIT_SECONDS}"
                    cleanup_processes
                    continue
                fi

                mv_config_file "${current_suite_type}" "${current_query}" "${current_sensor_type}"
                sleep 3

                for ((current_repeat = 1; current_repeat <= QUERY_REPEAT_COUNT; current_repeat++)); do
                    init_items
                    prepare_query_context "${current_suite_type}" "${current_query}" "${current_sensor_type}" "${current_repeat}" "${query_label}"
                    monitor_failed=0

                    start_benchmark
                    start_time="$(current_datetime)"
                    m_start_time="$(date +%s)"
                    sleep "${BENCHMARK_RESULT_WAIT_SECONDS}"

                    if ! monitor_test_status "${current_query}" "${query_label}"; then
                        monitor_failed=1
                    fi

                    m_end_time="$(date +%s)"
                    collect_monitor_data

                    csv_file="$(find_result_csv || true)"
                    if [ -z "${csv_file}" ] || ! parse_benchmark_result "${csv_file}" "${query_label}"; then
                        log "failed to parse benchmark result; write fallback result"
                        [ -n "${end_time}" ] || end_time="$(current_datetime)"
                        cost_time=-2
                        set_negative_benchmark_metrics -2
                        insert_result_row "${protocol_code}"
                        operation_failed=1
                    else
                        [ -n "${end_time}" ] || end_time="$(current_datetime)"
                        cost_time=$(( $(datetime_to_epoch "${end_time}") - $(datetime_to_epoch "${start_time}") ))
                        insert_result_row "${protocol_code}"
                        log "${commit_id} ${ts_type} ${query_scope} repeat=${query_num} okPoint=${okPoint} latency=${Latency}ms"
                    fi

                    if [ "${monitor_failed}" -ne 0 ]; then
                        operation_failed=1
                    fi
                    check_benchmark_pid
                done

                archive_query_logs "${current_query}"
                stop_iotdb || true
                sleep "${BENCHMARK_STOP_WAIT_SECONDS}"
                cleanup_processes
            done
        done

        log "${current_suite_type} finished"
        [ -d "${TEST_IOTDB_PATH}" ] && backup_test_data "${protocol_code}" "${current_suite_type}"
    done

    return "${operation_failed}"
}

main() {
    local protocol=""
    local task_failed=0

    trap restore_test_type_file EXIT

    ensure_runtime_dependencies
    check_password
    validate_query_settings
    if [ "${ENABLE_BENCHMARK_VERSION_CHECK}" = "1" ]; then
        check_benchmark_version
    fi

    mark_test_in_progress
    if ! fetch_next_commit; then
        sleep 60
        return 0
    fi

    if [ "${author}" = "Timecho" ]; then
        result_table_name="${TABLENAME_T}"
    else
        result_table_name="${TABLENAME}"
    fi

    update_task_status "ontesting"
    log "start query test for commit ${commit_id}, result table ${result_table_name}"

    test_date_time="$(date +%Y%m%d%H%M%S)"
    for protocol in "${PROTOCOL_LIST[@]}"; do
        init_items
        if ! test_operation "${protocol}"; then
            task_failed=1
        fi
    done

    log "query test ${test_date_time} finished"
    if [ "${task_failed}" -eq 0 ]; then
        update_task_status "done"
        if [ "${author}" != "Timecho" ]; then
            mark_older_commits_skip
        fi
    else
        update_task_status "RError"
    fi
}

main "$@"
