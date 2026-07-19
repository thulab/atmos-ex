#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
if shopt -oq posix; then
    exec bash "${BASH_SOURCE[0]}" "$@"
fi

set -u
set -o pipefail

readonly -a PROTOCOL_LIST=(223)
readonly -a TS_LIST=(common)
readonly -a API_LIST=(SESSION_BY_TABLET)

readonly TEST_IP="${DELETE_TEST_IP:-172.20.31.31}"
readonly TEST_TYPE="delete_test"

readonly BACKUP_PATH="${DELETE_TEST_BACKUP_PATH:-/nasdata/repository/${TEST_TYPE}}"
readonly INIT_PATH="${DELETE_TEST_INIT_PATH:-/data/atmos/zk_test}"
readonly ATMOS_PATH="${DELETE_TEST_ATMOS_PATH:-${INIT_PATH}/atmos-ex}"
readonly BM_PATH="${DELETE_TEST_BM_PATH:-${INIT_PATH}/iot-benchmark}"
readonly REPOS_PATH="${DELETE_TEST_REPOS_PATH:-/nasdata/repository/master}"
readonly BM_REPOS_PATH="${DELETE_TEST_BM_REPOS_PATH:-/nasdata/repository/iot-benchmark}"
readonly TEST_INIT_PATH="${DELETE_TEST_TEST_INIT_PATH:-/data/atmos}"
readonly TEST_IOTDB_PATH="${DELETE_TEST_IOTDB_PATH:-${TEST_INIT_PATH}/apache-iotdb}"

readonly -a PROTOCOL_CLASS=(
    ""
    "org.apache.iotdb.consensus.simple.SimpleConsensus"
    "org.apache.iotdb.consensus.ratis.RatisConsensus"
    "org.apache.iotdb.consensus.iot.IoTConsensus"
    "org.apache.iotdb.consensus.iot.IoTConsensusV2"
)

readonly METRIC_SERVER="${DELETE_TEST_METRIC_SERVER:-${METRIC_SERVER:-111.200.37.158:19090}}"
readonly ENABLE_BENCHMARK_VERSION_CHECK="${ENABLE_BENCHMARK_VERSION_CHECK:-1}"
readonly MONITOR_TIMEOUT_SECONDS="${MONITOR_TIMEOUT_SECONDS:-21600}"
readonly MONITOR_POLL_INTERVAL_SECONDS="${MONITOR_POLL_INTERVAL_SECONDS:-10}"
readonly IOTDB_READY_RETRIES="${IOTDB_READY_RETRIES:-10}"
readonly IOTDB_READY_INTERVAL_SECONDS="${IOTDB_READY_INTERVAL_SECONDS:-5}"
readonly STARTUP_GRACE_SECONDS="${STARTUP_GRACE_SECONDS:-10}"
readonly BENCHMARK_WARMUP_SECONDS="${BENCHMARK_WARMUP_SECONDS:-60}"
readonly BENCHMARK_STOP_WAIT_SECONDS="${BENCHMARK_STOP_WAIT_SECONDS:-30}"

readonly MYSQLHOSTNAME="${DELETE_TEST_MYSQL_HOSTNAME:-111.200.37.158}"
readonly MYSQL_PORT="${DELETE_TEST_MYSQL_PORT:-13306}"
readonly MYSQL_USERNAME="${DELETE_TEST_MYSQL_USERNAME:-iotdbatm}"
readonly MYSQL_PASSWORD="${ATMOS_DB_PASSWORD:-}"
readonly DBNAME="${DELETE_TEST_MYSQL_DBNAME:-QA_ATM}"
readonly TASK_TABLENAME="${DELETE_TEST_TASK_TABLENAME:-ex_commit_history}"

readonly TABLENAME="${DELETE_TEST_RESULT_TABLE:-ex_${TEST_TYPE}}"
readonly TABLENAME_T="${DELETE_TEST_RESULT_TABLE_T:-ex_${TEST_TYPE}_T}"
readonly IOTDB_PW="TimechoDB@2021"
readonly DEFAULT_DISK_ID="${DELETE_TEST_DEFAULT_DISK_ID:-sdb}"

result_table="${TABLENAME}"
disk_id_regex="^${DEFAULT_DISK_ID}$"
commit_id=""
author=""
commit_date_time=""
test_date_time=""
ts_type=""
data_type=""
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
maxCPULoad=0
avgCPULoad=0
maxDiskIOOpsRead=0
maxDiskIOOpsWrite=0
maxDiskIOSizeRead=0
maxDiskIOSizeWrite=0

IOTDB_READY_USER="${IOTDB_READY_USER:-}"
IOTDB_READY_PASSWORD="${IOTDB_READY_PASSWORD:-}"

readonly DELETE_CONF_DIR="${ATMOS_PATH}/conf/${TEST_TYPE}"
readonly WRITE_FIRST_CONFIG="${DELETE_CONF_DIR}/write_first.properties"
readonly WRITE_SECOND_CONFIG="${DELETE_CONF_DIR}/write_second.properties"

readonly CLI_HOST="127.0.0.1"
readonly CLI_PORT="6667"

readonly RANGE_START_MS=1767196800000
readonly JAN02_START_MS=1767283200000
readonly DELETE1_START_MS=1767369600000
readonly DELETE1_END_MS=1767456000000
readonly JAN08_START_MS=1767801600000
readonly JAN10_START_MS=1767974400000
readonly JAN14_START_MS=1768320000000
readonly JAN16_START_MS=1768492800000
readonly RANGE_END_MS=1768924800000

readonly BOUNDARY_BEFORE_DELETE_MS=1767369599000
readonly BOUNDARY_DELETE_START_MS=1767369600000
readonly BOUNDARY_DELETE_END_PREV_MS=1767455999000
readonly BOUNDARY_AFTER_DELETE_MS=1767456000000
readonly REINSERT1_MS=1767369600000
readonly REINSERT2_MS=1767369601000

readonly EXPECT_TOTAL_BEFORE_DELETE=1727998
readonly EXPECT_ONE_DAY=86400
readonly EXPECT_TWO_DAYS=172798
readonly EXPECT_AFTER_FIRST_DELETE=1468800
readonly EXPECT_COMPACTED_AFTER_COUNT=1123200
readonly EXPECT_COMPACTED_TOTAL=1296000

readonly COMPACTION_INITIAL_WAIT_SECONDS="${DELETE_TEST_COMPACTION_INITIAL_WAIT_SECONDS:-30}"
readonly COMPACTION_IDLE_CONFIRM_SECONDS="${DELETE_TEST_COMPACTION_IDLE_CONFIRM_SECONDS:-70}"
readonly COMPACTION_TIMEOUT_SECONDS="${DELETE_TEST_COMPACTION_TIMEOUT_SECONDS:-7200}"
readonly COMPACTION_POLL_SECONDS="${DELETE_TEST_COMPACTION_POLL_SECONDS:-60}"

pass_num=0
fail_num=0
remark=""
case_start_time=""
case_end_time=""
delete_cost_ms_1=0
delete_cost_ms_2=0
delete_cost_ms_3=0
pre_count=0
delete1_window_count=0
before_delete_window_count=0
after_delete_window_count=0
restart_delete1_window_count=0
compacted_delete1_window_count=0
compacted_before_count=0
compacted_after_count=0
compacted_total_count=0
write_tsfile_count=0
delete_mods_file_count=0
compacted_level0_tsfile_count=0
compacted_level1_tsfile_count=0
compacted_mods_file_count=0
write_ok_point=0
write_fail_point=0
write_ok_operation=0
write_fail_operation=0

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
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

check_password() {
    [ -n "${MYSQL_PASSWORD}" ] || die "ATMOS_DB_PASSWORD is not set, cannot connect to MySQL"
}

ensure_runtime_dependencies() {
    local cmd=""

    for cmd in awk cat cp curl date du find grep jq jps kill mkdir mysql rm sed tr wc; do
        require_command "${cmd}"
    done
}

append_iotdb_properties() {
    local properties_file="$1"

    cat >> "${properties_file}" <<EOF
enable_seq_space_compaction=false
enable_unseq_space_compaction=false
enable_cross_space_compaction=false
EOF
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
    path_is_safe "${path}" || die "refuse to remove unsafe path: ${path}"
    rm -rf -- "${path}"
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

mysql_exec() {
    local sql="$1"

    MYSQL_PWD="${MYSQL_PASSWORD}" mysql -N -B -h"${MYSQLHOSTNAME}" -P"${MYSQL_PORT}" -u"${MYSQL_USERNAME}" "${DBNAME}" -e "${sql}"
}

sql_quote() {
    local value="${1:-}"

    value="${value//\\/\\\\}"
    value="$(printf '%s' "${value}" | sed "s/'/''/g")"
    printf "'%s'" "${value}"
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
        log "sync benchmark directory to latest version"
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
    disk_id_regex="^${DEFAULT_DISK_ID}$"
    maxCPULoad=0
    avgCPULoad=0
    maxDiskIOOpsRead=0
    maxDiskIOOpsWrite=0
    maxDiskIOSizeRead=0
    maxDiskIOSizeWrite=0
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
        kill -TERM "${pid}" 2>/dev/null || true
        sleep 2
        kill -KILL "${pid}" 2>/dev/null || true
    done <<< "${pids}"

    log "${desc} process stopped"
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
            log "${current_name} completed"
            return 0
        fi

        now_epoch="$(date +%s)"
        elapsed=$((now_epoch - m_start_time))
        if [ "${elapsed}" -ge "${MONITOR_TIMEOUT_SECONDS}" ]; then
            end_time="$(current_datetime)"
            log "${current_name} timed out, writing stuck result"
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

count_data_files_by_name() {
    local file_name="$1"
    local data_dir="${TEST_IOTDB_PATH}/data/datanode/data"

    if [ ! -d "${data_dir}" ]; then
        printf '0\n'
        return 0
    fi

    find "${data_dir}" -type f -name "${file_name}" 2>/dev/null | wc -l | awk '{print $1}'
}

count_tsfiles() {
    count_data_files_by_name "*.tsfile"
}

count_mods_files() {
    count_data_files_by_name "*.mods2"
}

count_tsfiles_by_level() {
    local target_level="$1"
    local data_dir="${TEST_IOTDB_PATH}/data/datanode/data"

    if [ ! -d "${data_dir}" ]; then
        printf '0\n'
        return 0
    fi

    find "${data_dir}" -type f -name "*.tsfile" 2>/dev/null | awk -v target_level="${target_level}" '
        {
            file = $0
            sub(/^.*\//, "", file)
            sub(/\.tsfile$/, "", file)
            part_count = split(file, parts, "-")
            if (part_count < 3) {
                next
            }
            level = (part_count >= 4) ? parts[part_count - 1] : parts[part_count]
            if (level == target_level) {
                count++
            }
        }
        END {
            print count + 0
        }
    '
}

collect_file_stats_after_write() {
    write_tsfile_count="$(count_tsfiles)"
    log "write file stats: tsfile_count=${write_tsfile_count}"
}

collect_file_stats_after_delete() {
    delete_mods_file_count="$(count_mods_files)"
    log "delete file stats: mods_file_count=${delete_mods_file_count}"
}

collect_file_stats_after_compaction() {
    compacted_level0_tsfile_count="$(count_tsfiles_by_level 0)"
    compacted_level1_tsfile_count="$(count_tsfiles_by_level 1)"
    compacted_mods_file_count="$(count_mods_files)"
    log "compacted file stats: level0_tsfile_count=${compacted_level0_tsfile_count} level1_tsfile_count=${compacted_level1_tsfile_count} mods_file_count=${compacted_mods_file_count}"
}

collect_monitor_snapshot() {
    local ip="${1:-${TEST_IP}}"
    local metric_time="${2:-$(date +%s)}"

    dataFileSize="$(get_single_index "sum(file_global_size{instance=~\"${ip}:9091\"})" "${metric_time}")"
    dataFileSize="$(bytes_to_gib "${dataFileSize}")"
    numOfSe0Level="$(get_single_index "sum(file_global_count{instance=~\"${ip}:9091\",name=\"seq\"})" "${metric_time}")"
    numOfUnse0Level="$(get_single_index "sum(file_global_count{instance=~\"${ip}:9091\",name=\"unseq\"})" "${metric_time}")"
}

collect_monitor_window_data() {
    local ip="${1:-${TEST_IP}}"
    local window_start_time="${2:-${m_start_time}}"
    local window_end_time="${3:-${m_end_time}}"
    local metric_window=$((window_end_time - window_start_time))
    local max_num_thread_c=0
    local max_num_thread_d=0

    if [ "${metric_window}" -le 0 ]; then
        metric_window=1
    fi

    collect_monitor_snapshot "${ip}" "${window_end_time}"
    max_num_thread_c="$(get_single_index "max_over_time(process_threads_count{instance=~\"${ip}:9081\"}[${metric_window}s])" "${window_end_time}")"
    max_num_thread_d="$(get_single_index "max_over_time(process_threads_count{instance=~\"${ip}:9091\"}[${metric_window}s])" "${window_end_time}")"
    maxNumofThread=$(( $(to_int "${max_num_thread_c}") + $(to_int "${max_num_thread_d}") ))
    maxNumofOpenFiles="$(get_single_index "max_over_time(file_count{instance=~\"${ip}:9091\",name=\"open_file_handlers\"}[${metric_window}s])" "${window_end_time}")"
    walFileSize="$(get_single_index "max_over_time(file_size{instance=~\"${ip}:9091\",name=~\"wal\"}[${metric_window}s])" "${window_end_time}")"
    walFileSize="$(bytes_to_gib "${walFileSize}")"
    errorLogSize="$(collect_error_log_size)"
}

collect_resource_monitor_data() {
    local ip="${1:-${TEST_IP}}"
    local disk_id_pattern="${2:-}"
    local window_start_time="${3:-${m_start_time}}"
    local window_end_time="${4:-${m_end_time}}"
    local metric_window=$((window_end_time - window_start_time))

    if [ "${metric_window}" -le 0 ]; then
        metric_window=1
    fi

    collect_monitor_window_data "${ip}" "${window_start_time}" "${window_end_time}"
    maxCPULoad="$(get_single_index "max_over_time(sys_cpu_load{instance=~\"${ip}:9091\"}[${metric_window}s])" "${window_end_time}")"
    avgCPULoad="$(get_single_index "avg_over_time(sys_cpu_load{instance=~\"${ip}:9091\"}[${metric_window}s])" "${window_end_time}")"

    if [ -n "${disk_id_pattern}" ]; then
        maxDiskIOOpsRead="$(get_single_index "sum(rate(disk_io_ops{instance=~\"${ip}:9091\",disk_id=~\"${disk_id_pattern}\",type=~\"read\"}[${metric_window}s]))" "${window_end_time}")"
        maxDiskIOOpsWrite="$(get_single_index "sum(rate(disk_io_ops{instance=~\"${ip}:9091\",disk_id=~\"${disk_id_pattern}\",type=~\"write\"}[${metric_window}s]))" "${window_end_time}")"
        maxDiskIOSizeRead="$(get_single_index "sum(rate(disk_io_size{instance=~\"${ip}:9091\",disk_id=~\"${disk_id_pattern}\",type=~\"read\"}[${metric_window}s]))" "${window_end_time}")"
        maxDiskIOSizeWrite="$(get_single_index "sum(rate(disk_io_size{instance=~\"${ip}:9091\",disk_id=~\"${disk_id_pattern}\",type=~\"write\"}[${metric_window}s]))" "${window_end_time}")"
    else
        maxDiskIOOpsRead=0
        maxDiskIOOpsWrite=0
        maxDiskIOSizeRead=0
        maxDiskIOSizeWrite=0
    fi
}

get_iotdb_property_value() {
    local properties_file="$1"
    local property_key="$2"

    awk -v property_key="${property_key}" '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/\r$/, "", line)
            if (line ~ "^[[:space:]]*" property_key "[[:space:]]*=") {
                sub("^[[:space:]]*" property_key "[[:space:]]*=[[:space:]]*", "", line)
                last_value = line
            }
        }
        END {
            if (last_value != "") {
                print last_value
            }
        }
    ' "${properties_file}"
}

split_iotdb_path_list() {
    local value="$1"
    local item=""
    local -a items=()

    value="${value//;/,}"
    value="${value//\"/}"
    IFS=',' read -r -a items <<< "${value}"
    for item in "${items[@]}"; do
        item="$(trim "${item}")"
        [ -n "${item}" ] || continue
        printf '%s\n' "${item}"
    done
}

normalize_monitor_target_path() {
    local path="$1"

    path="$(trim "${path}")"
    path="${path%/}"

    case "${path}" in
        /*)
            printf '%s\n' "${path}"
            ;;
        *)
            printf '%s\n' "${TEST_IOTDB_PATH}/${path}"
            ;;
    esac
}

get_monitor_disk_target_paths() {
    local properties_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
    local property_key=""
    local property_value=""
    local raw_path=""
    local normalized_path=""
    local found_configured_path=0
    local -a property_keys=(dn_data_dirs dn_wal_dirs)

    if [ -f "${properties_file}" ]; then
        for property_key in "${property_keys[@]}"; do
            property_value="$(get_iotdb_property_value "${properties_file}" "${property_key}")"
            [ -n "${property_value}" ] || continue

            while IFS= read -r raw_path; do
                [ -n "${raw_path}" ] || continue
                normalized_path="$(normalize_monitor_target_path "${raw_path}")"
                [ -n "${normalized_path}" ] || continue
                printf '%s\n' "${normalized_path}"
                found_configured_path=1
            done < <(split_iotdb_path_list "${property_value}")
        done
    fi

    if [ "${found_configured_path}" -eq 0 ]; then
        printf '%s\n' "${TEST_IOTDB_PATH}/data"
    fi
}

find_existing_monitor_path() {
    local path="$1"

    while [ ! -e "${path}" ] && [ "${path}" != "/" ]; do
        path="${path%/*}"
        [ -n "${path}" ] || path="/"
    done

    [ -e "${path}" ] || return 1
    printf '%s\n' "${path}"
}

contains_value() {
    local expected="$1"
    shift
    local actual=""

    for actual in "$@"; do
        [ "${actual}" = "${expected}" ] && return 0
    done

    return 1
}

build_disk_id_regex() {
    local regex=""
    local current_disk_id=""

    for current_disk_id in "$@"; do
        if [ -z "${regex}" ]; then
            regex="${current_disk_id}"
        else
            regex="${regex}|${current_disk_id}"
        fi
    done

    [ -n "${regex}" ] || regex="${DEFAULT_DISK_ID}"
    printf '^(%s)$\n' "${regex}"
}

detect_disk_id_from_path() {
    local target_path="$1"
    local existing_path=""
    local source_device=""
    local resolved_device=""
    local parent_device=""

    command -v findmnt >/dev/null 2>&1 || return 1
    command -v lsblk >/dev/null 2>&1 || return 1

    existing_path="$(find_existing_monitor_path "${target_path}" || true)"
    [ -n "${existing_path}" ] || return 1

    source_device="$(findmnt -no SOURCE --target "${existing_path}" 2>/dev/null | awk 'NF { print; exit }')"
    [ -n "${source_device}" ] || return 1

    source_device="${source_device%%[*}"
    if command -v readlink >/dev/null 2>&1; then
        resolved_device="$(readlink -f "${source_device}" 2>/dev/null || printf '%s\n' "${source_device}")"
    else
        resolved_device="${source_device}"
    fi

    [ -b "${resolved_device}" ] || return 1

    while true; do
        parent_device="$(lsblk -ndo PKNAME "${resolved_device}" 2>/dev/null | awk 'NF { print; exit }')"
        [ -n "${parent_device}" ] || break
        resolved_device="/dev/${parent_device}"
    done

    printf '%s\n' "${resolved_device##*/}"
}

resolve_monitor_disk_id() {
    local target_path=""
    local detected_disk_id=""
    local -a detected_disk_ids=()
    local -a monitor_target_paths=()

    disk_id_regex="^${DEFAULT_DISK_ID}$"

    while IFS= read -r target_path; do
        [ -n "${target_path}" ] || continue
        monitor_target_paths+=("${target_path}")
        detected_disk_id="$(detect_disk_id_from_path "${target_path}" || true)"
        [ -n "${detected_disk_id}" ] || continue

        if ! contains_value "${detected_disk_id}" "${detected_disk_ids[@]:-}"; then
            detected_disk_ids+=("${detected_disk_id}")
        fi
    done < <(get_monitor_disk_target_paths)

    if [ "${#detected_disk_ids[@]:-}" -gt 0 ]; then
        disk_id_regex="$(build_disk_id_regex "${detected_disk_ids[@]:-}")"
        log "resolved monitor disk ids from ${monitor_target_paths[*]:-${TEST_IOTDB_PATH}}: ${detected_disk_ids[*]}"
    else
        log "failed to resolve monitor disk id from ${monitor_target_paths[*]:-${TEST_IOTDB_PATH}}, fallback to ${DEFAULT_DISK_ID}"
    fi
}

collect_monitor_data() {
    local ip="${1:-${TEST_IP}}"

    resolve_monitor_disk_id
    collect_resource_monitor_data "${ip}" "${disk_id_regex}" "${m_start_time}" "${m_end_time}"
}

copy_benchmark_config() {
    local config_source="$1"
    local config_target="${BM_PATH}/conf/config.properties"

    [ -f "${config_source}" ] || die "missing benchmark config: ${config_source}"
    safe_rm "${config_target}"
    cp -rf "${config_source}" "${config_target}"
}

mark_test_in_progress() {
    mkdir -p "${INIT_PATH}"
    printf 'ontesting\n' > "${INIT_PATH}/test_type_file"
}

restore_test_type_file() {
    mkdir -p "${INIT_PATH}"
    printf '%s\n' "${TEST_TYPE}" > "${INIT_PATH}/test_type_file"
}

change_root_password() {
    if "${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw "${IOTDB_PW}" -e "show cluster" >/dev/null 2>&1; then
        return 0
    fi

    "${TEST_IOTDB_PATH}/sbin/start-cli.sh" -e "ALTER USER root SET PASSWORD '${IOTDB_PW}'" >/dev/null 2>&1
}

parse_benchmark_result() {
    local csv_file="$1"
    local throughput_line=""
    local latency_line=""

    [ -f "${csv_file}" ] || return 1

    throughput_line="$(
        awk -F, '
            /^INGESTION/ {
                for (i = 2; i <= 6; i++) {
                    gsub(/^[ \t]+|[ \t]+$/, "", $i)
                    printf "%s%s", $i, (i == 6 ? ORS : OFS)
                }
                exit
            }
        ' OFS=$'\t' "${csv_file}"
    )"

    latency_line="$(
        awk -F, '
            /^INGESTION/ {
                count++
                if (count == 2) {
                    for (i = 2; i <= 12; i++) {
                        gsub(/^[ \t]+|[ \t]+$/, "", $i)
                        printf "%s%s", $i, (i == 12 ? ORS : OFS)
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

append_remark() {
    local message="$1"
    if [ -z "${remark}" ]; then
        remark="${message}"
    else
        remark="${remark}; ${message}"
    fi
}

sql_number() {
    local value="${1:-0}"
    if [[ "${value}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
        printf '%s' "${value}"
    else
        printf '0'
    fi
}

current_epoch_ms() {
    date +%s%3N
}

set_env() {
    local source_path="${REPOS_PATH}/${commit_id}/apache-iotdb"
    local delete_conf_path="${ATMOS_PATH}/conf/${TEST_TYPE}"
    local license_file="${delete_conf_path}/license"
    local env_file="${delete_conf_path}/env"

    if [ ! -d "${source_path}" ]; then
        append_remark "missing test version path: ${source_path}"
        return 1
    fi

    safe_rm "${TEST_IOTDB_PATH}"
    mkdir -p "${TEST_IOTDB_PATH}/activation"
    cp -rf "${source_path}/." "${TEST_IOTDB_PATH}/"
    cp -rf "${license_file}" "${TEST_IOTDB_PATH}/activation/"
    if [ -f "${license_file}" ]; then
        cp -rf "${license_file}" "${TEST_IOTDB_PATH}/license"
    else
        log "missing delete_test license, skip license copy: ${license_file}"
    fi
    if [ -f "${env_file}" ]; then
        cp -rf "${env_file}" "${TEST_IOTDB_PATH}/.env"
    else
        log "missing delete_test env, skip .env copy: ${env_file}"
    fi
}

prepare_benchmark_config() {
    local phase_config="$1"

    copy_benchmark_config "${phase_config}"
}

run_benchmark_write() {
    local phase_name="$1"
    local phase_config="$2"
    local csv_file=""
    local monitor_failed=0

    init_items
    prepare_benchmark_config "${phase_config}"
    start_benchmark
    start_time="$(current_datetime)"
    m_start_time="$(date +%s)"
    sleep "${BENCHMARK_WARMUP_SECONDS}"

    if ! monitor_test_status "${phase_name}" "INGESTION"; then
        monitor_failed=1
        append_remark "${phase_name} benchmark monitor timeout"
    fi

    m_end_time="$(date +%s)"
    csv_file="$(find_result_csv || true)"
    if [ -z "${csv_file}" ] || ! parse_benchmark_result "${csv_file}"; then
        sleep "${BENCHMARK_STOP_WAIT_SECONDS}"
        check_benchmark_pid
        append_remark "${phase_name} benchmark result parse failed"
        fail_num=$((fail_num + 1))
        return 1
    fi

    sleep "${BENCHMARK_STOP_WAIT_SECONDS}"
    check_benchmark_pid

    write_ok_point=$((write_ok_point + okPoint))
    write_ok_operation=$((write_ok_operation + okOperation))
    write_fail_point=$((write_fail_point + failPoint))
    write_fail_operation=$((write_fail_operation + failOperation))

    if [ "${monitor_failed}" -eq 0 ] && [ "${failOperation}" -eq 0 ] && [ "${failPoint}" -eq 0 ]; then
        pass_num=$((pass_num + 1))
        return 0
    fi

    fail_num=$((fail_num + 1))
    append_remark "${phase_name} benchmark has failed operations"
    return 1
}

run_iotdb_sql() {
    local sql="$1"
    "${TEST_IOTDB_PATH}/sbin/start-cli.sh" \
        -u root \
        -pw "${IOTDB_PW}" \
        -h "${CLI_HOST}" \
        -p "${CLI_PORT}" \
        -e "${sql}" 2>&1
}

extract_last_value() {
    awk -F'|' '
        /^\|/ {
            count = 0
            delete values
            for (i = 2; i < NF; i++) {
                value = $i
                gsub(/^[ \t]+|[ \t]+$/, "", value)
                if (value != "") {
                    values[++count] = value
                }
            }
            if (count == 0) {
                next
            }
            first = values[1]
            if (first == "Time" || first ~ /^count\(/ || first ~ /^root\./) {
                next
            }
            print values[count]
            exit
        }
    '
}

query_value() {
    local sql="$1"
    local output=""
    local value=""

    if ! output="$(run_iotdb_sql "${sql}")"; then
        append_remark "SQL failed: ${sql}"
        printf '\n'
        return 1
    fi

    value="$(printf '%s\n' "${output}" | extract_last_value)"
    printf '%s\n' "${value}"
}

execute_sql() {
    local label="$1"
    local sql="$2"
    local output=""

    if output="$(run_iotdb_sql "${sql}")"; then
        log "${label} succeeded"
        pass_num=$((pass_num + 1))
        return 0
    fi

    log "${label} failed: ${output}"
    append_remark "${label} failed"
    fail_num=$((fail_num + 1))
    return 1
}

execute_timed_sql() {
    local label="$1"
    local sql="$2"
    local result_var="$3"
    local begin_ms=0
    local end_ms=0
    local output=""

    begin_ms="$(current_epoch_ms)"
    if output="$(run_iotdb_sql "${sql}")"; then
        end_ms="$(current_epoch_ms)"
        printf -v "${result_var}" '%s' "$((end_ms - begin_ms))"
        log "${label} succeeded, cost_ms=$((end_ms - begin_ms))"
        pass_num=$((pass_num + 1))
        return 0
    fi

    end_ms="$(current_epoch_ms)"
    printf -v "${result_var}" '%s' "$((end_ms - begin_ms))"
    log "${label} failed: ${output}"
    append_remark "${label} failed"
    fail_num=$((fail_num + 1))
    return 1
}

assert_value() {
    local label="$1"
    local sql="$2"
    local expected="$3"
    local result_var="$4"
    local actual=""

    actual="$(query_value "${sql}")"
    printf -v "${result_var}" '%s' "${actual:-0}"

    if [ "${actual}" = "${expected}" ]; then
        log "${label} ok: ${actual}"
        pass_num=$((pass_num + 1))
        return 0
    fi

    log "${label} failed: expected ${expected}, actual ${actual:-EMPTY}"
    append_remark "${label} expected ${expected} actual ${actual:-EMPTY}"
    fail_num=$((fail_num + 1))
    return 1
}

assert_count_literal() {
    local label="$1"
    local begin_ms="$2"
    local end_ms="$3"
    local expected="$4"
    local result_var="$5"

    assert_value "${label}" \
        "select count(s_0) from root.test.g_0.d_0 where time >= ${begin_ms} and time < ${end_ms}" \
        "${expected}" \
        "${result_var}"
}

assert_point_count() {
    local label="$1"
    local point_ms="$2"
    local expected="$3"
    local scratch_var="delete_test_point_count"

    assert_value "${label}" \
        "select count(s_0) from root.test.g_0.d_0 where time = ${point_ms}" \
        "${expected}" \
        "${scratch_var}"
}

assert_point_value() {
    local label="$1"
    local point_ms="$2"
    local expected="$3"
    local scratch_var="delete_test_point_value"

    assert_value "${label}" \
        "select s_0 from root.test.g_0.d_0 where time = ${point_ms}" \
        "${expected}" \
        "${scratch_var}"
}

wait_for_iotdb_ready_with_auth() {
    local attempt=0
    local iotdb_state=""

    for ((attempt = 1; attempt <= IOTDB_READY_RETRIES; attempt++)); do
        iotdb_state="$(
            "${TEST_IOTDB_PATH}/sbin/start-cli.sh" \
                -u root \
                -pw "${IOTDB_PW}" \
                -h "${CLI_HOST}" \
                -p "${CLI_PORT}" \
                -e "show cluster" 2>/dev/null | grep -F 'Total line number = 2' || true
        )"
        if [ "${iotdb_state}" = "Total line number = 2" ]; then
            return 0
        fi
        sleep "${IOTDB_READY_INTERVAL_SECONDS}"
    done

    return 1
}

restart_iotdb_and_wait() {
    stop_iotdb
    sleep "${BENCHMARK_STOP_WAIT_SECONDS}"
    cleanup_processes
    start_iotdb
    sleep "${STARTUP_GRACE_SECONDS}"
    wait_for_iotdb_ready_with_auth
}

enable_compaction_config() {
    local properties_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"

    cat >> "${properties_file}" <<EOF
enable_seq_space_compaction=true
enable_unseq_space_compaction=true
enable_cross_space_compaction=true
EOF
}

wait_for_compaction_quiet() {
    local data_dir="${TEST_IOTDB_PATH}/data/datanode/data"
    local log_file="${TEST_IOTDB_PATH}/logs/log_datanode_compaction.log"
    local start_epoch=0
    local now_epoch=0
    local elapsed=0
    local active_count=0

    start_epoch="$(date +%s)"
    sleep "${COMPACTION_INITIAL_WAIT_SECONDS}"

    while true; do
        if [ -d "${data_dir}" ]; then
            active_count="$(find "${data_dir}" -name "*compaction.log" 2>/dev/null | wc -l | awk '{print $1}')"
        else
            active_count=0
        fi

        now_epoch="$(date +%s)"
        elapsed=$((now_epoch - start_epoch))
        log "compaction wait elapsed=${elapsed}s active_logs=${active_count}"

        if [ "${active_count}" -le 0 ] && [ -f "${log_file}" ]; then
            sleep "${COMPACTION_IDLE_CONFIRM_SECONDS}"
            if [ -d "${data_dir}" ]; then
                active_count="$(find "${data_dir}" -name "*compaction.log" 2>/dev/null | wc -l | awk '{print $1}')"
            else
                active_count=0
            fi

            if [ "${active_count}" -le 0 ] && [ -f "${log_file}" ]; then
                log "compaction completed"
                return 0
            fi
        fi

        if [ "${elapsed}" -ge "${COMPACTION_TIMEOUT_SECONDS}" ]; then
            append_remark "compaction wait timeout"
            return 1
        fi

        sleep "${COMPACTION_POLL_SECONDS}"
    done
}

run_consistency_checks_after_first_delete() {
    assert_count_literal "delete window after delete" "${DELETE1_START_MS}" "${DELETE1_END_MS}" 0 delete1_window_count
    assert_count_literal "before delete window" "${RANGE_START_MS}" "${DELETE1_START_MS}" "${EXPECT_TWO_DAYS}" before_delete_window_count
    assert_count_literal "after delete window" "${DELETE1_END_MS}" "${RANGE_END_MS}" "${EXPECT_AFTER_FIRST_DELETE}" after_delete_window_count
    assert_point_count "boundary before delete exists" "${BOUNDARY_BEFORE_DELETE_MS}" 1
    assert_point_count "boundary delete start absent" "${BOUNDARY_DELETE_START_MS}" 0
    assert_point_count "boundary delete end previous absent" "${BOUNDARY_DELETE_END_PREV_MS}" 0
    assert_point_count "boundary after delete exists" "${BOUNDARY_AFTER_DELETE_MS}" 1
}

run_reinsert_checks() {
    execute_sql "reinsert first deleted point" "insert into root.test.g_0.d_0(timestamp, s_0) values(${REINSERT1_MS}, true)"
    execute_sql "reinsert second deleted point" "insert into root.test.g_0.d_0(timestamp, s_0) values(${REINSERT2_MS}, true)"
    assert_point_value "reinsert first point visible" "${REINSERT1_MS}" true
    assert_point_value "reinsert second point visible" "${REINSERT2_MS}" true
}

run_restart_checks() {
    assert_count_literal "restart delete window count" "${DELETE1_START_MS}" "${DELETE1_END_MS}" 2 restart_delete1_window_count
    assert_point_count "restart boundary before delete exists" "${BOUNDARY_BEFORE_DELETE_MS}" 1
    assert_point_count "restart boundary delete end previous absent" "${BOUNDARY_DELETE_END_PREV_MS}" 0
    assert_point_count "restart boundary after delete exists" "${BOUNDARY_AFTER_DELETE_MS}" 1
    assert_point_value "restart reinsert first point visible" "${REINSERT1_MS}" true
    assert_point_value "restart reinsert second point visible" "${REINSERT2_MS}" true
}

run_compaction_checks() {
    assert_count_literal "compacted delete window count" "${DELETE1_START_MS}" "${DELETE1_END_MS}" 2 compacted_delete1_window_count
    assert_count_literal "compacted before count" "${RANGE_START_MS}" "${DELETE1_START_MS}" "${EXPECT_TWO_DAYS}" compacted_before_count
    assert_count_literal "compacted after count" "${DELETE1_END_MS}" "${RANGE_END_MS}" "${EXPECT_COMPACTED_AFTER_COUNT}" compacted_after_count
    assert_count_literal "compacted total count" "${RANGE_START_MS}" "${RANGE_END_MS}" "${EXPECT_COMPACTED_TOTAL}" compacted_total_count
}

insert_delete_result_row() {
    local protocol_code="$1"
    local insert_sql=""

    insert_sql=$(cat <<EOF
insert into ${result_table} (
    commit_date_time,test_date_time,commit_id,author,protocol,pass_num,fail_num,
    write_ok_point,write_ok_operation,write_fail_point,write_fail_operation,
    delete_cost_ms_1,delete_cost_ms_2,delete_cost_ms_3,
    pre_count,delete1_window_count,before_delete_window_count,after_delete_window_count,
    restart_delete1_window_count,compacted_delete1_window_count,compacted_before_count,compacted_after_count,compacted_total_count,
    write_tsfile_count,delete_mods_file_count,compacted_level0_tsfile_count,compacted_level1_tsfile_count,compacted_mods_file_count,
    numOfSe0Level,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,walFileSize,
    avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,
    start_time,end_time,cost_time,remark
) values (
    ${commit_date_time},
    ${test_date_time},
    $(sql_quote "${commit_id}"),
    $(sql_quote "${author}"),
    ${protocol_code},
    ${pass_num},
    ${fail_num},
    $(sql_number "${write_ok_point}"),
    $(sql_number "${write_ok_operation}"),
    $(sql_number "${write_fail_point}"),
    $(sql_number "${write_fail_operation}"),
    $(sql_number "${delete_cost_ms_1}"),
    $(sql_number "${delete_cost_ms_2}"),
    $(sql_number "${delete_cost_ms_3}"),
    $(sql_number "${pre_count}"),
    $(sql_number "${delete1_window_count}"),
    $(sql_number "${before_delete_window_count}"),
    $(sql_number "${after_delete_window_count}"),
    $(sql_number "${restart_delete1_window_count}"),
    $(sql_number "${compacted_delete1_window_count}"),
    $(sql_number "${compacted_before_count}"),
    $(sql_number "${compacted_after_count}"),
    $(sql_number "${compacted_total_count}"),
    $(sql_number "${write_tsfile_count}"),
    $(sql_number "${delete_mods_file_count}"),
    $(sql_number "${compacted_level0_tsfile_count}"),
    $(sql_number "${compacted_level1_tsfile_count}"),
    $(sql_number "${compacted_mods_file_count}"),
    $(sql_number "${numOfSe0Level}"),
    $(sql_number "${numOfUnse0Level}"),
    $(sql_number "${dataFileSize}"),
    $(sql_number "${maxNumofOpenFiles}"),
    $(sql_number "${maxNumofThread}"),
    $(sql_number "${errorLogSize}"),
    $(sql_number "${walFileSize}"),
    $(sql_number "${avgCPULoad}"),
    $(sql_number "${maxCPULoad}"),
    $(sql_number "${maxDiskIOSizeRead}"),
    $(sql_number "${maxDiskIOSizeWrite}"),
    $(sql_number "${maxDiskIOOpsRead}"),
    $(sql_number "${maxDiskIOOpsWrite}"),
    $(sql_quote "${case_start_time}"),
    $(sql_quote "${case_end_time}"),
    $(sql_number "${cost_time}"),
    $(sql_quote "${remark}")
)
EOF
)

    mysql_exec "${insert_sql}"
}

test_operation() {
    local protocol_code="$1"

    log "start delete consistency test, protocol=${protocol_code}"
    pass_num=0
    fail_num=0
    remark=""
    write_tsfile_count=0
    delete_mods_file_count=0
    compacted_level0_tsfile_count=0
    compacted_level1_tsfile_count=0
    compacted_mods_file_count=0
    case_start_time="$(current_datetime)"
    cleanup_processes
    if ! set_env; then
        fail_num=$((fail_num + 1))
        case_end_time="$(current_datetime)"
        cost_time=$(( $(datetime_to_epoch "${case_end_time}") - $(datetime_to_epoch "${case_start_time}") ))
        insert_delete_result_row "${protocol_code}"
        cleanup_processes
        return 1
    fi
    modify_iotdb_config

    if ! set_protocol_class "${protocol_code}"; then
        append_remark "invalid protocol ${protocol_code}"
        fail_num=$((fail_num + 1))
        return 1
    fi

    start_iotdb
    sleep "${STARTUP_GRACE_SECONDS}"
    if ! wait_for_iotdb_ready; then
        append_remark "IoTDB startup failed before password change"
        fail_num=$((fail_num + 1))
        case_end_time="$(current_datetime)"
        cost_time=$(( $(datetime_to_epoch "${case_end_time}") - $(datetime_to_epoch "${case_start_time}") ))
        insert_delete_result_row "${protocol_code}"
        cleanup_processes
        return 1
    fi

    if ! change_root_password; then
        append_remark "root password change failed"
        fail_num=$((fail_num + 1))
        case_end_time="$(current_datetime)"
        cost_time=$(( $(datetime_to_epoch "${case_end_time}") - $(datetime_to_epoch "${case_start_time}") ))
        insert_delete_result_row "${protocol_code}"
        cleanup_processes
        return 1
    fi

    run_benchmark_write "delete first write" "${WRITE_FIRST_CONFIG}" || true
    execute_sql "flush after first write" "flush"
    run_benchmark_write "delete second write" "${WRITE_SECOND_CONFIG}" || true
    execute_sql "flush after second write" "flush"
    collect_file_stats_after_write

    m_start_time="$(date +%s)"
    assert_count_literal "count before delete" "${RANGE_START_MS}" "${RANGE_END_MS}" "${EXPECT_TOTAL_BEFORE_DELETE}" pre_count

    execute_timed_sql "delete Jan03 window" \
        "delete from root.test.g_0.d_0.s_0 where time >= ${DELETE1_START_MS} and time < ${DELETE1_END_MS}" \
        delete_cost_ms_1
    execute_sql "flush after first delete" "flush"
    run_consistency_checks_after_first_delete
    run_reinsert_checks

    if restart_iotdb_and_wait; then
        pass_num=$((pass_num + 1))
        run_restart_checks
    else
        append_remark "restart check startup failed"
        fail_num=$((fail_num + 1))
    fi

    execute_timed_sql "delete Jan08 Jan10 window" \
        "delete from root.test.g_0.d_0.s_0 where time >= ${JAN08_START_MS} and time < ${JAN10_START_MS}" \
        delete_cost_ms_2
    execute_timed_sql "delete Jan14 Jan16 window" \
        "delete from root.test.g_0.d_0.s_0 where time >= ${JAN14_START_MS} and time < ${JAN16_START_MS}" \
        delete_cost_ms_3
    execute_sql "flush after later deletes" "flush"
    collect_file_stats_after_delete

    enable_compaction_config
    if restart_iotdb_and_wait; then
        pass_num=$((pass_num + 1))
        if ! wait_for_compaction_quiet; then
            fail_num=$((fail_num + 1))
        fi
        execute_sql "flush after compaction wait" "flush"
        collect_file_stats_after_compaction
        run_compaction_checks
    else
        append_remark "compaction restart failed"
        fail_num=$((fail_num + 1))
    fi

    m_end_time="$(date +%s)"
    collect_monitor_data "${TEST_IP}"
    case_end_time="$(current_datetime)"
    cost_time=$(( $(datetime_to_epoch "${case_end_time}") - $(datetime_to_epoch "${case_start_time}") ))
    insert_delete_result_row "${protocol_code}"

    stop_iotdb
    sleep "${BENCHMARK_STOP_WAIT_SECONDS}"
    cleanup_processes

    [ "${fail_num}" -eq 0 ]
}

main() {
    local protocol=""
    local task_failed=0

    trap restore_test_type_file EXIT

    ensure_runtime_dependencies
    check_password
    if [ "${ENABLE_BENCHMARK_VERSION_CHECK}" = "1" ]; then
        check_benchmark_version
    fi
    mark_test_in_progress
    if ! fetch_next_commit; then
        sleep 60
        return 0
    fi

    update_task_status "ontesting"
    if [ "${author}" = "Timecho" ]; then
        result_table="${TABLENAME_T}"
    else
        result_table="${TABLENAME}"
    fi

    test_date_time="$(date +%Y%m%d%H%M%S)"
    for protocol in "${PROTOCOL_LIST[@]}"; do
        if ! test_operation "${protocol}"; then
            task_failed=1
        fi
    done

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
