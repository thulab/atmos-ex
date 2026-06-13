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
readonly IOTDB_PW="${TREEVIEW_IOTDB_PW:-root}"
readonly RESULT_TABLE_NAME="${TREEVIEW_RESULT_TABLE_NAME:-ex_${TEST_TYPE}}"

readonly INIT_PATH="${TREEVIEW_INIT_PATH:-/data/atmos/zk_test}"
readonly ATMOS_PATH="${TREEVIEW_ATMOS_PATH:-${INIT_PATH}/atmos-ex}"
readonly BM_PATH="${TREEVIEW_BM_PATH:-${INIT_PATH}/iot-benchmark}"
readonly REPOS_PATH="${TREEVIEW_REPOS_PATH:-/nasdata/repository/master}"
readonly BM_REPOS_PATH="${TREEVIEW_BM_REPOS_PATH:-/nasdata/repository/iot-benchmark}"
readonly BACKUP_PATH="${TREEVIEW_BACKUP_PATH:-/nasdata/repository/${TEST_TYPE}}"
readonly TEST_INIT_PATH="${TREEVIEW_TEST_INIT_PATH:-/data/atmos}"
readonly TEST_IOTDB_PATH="${TREEVIEW_TEST_IOTDB_PATH:-${TEST_INIT_PATH}/apache-iotdb}"

readonly MYSQLHOSTNAME="${TREEVIEW_MYSQL_HOSTNAME:-111.200.37.158}"
readonly PORT="${TREEVIEW_MYSQL_PORT:-13306}"
readonly USERNAME="${TREEVIEW_MYSQL_USERNAME:-iotdbatm}"
readonly PASSWORD="${ATMOS_DB_PASSWORD:-}"
readonly DBNAME="${TREEVIEW_MYSQL_DBNAME:-QA_ATM}"
readonly TASK_TABLENAME="${TREEVIEW_TASK_TABLENAME:-ex_commit_history}"

readonly METRIC_SERVER="${TREEVIEW_METRIC_SERVER:-111.200.37.158:19090}"
readonly QUERY_REPEAT_COUNT="${TREEVIEW_QUERY_REPEAT_COUNT:-1}"
readonly BENCHMARK_WARMUP_SECONDS="${TREEVIEW_BENCHMARK_WARMUP_SECONDS:-2}"
readonly BENCHMARK_STOP_WAIT_SECONDS="${TREEVIEW_BENCHMARK_STOP_WAIT_SECONDS:-30}"
readonly STARTUP_GRACE_SECONDS="${TREEVIEW_STARTUP_GRACE_SECONDS:-10}"
readonly MONITOR_TIMEOUT_SECONDS="${TREEVIEW_MONITOR_TIMEOUT_SECONDS:-21600}"
readonly MONITOR_POLL_INTERVAL_SECONDS="${TREEVIEW_MONITOR_POLL_INTERVAL_SECONDS:-10}"
readonly IOTDB_READY_RETRIES="${TREEVIEW_IOTDB_READY_RETRIES:-10}"
readonly IOTDB_READY_INTERVAL_SECONDS="${TREEVIEW_IOTDB_READY_INTERVAL_SECONDS:-5}"
readonly ENABLE_BENCHMARK_VERSION_CHECK="${TREEVIEW_ENABLE_BENCHMARK_VERSION_CHECK:-1}"

readonly SE_QUERY_DATASET_PATH="${TREEVIEW_SE_QUERY_DATASET_PATH:-/nasdata/se_query/DataSet}"
readonly UNSE_QUERY_DATASET_PATH="${TREEVIEW_UNSE_QUERY_DATASET_PATH:-/nasdata/unse_query/DataSet}"

readonly TREEVIEW_DB_NAME="${TREEVIEW_DB_NAME:-test}"
readonly TREEVIEW_GROUP_NAME_PREFIX="${TREEVIEW_GROUP_NAME_PREFIX:-g_}"
readonly TREEVIEW_TABLE_NAME_PREFIX="${TREEVIEW_TABLE_NAME_PREFIX:-table_}"
readonly TREEVIEW_GROUP_INDEX="${TREEVIEW_GROUP_INDEX:-0}"
readonly TREEVIEW_TABLE_DATABASE="${TREEVIEW_TABLE_DATABASE:-${TREEVIEW_DB_NAME}_${TREEVIEW_GROUP_NAME_PREFIX}${TREEVIEW_GROUP_INDEX}}"
readonly TREEVIEW_TABLE_NAME="${TREEVIEW_TABLE_NAME:-${TREEVIEW_TABLE_NAME_PREFIX}0}"
readonly TREEVIEW_TREE_PREFIX="${TREEVIEW_TREE_PREFIX:-root.${TREEVIEW_DB_NAME}.${TREEVIEW_GROUP_NAME_PREFIX}${TREEVIEW_GROUP_INDEX}}"

readonly -a PROTOCOL_CLASS=(
    ""
    "org.apache.iotdb.consensus.simple.SimpleConsensus"
    "org.apache.iotdb.consensus.ratis.RatisConsensus"
    "org.apache.iotdb.consensus.iot.IoTConsensus"
    "org.apache.iotdb.consensus.iot.IoTConsensusV2"
)
readonly -a PROTOCOL_LIST=(211)
readonly -a QUERY_LIST=(
    Q1 Q2-1 Q2-2 Q2-3 Q3-1 Q3-2 Q3-3 Q4a-1 Q4a-2 Q4a-3
    Q4b-1 Q4b-2 Q4b-3 Q5 Q6-1 Q6-2 Q6-3 Q7-1 Q7-2 Q7-3
    Q8 Q9-1 Q9-2 Q9-3 Q10
)
readonly -a QUERY_LABELS=(
    PRECISE_POINT TIME_RANGE TIME_RANGE TIME_RANGE VALUE_RANGE VALUE_RANGE VALUE_RANGE
    AGG_RANGE AGG_RANGE AGG_RANGE AGG_RANGE AGG_RANGE AGG_RANGE AGG_VALUE
    AGG_RANGE_VALUE AGG_RANGE_VALUE AGG_RANGE_VALUE GROUP_BY GROUP_BY GROUP_BY
    LATEST_POINT RANGE_QUERY_DESC RANGE_QUERY_DESC RANGE_QUERY_DESC VALUE_RANGE_QUERY_DESC
)

if [ -n "${TREEVIEW_QUERY_SUITES:-}" ]; then
    IFS=',' read -r -a QUERY_DATA_TYPES <<< "${TREEVIEW_QUERY_SUITES}"
    readonly -a QUERY_DATA_TYPES
else
    readonly -a QUERY_DATA_TYPES=(
        seq_common
        seq_aligned
        seq_tempaligned
        unseq_common
        unseq_aligned
        unseq_tempaligned
    )
fi

if [ -n "${TREEVIEW_QUERY_SENSOR_TYPES:-}" ]; then
    IFS=',' read -r -a QUERY_SENSOR_TYPES <<< "${TREEVIEW_QUERY_SENSOR_TYPES}"
    readonly -a QUERY_SENSOR_TYPES
else
    readonly -a QUERY_SENSOR_TYPES=()
fi

commit_id=""
author=""
commit_date_time=""
test_date_time=""
ts_type=""
data_type=""
query_type=""
query_label_name=""
query_suite_type=""
sensor_type=""
query_num=1
start_time=""
end_time=""
cost_time=0
m_start_time=0
m_end_time=0

okPoint=0
okOperation=0
failPoint=0
failOperation=0
throughput=0
Latency=0
MIN=0
P10=0
P25=0
MEDIAN=0
P75=0
P90=0
P95=0
P99=0
P999=0
MAX=0
numOfSe0Level=0
numOfUnse0Level=0
dataFileSize=0
maxNumofOpenFiles=0
maxNumofThread=0
errorLogSize=0
walFileSize=0

IOTDB_READY_USER="${TREEVIEW_IOTDB_READY_USER:-root}"
IOTDB_READY_PASSWORD="${TREEVIEW_IOTDB_READY_PASSWORD:-${IOTDB_PW}}"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
    log "error: $*"
    exit 1
}

trim() {
    local value="${1:-}"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

current_datetime() {
    date '+%Y-%m-%d %H:%M:%S'
}

datetime_to_epoch() {
    date -d "$1" +%s
}

normalize_datetime() {
    printf '%s' "$1" | tr -cd '0-9'
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

check_password() {
    [ -n "${PASSWORD}" ] || die "ATMOS_DB_PASSWORD is required for MySQL access"
}

ensure_runtime_dependencies() {
    local cmd=""

    for cmd in awk cat cp curl date du grep jq jps kill mkdir mv mysql rm sed sudo tr wc; do
        require_command "${cmd}"
    done
}

path_is_safe() {
    local path="$1"

    [ -n "${path}" ] || return 1
    case "${path}" in
        "/"|"/data"|"/nasdata"|".")
            return 1
            ;;
        "${INIT_PATH}"/*|"${TEST_INIT_PATH}"/*|"${BACKUP_PATH}"/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

safe_rm() {
    local path="$1"

    [ -e "${path}" ] || return 0
    path_is_safe "${path}" || die "refuse to remove unexpected path: ${path}"
    rm -rf -- "${path}"
}

sudo_safe_rm() {
    local path="$1"

    [ -e "${path}" ] || return 0
    path_is_safe "${path}" || die "refuse to sudo remove unexpected path: ${path}"
    sudo rm -rf -- "${path}"
}

copy_if_exists() {
    local source="$1"
    local target="$2"
    local label="${3:-$1}"

    if [ ! -e "${source}" ]; then
        log "skip missing ${label}: ${source}"
        return 0
    fi

    cp -rf -- "${source}" "${target}"
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

mysql_exec() {
    local sql="$1"

    MYSQL_PWD="${PASSWORD}" mysql -N -B -h"${MYSQLHOSTNAME}" -P"${PORT}" -u"${USERNAME}" "${DBNAME}" -e "${sql}"
}

sql_quote() {
    local value="${1:-}"

    value="${value//\\/\\\\}"
    value="$(printf '%s' "${value}" | sed "s/'/''/g")"
    printf "'%s'" "${value}"
}

sql_maybe_quote() {
    local value="${1:-}"

    if [ -n "${value}" ]; then
        sql_quote "${value}"
    else
        printf 'NULL'
    fi
}

update_task_status() {
    local status="$1"

    mysql_exec "update ${TASK_TABLENAME} set ${TEST_TYPE} = $(sql_quote "${status}") where commit_id = $(sql_quote "${commit_id}")"
}

mark_older_commits_skip() {
    mysql_exec "update ${TASK_TABLENAME} set ${TEST_TYPE} = 'skip' where ${TEST_TYPE} is NULL and commit_date_time < $(sql_quote "${commit_date_time}")"
}

query_next_commit() {
    local status_filter="$1"

    if [ "${status_filter}" = "retest" ]; then
        mysql_exec "SELECT commit_id, author, commit_date_time FROM ${TASK_TABLENAME} WHERE ${TEST_TYPE} = 'retest' ORDER BY commit_date_time desc LIMIT 1"
    else
        mysql_exec "SELECT commit_id, author, commit_date_time FROM ${TASK_TABLENAME} WHERE ${TEST_TYPE} is NULL ORDER BY commit_date_time desc LIMIT 1"
    fi
}

fetch_next_commit() {
    local row=""
    local raw_commit_date_time=""

    row="$(query_next_commit "retest")"
    if [ -z "${row}" ]; then
        row="$(query_next_commit "pending")"
    fi
    [ -n "${row}" ] || return 1

    IFS=$'\t' read -r commit_id author raw_commit_date_time <<< "${row}"
    author="$(trim "${author}")"
    commit_date_time="$(normalize_datetime "${raw_commit_date_time}")"
    [ -n "${commit_id}" ] || return 1
    [ -n "${commit_date_time}" ] || die "failed to parse commit_date_time"
}

check_benchmark_version() {
    local bm_new=""
    local bm_old=""

    [ -f "${BM_REPOS_PATH}/git.properties" ] || die "missing benchmark git.properties: ${BM_REPOS_PATH}/git.properties"
    bm_new="$(awk -F= '/git.commit.id.abbrev/ {print $2}' "${BM_REPOS_PATH}/git.properties")"
    [ -n "${bm_new}" ] || die "failed to read benchmark version"

    if [ -f "${BM_PATH}/git.properties" ]; then
        bm_old="$(awk -F= '/git.commit.id.abbrev/ {print $2}' "${BM_PATH}/git.properties")"
    fi

    if [ ! -d "${BM_PATH}" ] || [ "${bm_old}" != "${bm_new}" ]; then
        log "sync benchmark to latest version"
        mkdir -p "${INIT_PATH}"
        safe_rm "${BM_PATH}"
        cp -rf "${BM_REPOS_PATH}" "${BM_PATH}"
    fi
}

init_common_items() {
    okPoint=0
    okOperation=0
    failPoint=0
    failOperation=0
    throughput=0
    Latency=0
    MIN=0
    P10=0
    P25=0
    MEDIAN=0
    P75=0
    P90=0
    P95=0
    P99=0
    P999=0
    MAX=0
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
}

init_items() {
    init_common_items
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
    [ "${#QUERY_LIST[@]}" -eq "${#QUERY_LABELS[@]}" ] || die "QUERY_LIST and QUERY_LABELS length mismatch"
}

check_pid_and_kill() {
    local pname="$1"
    local desc="$2"
    local pids=""
    local pid=""

    pids="$(jps | awk -v pname="${pname}" '$2 == pname {print $1}')"
    if [ -z "${pids}" ]; then
        log "no ${desc} process found"
        return 0
    fi

    while IFS= read -r pid; do
        [ -n "${pid}" ] || continue
        kill -9 "${pid}"
    done <<< "${pids}"

    log "stopped ${desc}"
}

check_benchmark_pid() {
    check_pid_and_kill "App" "benchmark"
}

check_iotdb_pid() {
    check_pid_and_kill "DataNode" "DataNode"
    check_pid_and_kill "ConfigNode" "ConfigNode"
    check_pid_and_kill "IoTDB" "IoTDB"
}

cleanup_processes() {
    check_benchmark_pid
    check_iotdb_pid
}

set_env() {
    local source_path="${REPOS_PATH}/${commit_id}/apache-iotdb"

    [ -d "${source_path}" ] || die "missing test IoTDB directory: ${source_path}"

    safe_rm "${TEST_IOTDB_PATH}"
    mkdir -p "${TEST_IOTDB_PATH}/activation"
    cp -rf "${source_path}/." "${TEST_IOTDB_PATH}/"
    copy_if_exists "${ATMOS_PATH}/conf/${TEST_TYPE}/license" "${TEST_IOTDB_PATH}/activation/" "license"
    copy_if_exists "${ATMOS_PATH}/conf/${TEST_TYPE}/env" "${TEST_IOTDB_PATH}/.env" "env"
}

append_iotdb_properties() {
    local properties_file="$1"

    cat >> "${properties_file}" <<EOF
series_slot_num=10000
enable_seq_space_compaction=false
enable_unseq_space_compaction=false
enable_cross_space_compaction=false
EOF
}

modify_iotdb_config() {
    local datanode_env="${TEST_IOTDB_PATH}/conf/datanode-env.sh"
    local properties_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"

    [ -f "${datanode_env}" ] || die "missing config file: ${datanode_env}"
    [ -f "${properties_file}" ] || die "missing config file: ${properties_file}"

    sed -i 's/^#\?ON_HEAP_MEMORY=.*$/ON_HEAP_MEMORY="20G"/' "${datanode_env}"

    cat >> "${properties_file}" <<EOF
cluster_name=${TEST_TYPE}
cn_enable_metric=true
cn_enable_performance_stat=true
cn_metric_reporter_list=PROMETHEUS
cn_metric_level=ALL
cn_metric_prometheus_reporter_port=9081
dn_enable_metric=true
dn_enable_performance_stat=true
dn_metric_reporter_list=PROMETHEUS
dn_metric_level=ALL
dn_metric_prometheus_reporter_port=9091
EOF

    append_iotdb_properties "${properties_file}"
}

set_protocol_class() {
    local protocol_code="$1"
    local config_node="${protocol_code:0:1}"
    local schema_region="${protocol_code:1:1}"
    local data_region="${protocol_code:2:1}"
    local properties_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"

    [ "${#protocol_code}" -eq 3 ] || return 1
    [ -n "${PROTOCOL_CLASS[${config_node}]:-}" ] || return 1
    [ -n "${PROTOCOL_CLASS[${schema_region}]:-}" ] || return 1
    [ -n "${PROTOCOL_CLASS[${data_region}]:-}" ] || return 1

    cat >> "${properties_file}" <<EOF
config_node_consensus_protocol_class=${PROTOCOL_CLASS[${config_node}]}
schema_region_consensus_protocol_class=${PROTOCOL_CLASS[${schema_region}]}
data_region_consensus_protocol_class=${PROTOCOL_CLASS[${data_region}]}
EOF
}

start_iotdb() {
    (
        cd "${TEST_IOTDB_PATH}" || exit 1
        ./sbin/start-confignode.sh >/dev/null 2>&1 &
    )
    sleep "${STARTUP_GRACE_SECONDS}"
    (
        cd "${TEST_IOTDB_PATH}" || exit 1
        ./sbin/start-datanode.sh -H "${TEST_IOTDB_PATH}/dn_dump.hprof" >/dev/null 2>&1 &
    )
}

stop_iotdb() {
    if [ ! -d "${TEST_IOTDB_PATH}" ]; then
        return 0
    fi

    (
        cd "${TEST_IOTDB_PATH}" || exit 1
        ./sbin/stop-datanode.sh >/dev/null 2>&1 &
    )
    sleep "${STARTUP_GRACE_SECONDS}"
    (
        cd "${TEST_IOTDB_PATH}" || exit 1
        ./sbin/stop-confignode.sh >/dev/null 2>&1 &
    )
}

start_benchmark() {
    safe_rm "${BM_PATH}/logs"
    safe_rm "${BM_PATH}/data"
    (
        cd "${BM_PATH}" || exit 1
        ./benchmark.sh >/dev/null 2>&1 &
    )
}

wait_for_iotdb_ready() {
    local attempt=0
    local iotdb_state=""
    local -a cli_args=()

    if [ -n "${IOTDB_READY_USER}" ]; then
        cli_args+=(-u "${IOTDB_READY_USER}")
    fi
    if [ -n "${IOTDB_READY_PASSWORD}" ]; then
        cli_args+=(-pw "${IOTDB_READY_PASSWORD}")
    fi

    for ((attempt = 1; attempt <= IOTDB_READY_RETRIES; attempt++)); do
        if [ "${#cli_args[@]}" -gt 0 ]; then
            iotdb_state="$("${TEST_IOTDB_PATH}/sbin/start-cli.sh" "${cli_args[@]}" -e "show cluster" 2>/dev/null | grep -F 'Total line number = 2' || true)"
        else
            iotdb_state="$("${TEST_IOTDB_PATH}/sbin/start-cli.sh" -e "show cluster" 2>/dev/null | grep -F 'Total line number = 2' || true)"
        fi
        if [ "${iotdb_state}" = "Total line number = 2" ]; then
            return 0
        fi
        sleep "${IOTDB_READY_INTERVAL_SECONDS}"
    done

    return 1
}

find_result_csv() {
    local had_nullglob=0
    local files=()

    if shopt -q nullglob; then
        had_nullglob=1
    else
        shopt -s nullglob
    fi

    files=("${BM_PATH}/data/csvOutput/"*result.csv)

    if [ "${had_nullglob}" -eq 0 ]; then
        shopt -u nullglob
    fi

    if [ "${#files[@]}" -gt 0 ]; then
        printf '%s\n' "${files[0]}"
    fi
}

create_stuck_result_csv() {
    local csv_file="$1"
    local result_label="$2"
    local index=0

    mkdir -p "${csv_file%/*}"
    : > "${csv_file}"
    for ((index = 0; index < 100; index++)); do
        printf '%s ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1\n' "${result_label}" >> "${csv_file}"
    done
}

monitor_test_status() {
    local current_name="$1"
    local result_label="$2"
    local csv_file=""
    local now_epoch=0
    local elapsed=0

    while true; do
        csv_file="$(find_result_csv || true)"
        if [ -n "${csv_file}" ]; then
            end_time="$(current_datetime)"
            log "${current_name} finished"
            return 0
        fi

        now_epoch="$(date +%s)"
        elapsed=$((now_epoch - m_start_time))
        if [ "${elapsed}" -ge "${MONITOR_TIMEOUT_SECONDS}" ]; then
            end_time="$(current_datetime)"
            log "${current_name} timed out; write fallback result"
            create_stuck_result_csv "${BM_PATH}/data/csvOutput/Stuck_result.csv" "${result_label}"
            return 1
        fi

        sleep "${MONITOR_POLL_INTERVAL_SECONDS}"
    done
}

get_single_index() {
    local query="$1"
    local end="$2"
    local index_value=""

    index_value="$(
        curl -G -s "http://${METRIC_SERVER}/api/v1/query" \
            --data-urlencode "query=${query}" \
            --data-urlencode "time=${end}" \
            | jq -r '.data.result[0].value[1] // 0'
    )"

    if [ "${index_value}" = "null" ] || [ -z "${index_value}" ]; then
        index_value=0
    fi

    printf '%s\n' "${index_value}"
}

bytes_to_gib() {
    awk -v value="${1:-0}" 'BEGIN { printf "%.2f\n", value / 1073741824 }'
}

to_int() {
    awk -v value="${1:-0}" 'BEGIN { printf "%d\n", value }'
}

collect_error_log_size() {
    local datanode_error_log_file="${TEST_IOTDB_PATH}/logs/log_datanode_error.log"
    local confignode_error_log_file="${TEST_IOTDB_PATH}/logs/log_confignode_error.log"
    local datanode_error_log_size=0
    local confignode_error_log_size=0

    datanode_error_log_size="$(du -sb "${datanode_error_log_file}" 2>/dev/null | awk '{print $1}')"
    confignode_error_log_size="$(du -sb "${confignode_error_log_file}" 2>/dev/null | awk '{print $1}')"
    printf '%s\n' "$(( ${datanode_error_log_size:-0} + ${confignode_error_log_size:-0} ))"
}

collect_monitor_data() {
    local ip="${1:-${TEST_IP}}"
    local metric_window=$((m_end_time - m_start_time))
    local max_num_thread_c=0
    local max_num_thread_d=0

    if [ "${metric_window}" -le 0 ]; then
        metric_window=1
    fi

    dataFileSize="$(get_single_index "sum(file_global_size{instance=~\"${ip}:9091\"})" "${m_end_time}")"
    dataFileSize="$(bytes_to_gib "${dataFileSize}")"
    numOfSe0Level="$(get_single_index "sum(file_global_count{instance=~\"${ip}:9091\",name=\"seq\"})" "${m_end_time}")"
    numOfUnse0Level="$(get_single_index "sum(file_global_count{instance=~\"${ip}:9091\",name=\"unseq\"})" "${m_end_time}")"
    max_num_thread_c="$(get_single_index "max_over_time(process_threads_count{instance=~\"${ip}:9081\"}[${metric_window}s])" "${m_end_time}")"
    max_num_thread_d="$(get_single_index "max_over_time(process_threads_count{instance=~\"${ip}:9091\"}[${metric_window}s])" "${m_end_time}")"
    maxNumofThread=$(( $(to_int "${max_num_thread_c}") + $(to_int "${max_num_thread_d}") ))
    maxNumofOpenFiles="$(get_single_index "max_over_time(file_count{instance=~\"${ip}:9091\",name=\"open_file_handlers\"}[${metric_window}s])" "${m_end_time}")"
    walFileSize="$(get_single_index "max_over_time(file_size{instance=~\"${ip}:9091\",name=~\"wal\"}[${metric_window}s])" "${m_end_time}")"
    walFileSize="$(bytes_to_gib "${walFileSize}")"
    errorLogSize="$(collect_error_log_size)"
}

copy_benchmark_config() {
    local config_source="$1"
    local config_target="${BM_PATH}/conf/config.properties"

    [ -f "${config_source}" ] || die "missing benchmark config: ${config_source}"
    safe_rm "${config_target}"
    cp -rf "${config_source}" "${config_target}"
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
    sudo mv "${TEST_IOTDB_PATH}" "${iotdb_target}"

    if [ -d "${csv_source}" ]; then
        sudo cp -rf "${csv_source}" "${backup_dir}/"
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
    local current_suite_type="$1"

    cat >> "${BM_PATH}/conf/config.properties" <<EOF
IoTDB_DIALECT_MODE=table
DB_NAME=${TREEVIEW_DB_NAME}
GROUP_NAME_PREFIX=${TREEVIEW_GROUP_NAME_PREFIX}
IoTDB_TABLE_NAME_PREFIX=${TREEVIEW_TABLE_NAME_PREFIX}
IoTDB_TABLE_NUMBER=1
EOF
}

treeview_cli_sql() {
    local sql="$1"
    local output=""
    local status=0
    local user="${IOTDB_READY_USER:-root}"
    local password="${IOTDB_READY_PASSWORD:-${IOTDB_PW}}"
    local -a cmd=(
        "${TEST_IOTDB_PATH}/sbin/start-cli.sh"
        -u "${user}"
        -pw "${password}"
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
}

query_log_dir_suffix() {
    local current_query="$1"

    if [ -n "${sensor_type:-}" ]; then
        printf '%s_%s\n' "${current_query}" "${sensor_type}"
    else
        printf '%s\n' "${current_query}"
    fi
}

parse_query_result() {
    local csv_file="$1"
    local query_label="$2"
    local throughput_line=""
    local latency_line=""

    [ -f "${csv_file}" ] || return 1

    throughput_line="$(
        awk -F, -v query_label="${query_label}" '
            function trim_field(value) {
                gsub(/^[ \t]+|[ \t]+$/, "", value)
                return value
            }
            trim_field($1) == query_label {
                for (i = 2; i <= 6; i++) {
                    value = trim_field($i)
                    printf "%s%s", value, (i == 6 ? ORS : OFS)
                }
                exit
            }
        ' OFS=$'\t' "${csv_file}"
    )"

    latency_line="$(
        awk -F, -v query_label="${query_label}" '
            function trim_field(value) {
                gsub(/^[ \t]+|[ \t]+$/, "", value)
                return value
            }
            trim_field($1) == query_label {
                count++
                if (count == 2) {
                    for (i = 2; i <= 12; i++) {
                        value = trim_field($i)
                        printf "%s%s", value, (i == 12 ? ORS : OFS)
                    }
                    exit
                }
            }
        ' OFS=$'\t' "${csv_file}"
    )"

    [ -n "${throughput_line}" ] || return 1
    [ -n "${latency_line}" ] || return 1

    IFS=$'\t' read -r okOperation okPoint failOperation failPoint throughput <<< "${throughput_line}"
    IFS=$'\t' read -r Latency MIN P10 P25 MEDIAN P75 P90 P95 P99 P999 MAX <<< "${latency_line}"
}

insert_result_row() {
    local protocol_code="$1"
    local insert_sql=""

    insert_sql=$(cat <<EOF
insert into ${RESULT_TABLE_NAME} (
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
    NULL,
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
    [ -d "${live_log_dir}" ] || mkdir -p "${live_log_dir}"
    [ -d "${BM_PATH}/data/csvOutput" ] || return 0

    safe_rm "${archived_log_dir}"
    cp -rf "${BM_PATH}/data/csvOutput" "${live_log_dir}/"
    mv "${live_log_dir}" "${archived_log_dir}"
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
                query_label="${QUERY_LABELS[${index}]}"
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
                    end_time="$(current_datetime)"
                    cost_time=-3
                    throughput=-3
                    insert_result_row "${protocol_code}"
                    operation_failed=1
                    stop_iotdb
                    sleep "${BENCHMARK_STOP_WAIT_SECONDS}"
                    cleanup_processes
                    continue
                fi

                mv_config_file "${current_suite_type}" "${current_query}" "${current_sensor_type}"
                append_tablemode_config_if_needed "${current_suite_type}"
                sleep 3

                for ((current_repeat = 1; current_repeat <= QUERY_REPEAT_COUNT; current_repeat++)); do
                    init_items
                    prepare_query_context "${current_suite_type}" "${current_query}" "${current_sensor_type}" "${current_repeat}" "${query_label}"
                    monitor_failed=0

                    start_benchmark
                    start_time="$(current_datetime)"
                    m_start_time="$(date +%s)"
                    sleep "${BENCHMARK_WARMUP_SECONDS}"

                    if ! monitor_test_status "${current_query}" "${query_label}"; then
                        monitor_failed=1
                    fi

                    m_end_time="$(date +%s)"
                    collect_monitor_data "${TEST_IP}"

                    csv_file="$(find_result_csv || true)"
                    if [ -z "${csv_file}" ] || ! parse_query_result "${csv_file}" "${query_label}"; then
                        log "failed to parse benchmark result; write fallback result"
                        [ -n "${end_time}" ] || end_time="$(current_datetime)"
                        cost_time=-2
                        throughput=-2
                        insert_result_row "${protocol_code}"
                        operation_failed=1
                        if [ "${monitor_failed}" -ne 0 ]; then
                            operation_failed=1
                        fi
                        continue
                    fi

                    [ -n "${end_time}" ] || end_time="$(current_datetime)"
                    cost_time=$(( $(datetime_to_epoch "${end_time}") - $(datetime_to_epoch "${start_time}") ))
                    insert_result_row "${protocol_code}"
                    log "${commit_id} ${ts_type} ${query_scope} repeat=${query_num} okPoint=${okPoint} latency=${Latency}ms"

                    if [ "${monitor_failed}" -ne 0 ]; then
                        operation_failed=1
                    fi
                done

                archive_query_logs "${current_query}"
                stop_iotdb
                sleep "${BENCHMARK_STOP_WAIT_SECONDS}"
                cleanup_processes
            done
        done

        log "${current_suite_type} finished"
        [ -d "${TEST_IOTDB_PATH}" ] && backup_test_data "${protocol_code}" "${current_suite_type}"
    done

    return "${operation_failed}"
}

mark_test_in_progress() {
    mkdir -p "${INIT_PATH}"
    printf 'ontesting\n' > "${INIT_PATH}/test_type_file"
}

restore_test_type_file() {
    mkdir -p "${INIT_PATH}"
    printf '%s\n' "${TEST_TYPE}" > "${INIT_PATH}/test_type_file"
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

    update_task_status "ontesting"
    log "start query test for commit ${commit_id}"

    test_date_time="$(date +%Y%m%d%H%M%S)"
    for protocol in "${PROTOCOL_LIST[@]}"; do
        if ! test_operation "${protocol}"; then
            task_failed=1
        fi
    done

    log "query test ${test_date_time} finished"
    if [ "${task_failed}" -eq 0 ]; then
        update_task_status "done"
        mark_older_commits_skip
    else
        update_task_status "RError"
    fi
}

main "$@"
