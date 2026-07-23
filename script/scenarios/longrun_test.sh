#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
if shopt -oq posix; then
    exec bash "${BASH_SOURCE[0]}" "$@"
fi

set -u
set -o pipefail

TEST_IP="11.101.17.112"
readonly TIMECHO_LONGRUN_IP="11.101.17.112"
readonly IOTDB_PASSWORD="TimechoDB@2021"
readonly TEST_TYPE="longrun_test"
readonly DATA_TYPE="unseq_rw"
readonly DEFAULT_QUERY_MAX_TIME="2020-12-31 23:00:00"
readonly DEFAULT_BENCHMARK_START_TIME="2021-01-01T00:00:00+08:00"
readonly LONGRUN_TTL_KEEP_DAYS="${LONGRUN_TTL_KEEP_DAYS:-40}"

readonly INIT_PATH="/data/atmos/zk_test"
readonly ATMOS_PATH="${INIT_PATH}/atmos-ex"
readonly BM_PATH_TREE="${INIT_PATH}/iot-benchmark_tree"
readonly BM_PATH_TABLE="${INIT_PATH}/iot-benchmark_table"
readonly BM_PATH_TREE_QUERY="${INIT_PATH}/iot-benchmark_tree_query"
readonly BM_PATH_TABLE_QUERY="${INIT_PATH}/iot-benchmark_table_query"
readonly BACKUP_PATH="/nasdata/repository/${TEST_TYPE}"
readonly REPOS_PATH="/nasdata/repository/master"
readonly BM_REPOS_PATH="/nasdata/repository/iot-benchmark"

readonly TEST_INIT_PATH="/data/atmos"
readonly TEST_IOTDB_PATH="${TEST_INIT_PATH}/apache-iotdb"
readonly LONGRUN_START_TIME_LOG="${TEST_IOTDB_PATH}/logs/longrun_start_time_debug.log"
readonly IOTDB_HDD_DATA_DIR="/data/data_dir"
readonly IOTDB_SSD_DATA_DIR="/ssd_dcpmm/data_dir"
readonly IOTDB_DATA_DIRS="${IOTDB_HDD_DATA_DIR},${IOTDB_SSD_DATA_DIR}"
readonly IOTDB_CONF_DIR="/ssd_dcpmm/conf_dir"

readonly -a PROTOCOL_CLASS=(
    ""
    "org.apache.iotdb.consensus.simple.SimpleConsensus"
    "org.apache.iotdb.consensus.ratis.RatisConsensus"
    "org.apache.iotdb.consensus.iot.IoTConsensus"
    "org.apache.iotdb.consensus.iot.IoTConsensusV2"
)
readonly -a PROTOCOL_LIST=(223)
readonly -a OP_TYPE_LABELS=(
    PRECISE_POINT
    TIME_RANGE
    VALUE_RANGE
    AGG_RANGE
    AGG_VALUE
    AGG_RANGE_VALUE
    GROUP_BY
    LATEST_POINT
    RANGE_QUERY_DESC
    VALUE_RANGE_QUERY_DESC
    GROUP_BY_DESC
    VERIFICATION_QUERY
    DEVICE_QUERY
    SET_OPERATION
)
readonly -a OP_TYPE_NAMES=(
    PRECISE_POINT
    TIME_RANGE
    VALUE_RANGE
    AGG_RANGE
    AGG_VALUE
    AGG_RANGE_VALUE
    GROUP_BY
    LATEST_POINT
    RANGE_QUERY_DESC
    VALUE_RANGE_QUERY_DESC
    GROUP_BY_DESC
    VERIFICATION_QUERY
    DEVICE_QUERY
    SET_OPERATION
)

readonly MYSQL_HOST="111.200.37.158"
readonly MYSQL_PORT="13306"
readonly MYSQL_USERNAME="iotdbatm"
readonly MYSQL_PASSWORD="${ATMOS_DB_PASSWORD:-}"
readonly DBNAME="QA_ATM"
readonly TABLENAME="ex_${TEST_TYPE}"
readonly TABLENAME_T="ex_${TEST_TYPE}_T"
readonly TASK_TABLENAME="ex_commit_history"

readonly METRIC_SERVER="111.200.37.158:19090"
readonly DEFAULT_DISK_ID="sdb"
readonly MONITOR_TIMEOUT_SECONDS=432000
readonly MONITOR_POLL_INTERVAL_SECONDS=10
readonly IOTDB_READY_RETRIES=10
readonly IOTDB_READY_INTERVAL_SECONDS=5
readonly STARTUP_GRACE_SECONDS=10
readonly BENCHMARK_WARMUP_SECONDS=60
readonly BENCHMARK_STOP_WAIT_SECONDS=30

result_table="${TABLENAME}"
AUTHOR_FILTER_SQL="author != 'Timecho'"
commit_id=""
author=""
commit_date_time=""
test_date_time=""

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
start_time=""
end_time=""
cost_time=0
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
m_start_time=0
m_end_time=0
TREE_QUERY_MAX_TIME="${DEFAULT_QUERY_MAX_TIME}"
TABLE_QUERY_MAX_TIME="${DEFAULT_QUERY_MAX_TIME}"
QUERY_MAX_TIME="${DEFAULT_QUERY_MAX_TIME}"
BENCHMARK_START_TIME="${DEFAULT_BENCHMARK_START_TIME}"
LONGRUN_TTL_MS=0

# 功能：探测当前主机、磁盘或运行环境信息
detect_local_ips() {
    {
        hostname -I 2>/dev/null || true
        ifconfig -a 2>/dev/null | grep inet | grep -v 127.0.0.1 | grep -v inet6 | awk '{print $2}' | tr -d "addr:" || true
    } | tr ' ' '\n' | awk 'NF && !seen[$0]++'
}

# 功能：根据本机地址选择长稳测试的数据表和任务过滤条件
init_longrun_route() {
    local local_ips=""
    local first_ip=""

    local_ips="$(detect_local_ips)"
    first_ip="$(printf '%s\n' "${local_ips}" | awk 'NF {print; exit}')"

    if printf '%s\n' "${local_ips}" | grep -Fxq "${TIMECHO_LONGRUN_IP}"; then
        AUTHOR_FILTER_SQL="author = 'Timecho'"
        result_table="${TABLENAME_T}"
        TEST_IP="${TIMECHO_LONGRUN_IP}"
    else
        AUTHOR_FILTER_SQL="author != 'Timecho'"
        result_table="${TABLENAME}"
        if [ -n "${first_ip}" ]; then
            TEST_IP="${first_ip}"
        fi
    fi

    log "route: AUTHOR_FILTER_SQL=${AUTHOR_FILTER_SQL}, result_table=${result_table}, TEST_IP=${TEST_IP}"
}

# 功能：同步本地与目标位置的版本或目录内容
sync_benchmark_path() {
    sync_benchmark_distribution "${BM_REPOS_PATH}" "$1"
    return
    local target_path="$1"
    local source_version=""
    local target_version=""

    [ -f "${BM_REPOS_PATH}/git.properties" ] || die "missing benchmark git.properties: ${BM_REPOS_PATH}/git.properties"
    source_version="$(git_commit_abbrev "${BM_REPOS_PATH}/git.properties")"
    [ -n "${source_version}" ] || die "failed to read benchmark version."

    if [ -f "${target_path}/git.properties" ]; then
        target_version="$(git_commit_abbrev "${target_path}/git.properties")"
    fi

    if [ ! -d "${target_path}" ] || [ "${target_version}" != "${source_version}" ]; then
        log "sync benchmark to ${target_path}"
        safe_rm "${target_path}"
        cp -rf -- "${BM_REPOS_PATH}" "${target_path}"
    fi
}

# 功能：比较本地与仓库版本并同步 IoT-Benchmark
check_benchmark_version() {
    sync_benchmark_path "${BM_PATH_TREE}"
    sync_benchmark_path "${BM_PATH_TABLE}"
    sync_benchmark_path "${BM_PATH_TREE_QUERY}"
    sync_benchmark_path "${BM_PATH_TABLE_QUERY}"
}

# 功能：重置当前测试用例使用的指标和运行状态
init_items() {
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
    start_time=""
    end_time=""
    cost_time=0
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
    m_start_time=0
    m_end_time=0
    TREE_QUERY_MAX_TIME="${DEFAULT_QUERY_MAX_TIME}"
    TABLE_QUERY_MAX_TIME="${DEFAULT_QUERY_MAX_TIME}"
    QUERY_MAX_TIME="${DEFAULT_QUERY_MAX_TIME}"
    BENCHMARK_START_TIME="${DEFAULT_BENCHMARK_START_TIME}"
    LONGRUN_TTL_MS=0
}

# 功能：重置当前测试使用的指标或运行状态
reset_benchmark_metrics() {
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
}

# 功能：设置当前测试使用的配置值或运行状态
set_negative_benchmark_metrics() {
    local value="$1"
    okPoint="${value}"
    okOperation="${value}"
    failPoint="${value}"
    failOperation="${value}"
    throughput="${value}"
    Latency="${value}"
    MIN="${value}"
    P10="${value}"
    P25="${value}"
    MEDIAN="${value}"
    P75="${value}"
    P90="${value}"
    P95="${value}"
    P99="${value}"
    P999="${value}"
    MAX="${value}"
}

# 功能：准备当前测试所需的本地安装目录与运行环境
set_env() {
    local source_path="${REPOS_PATH}/${commit_id}/apache-iotdb"

    [ -d "${source_path}" ] || die "missing tested IoTDB path: ${source_path}"
    safe_rm "${TEST_IOTDB_PATH}"
    mkdir -p "${TEST_IOTDB_PATH}/activation"
    cp -rf -- "${source_path}/." "${TEST_IOTDB_PATH}/"
    copy_if_exists "${ATMOS_PATH}/conf/${TEST_TYPE}/license" "${TEST_IOTDB_PATH}/activation/" "license"
    copy_if_exists "${ATMOS_PATH}/conf/${TEST_TYPE}/env" "${TEST_IOTDB_PATH}/.env" "env"
    mkdir -p "${IOTDB_HDD_DATA_DIR}" "${IOTDB_SSD_DATA_DIR}" "${IOTDB_CONF_DIR}"
}

# 功能：按当前测试场景修改 IoTDB 配置
modify_iotdb_config() {
    local datanode_env="${TEST_IOTDB_PATH}/conf/datanode-env.sh"
    local properties_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"

    [ -f "${datanode_env}" ] || die "missing config file: ${datanode_env}"
    [ -f "${properties_file}" ] || die "missing config file: ${properties_file}"
    sed -i 's/^#\?ON_HEAP_MEMORY=.*$/ON_HEAP_MEMORY="40G"/' "${datanode_env}"

    cat >> "${properties_file}" <<EOF
enable_seq_space_compaction=true
enable_unseq_space_compaction=true
enable_cross_space_compaction=true
cluster_name=${TEST_TYPE}
cn_system_dir=${IOTDB_CONF_DIR}/confignode/system
cn_consensus_dir=${IOTDB_CONF_DIR}/confignode/consensus
cn_pipe_receiver_file_dir=${IOTDB_CONF_DIR}/confignode/system/pipe/receiver
dn_system_dir=${IOTDB_SSD_DATA_DIR}/datanode/system
dn_data_dirs=${IOTDB_DATA_DIRS}
dn_consensus_dir=${IOTDB_SSD_DATA_DIR}/datanode/consensus
dn_wal_dirs=${IOTDB_SSD_DATA_DIR}/datanode/wal
dn_tracing_dir=${IOTDB_SSD_DATA_DIR}/datanode/tracing
dn_sync_dir=${IOTDB_SSD_DATA_DIR}/datanode/sync
sort_tmp_dir=${IOTDB_SSD_DATA_DIR}/datanode/tmp
dn_pipe_receiver_file_dirs=${IOTDB_SSD_DATA_DIR}/datanode/system/pipe/receiver
iot_consensus_v2_receiver_file_dirs=${IOTDB_SSD_DATA_DIR}/datanode/system/pipe/consensus/receiver
iot_consensus_v2_deletion_file_dir=${IOTDB_SSD_DATA_DIR}/datanode/system/pipe/consensus/deletion
remote_tsfile_cache_dirs=${IOTDB_SSD_DATA_DIR}/datanode/data/cache
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
}

# 功能：根据协议编号设置各共识组使用的协议实现
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

# 功能：启动当前场景中的 IoTDB 服务
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

# 功能：停止当前场景中的 IoTDB 服务
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

# 功能：轮询 IoTDB 直到服务达到可查询状态
wait_for_iotdb_ready() {
    local attempt=0
    local cli_password=""
    local iotdb_state=""

    for ((attempt = 1; attempt <= IOTDB_READY_RETRIES; attempt++)); do
        for cli_password in "" "root" "${IOTDB_PASSWORD}"; do
            if [ -z "${cli_password}" ]; then
                iotdb_state="$("${TEST_IOTDB_PATH}/sbin/start-cli.sh" -e "show cluster" 2>/dev/null | grep -F 'Total line number = 2' || true)"
            else
                iotdb_state="$("${TEST_IOTDB_PATH}/sbin/start-cli.sh" -pw "${cli_password}" -e "show cluster" 2>/dev/null | grep -F 'Total line number = 2' || true)"
            fi
            [ "${iotdb_state}" = "Total line number = 2" ] && return 0
        done
        sleep "${IOTDB_READY_INTERVAL_SECONDS}"
    done

    return 1
}

# 功能：检测并设置 IoTDB root 用户密码
change_root_password() {
    if "${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw "${IOTDB_PASSWORD}" -e "show cluster" >/dev/null 2>&1; then
        return 0
    fi

    "${TEST_IOTDB_PATH}/sbin/start-cli.sh" -e "ALTER USER root SET PASSWORD '${IOTDB_PASSWORD}'" >/dev/null 2>&1
}

# 功能：记录长稳测试当前使用的 Benchmark 起始时间
longrun_start_time_log() {
    local log_line=""

    log_line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    mkdir -p "${TEST_IOTDB_PATH}/logs"
    printf '%s\n' "${log_line}" >> "${LONGRUN_START_TIME_LOG}"
    printf '%s\n' "${log_line}" >&2
}

# 功能：读取并返回指定配置、路径或指标值
get_benchmark_config_value() {
    local config_file="$1"
    local config_key="$2"

    awk -F= -v key="${config_key}" '
        /^[[:space:]]*#/ { next }
        {
            current_key = $1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", current_key)
        }
        current_key == key {
            value = substr($0, index($0, "=") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' "${config_file}"
}

# 功能：读取并返回指定配置、路径或指标值
get_benchmark_config_value_or_default() {
    local config_file="$1"
    local config_key="$2"
    local default_value="$3"
    local config_value=""

    config_value="$(get_benchmark_config_value "${config_file}" "${config_key}")"
    if [ -n "${config_value}" ]; then
        printf '%s\n' "${config_value}"
    else
        printf '%s\n' "${default_value}"
    fi
}

# 功能：读取并返回指定配置、路径或指标值
get_iotdb_timestamp_precision() {
    local properties_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
    local timestamp_precision=""

    if [ -f "${properties_file}" ]; then
        timestamp_precision="$(
            awk -F= '
                /^[[:space:]]*#/ { next }
                {
                    key = $1
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
                }
                key == "timestamp_precision" {
                    value = $2
                }
                END {
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                    print value
                }
            ' "${properties_file}"
        )"
    fi

    [ -n "${timestamp_precision}" ] || timestamp_precision="ms"
    printf '%s\n' "${timestamp_precision}"
}

# 功能：查询并返回当前场景需要的数据或状态
query_last_sensor_time() {
    local config_file="$1"
    local db_name=""
    local group_name_prefix=""
    local device_name_prefix=""
    local sensor_name_prefix=""
    local sensor_name=""
    local query_sql=""
    local query_result=""
    local cli_output=""
    local cli_status=0

    db_name="$(get_benchmark_config_value_or_default "${config_file}" "DB_NAME" "test")"
    group_name_prefix="$(get_benchmark_config_value_or_default "${config_file}" "GROUP_NAME_PREFIX" "g_")"
    device_name_prefix="$(get_benchmark_config_value_or_default "${config_file}" "DEVICE_NAME_PREFIX" "d_")"
    sensor_name_prefix="$(get_benchmark_config_value_or_default "${config_file}" "SENSOR_NAME_PREFIX" "s_")"
    sensor_name="${sensor_name_prefix}0"
    query_sql="select max_time(${sensor_name}) from root.${db_name}.${group_name_prefix}0.${device_name_prefix}0"

    longrun_start_time_log "query config=${config_file} db=${db_name} group_prefix=${group_name_prefix} device_prefix=${device_name_prefix} sensor=${sensor_name}"
    longrun_start_time_log "query sql=${query_sql}"

    cli_output="$("${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw "${IOTDB_PASSWORD}" -sql_dialect tree -h 127.0.0.1 -p 6667 -e "${query_sql}" 2>&1)"
    cli_status=$?
    longrun_start_time_log "query cli_status=${cli_status}"
    longrun_start_time_log "query raw_output_begin"
    printf '%s\n' "${cli_output}" >> "${LONGRUN_START_TIME_LOG}"
    printf '%s\n' "${cli_output}" >&2
    longrun_start_time_log "query raw_output_end"

    query_result="$(
        printf '%s\n' "${cli_output}" | awk -F'|' '
            /^\+/ { next }
            /Total line number/ { next }
            NF >= 3 {
                value = $2
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                if (value == "" || value ~ /^max_time/) {
                    next
                }
                print value
                exit
            }
        '
    )"
    longrun_start_time_log "query parsed_last_sensor_time=${query_result}"
    printf '%s\n' "${query_result}"
}

# 功能：检查或处理 IoTDB 服务状态与时间配置
iotdb_time_to_epoch() {
    local raw_timestamp="$1"
    local timestamp_precision="$2"

    if [[ "${raw_timestamp}" =~ ^[0-9]+$ ]]; then
        case "${timestamp_precision}" in
            ns) printf '%s\n' $((raw_timestamp / 1000000000)) ;;
            us) printf '%s\n' $((raw_timestamp / 1000000)) ;;
            s) printf '%s\n' "${raw_timestamp}" ;;
            ms|*) printf '%s\n' $((raw_timestamp / 1000)) ;;
        esac
    else
        date -d "${raw_timestamp}" +%s
    fi
}

# 功能：将输入值格式化为目标展示或配置格式
format_iotdb_time() {
    local raw_timestamp="$1"
    local timestamp_precision="$2"
    local offset_seconds="${3:-0}"
    local output_format="${4:-+%Y-%m-%dT%H:%M:%S%:z}"
    local target_epoch=0

    target_epoch="$(iotdb_time_to_epoch "${raw_timestamp}" "${timestamp_precision}" 2>/dev/null)" || return 1
    target_epoch=$((target_epoch + offset_seconds))

    date -d "@${target_epoch}" "${output_format}"
}

# 功能：计算当前测试所需的时间、大小或统计值
calculate_ttl_ms() {
    local raw_timestamp="$1"
    local timestamp_precision="$2"
    local max_time_epoch=0
    local now_epoch=0
    local keep_seconds=0
    local ttl_seconds=0

    [[ "${LONGRUN_TTL_KEEP_DAYS}" =~ ^[0-9]+$ ]] || return 1
    max_time_epoch="$(iotdb_time_to_epoch "${raw_timestamp}" "${timestamp_precision}" 2>/dev/null)" || return 1
    now_epoch="$(date +%s)"
    keep_seconds=$((LONGRUN_TTL_KEEP_DAYS * 24 * 60 * 60))
    ttl_seconds=$((now_epoch - max_time_epoch + keep_seconds))
    [ "${ttl_seconds}" -gt 0 ] || ttl_seconds="${keep_seconds}"

    printf '%s\n' $((ttl_seconds * 1000))
}

# 功能：设置当前测试使用的配置值或运行状态
set_result_max_time() {
    local formatted_max_time="$1"

    TREE_QUERY_MAX_TIME="${formatted_max_time}"
    TABLE_QUERY_MAX_TIME="${formatted_max_time}"
    QUERY_MAX_TIME="${formatted_max_time}"
}

# 功能：读取并返回指定配置、路径或指标值
get_result_max_time() {
    case "$1" in
        table) printf '%s\n' "${TABLE_QUERY_MAX_TIME}" ;;
        tree|*) printf '%s\n' "${TREE_QUERY_MAX_TIME}" ;;
    esac
}

# 功能：根据上次写入终点计算并更新下一轮 Benchmark 起始时间
update_benchmark_start_time() {
    local benchmark_path="$1"
    local config_file="${benchmark_path}/conf/config.properties"
    local benchmark_start_time=""
    local last_sensor_time=""
    local timestamp_precision=""
    local formatted_max_time=""
    local format_output=""
    local format_status=0

    if [ ! -f "${config_file}" ]; then
        longrun_start_time_log "skip update start time: config file not found, config=${config_file}"
        return
    fi

    longrun_start_time_log "update benchmark start time begin, benchmark_path=${benchmark_path}, config=${config_file}"
    last_sensor_time="$(query_last_sensor_time "${config_file}")"
    timestamp_precision="$(get_iotdb_timestamp_precision)"
    longrun_start_time_log "timestamp_precision=${timestamp_precision} last_sensor_time=${last_sensor_time}"

    if [ -n "${last_sensor_time}" ]; then
        format_output="$(calculate_ttl_ms "${last_sensor_time}" "${timestamp_precision}" 2>&1)"
        format_status=$?
        if [ "${format_status}" -eq 0 ] && [ -n "${format_output}" ]; then
            LONGRUN_TTL_MS="${format_output}"
            longrun_start_time_log "ttl calculated raw=${last_sensor_time} precision=${timestamp_precision} ttl_ms=${LONGRUN_TTL_MS} keep_days=${LONGRUN_TTL_KEEP_DAYS}"
        else
            longrun_start_time_log "calculate ttl failed status=${format_status} raw=${last_sensor_time} precision=${timestamp_precision} output=${format_output}"
        fi

        format_output="$(format_iotdb_time "${last_sensor_time}" "${timestamp_precision}" 0 '+%Y-%m-%d %H:%M:%S' 2>&1)"
        format_status=$?
        if [ "${format_status}" -eq 0 ] && [ -n "${format_output}" ]; then
            formatted_max_time="${format_output}"
        else
            longrun_start_time_log "format max time failed status=${format_status} raw=${last_sensor_time} precision=${timestamp_precision} output=${format_output}"
        fi

        format_output="$(format_iotdb_time "${last_sensor_time}" "${timestamp_precision}" 3600 2>&1)"
        format_status=$?
        if [ "${format_status}" -eq 0 ] && [ -n "${format_output}" ]; then
            benchmark_start_time="${format_output}"
        else
            longrun_start_time_log "format benchmark start time failed status=${format_status} raw=${last_sensor_time} precision=${timestamp_precision} output=${format_output}"
        fi
    else
        longrun_start_time_log "query returned empty last_sensor_time"
    fi

    if [ -z "${formatted_max_time}" ]; then
        formatted_max_time="${DEFAULT_QUERY_MAX_TIME}"
        longrun_start_time_log "formatted_max_time fallback=${formatted_max_time}"
    fi

    if [ -z "${benchmark_start_time}" ]; then
        benchmark_start_time="${DEFAULT_BENCHMARK_START_TIME}"
        longrun_start_time_log "benchmark_start_time fallback=${benchmark_start_time}"
    fi

    set_result_max_time "${formatted_max_time}"
    BENCHMARK_START_TIME="${benchmark_start_time}"
    sed -i "s|^START_TIME=.*$|START_TIME=${BENCHMARK_START_TIME}|g" "${config_file}"
    longrun_start_time_log "update benchmark start time end, BENCHMARK_START_TIME=${BENCHMARK_START_TIME}, QUERY_MAX_TIME=${formatted_max_time}"
}

# 功能：应用当前场景提供的配置或扩展钩子
apply_benchmark_start_time() {
    local benchmark_path="$1"
    local config_file="${benchmark_path}/conf/config.properties"

    [ -f "${config_file}" ] || return 0
    sed -i "s|^START_TIME=.*$|START_TIME=${BENCHMARK_START_TIME}|g" "${config_file}"
}

# 功能：执行指定测试阶段或外部工具命令
run_iotdb_sql_for_ttl() {
    local dialect="$1"
    local sql="$2"
    local cli_output=""
    local cli_status=0

    cli_output="$("${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw "${IOTDB_PASSWORD}" -sql_dialect "${dialect}" -h 127.0.0.1 -p 6667 -e "${sql}" 2>&1)"
    cli_status=$?
    longrun_start_time_log "set ttl cli_status=${cli_status} dialect=${dialect} sql=${sql}"

    if [ "${cli_status}" -eq 0 ] && ! printf '%s\n' "${cli_output}" | grep -Eiq 'error|exception|failed|fail|syntax|does not exist|cannot|invalid|illegal|semantic|analyze'; then
        return 0
    fi

    if [ -n "${cli_output}" ]; then
        longrun_start_time_log "set ttl output=${cli_output}"
    fi

    return 1
}

# 功能：设置当前测试使用的配置值或运行状态
set_tree_ttl() {
    local db_name="$1"
    local ttl_ms="$2"
    local ttl_path=""

    if [[ "${db_name}" == root.* ]]; then
        ttl_path="${db_name}"
    else
        ttl_path="root.${db_name}"
    fi

    run_iotdb_sql_for_ttl "tree" "SET TTL TO ${ttl_path} ${ttl_ms}"
}

# 功能：设置当前测试使用的配置值或运行状态
set_table_ttl() {
    local db_name="$1"
    local ttl_ms="$2"
    local -a ttl_sqls=()
    local ttl_sql=""

    if [[ "${db_name}" == root.* ]]; then
        db_name="${db_name#root.}"
    fi

    ttl_sqls=(
        "ALTER DATABASE ${db_name} SET PROPERTIES TTL=${ttl_ms}"
        "ALTER DATABASE ${db_name} SET PROPERTIES (TTL=${ttl_ms})"
        "ALTER DATABASE ${db_name} WITH (TTL=${ttl_ms})"
        "ALTER DATABASE ${db_name} SET TTL=${ttl_ms}"
    )

    for ttl_sql in "${ttl_sqls[@]}"; do
        if run_iotdb_sql_for_ttl "table" "${ttl_sql}"; then
            return 0
        fi
    done

    return 1
}

# 功能：设置当前测试使用的配置值或运行状态
set_longrun_ttl() {
    local tree_config="${BM_PATH_TREE}/conf/config.properties"
    local table_config="${BM_PATH_TABLE}/conf/config.properties"
    local tree_db_name=""
    local table_db_name=""
    local ttl_ms="${LONGRUN_TTL_MS}"
    local failed=0

    if ! [[ "${ttl_ms}" =~ ^[0-9]+$ ]] || [ "${ttl_ms}" -le 0 ]; then
        longrun_start_time_log "skip set ttl: ttl_ms=${ttl_ms}"
        return 0
    fi

    tree_db_name="$(get_benchmark_config_value_or_default "${tree_config}" "DB_NAME" "tree")"
    table_db_name="$(get_benchmark_config_value_or_default "${table_config}" "DB_NAME" "table")"
    longrun_start_time_log "set ttl begin ttl_ms=${ttl_ms} tree_db=${tree_db_name} table_db=${table_db_name}"

    if ! set_tree_ttl "${tree_db_name}" "${ttl_ms}"; then
        failed=1
    fi

    if ! set_tree_ttl "${table_db_name}" "${ttl_ms}" && ! set_table_ttl "${table_db_name}" "${ttl_ms}"; then
        failed=1
    fi

    if [ "${failed}" -eq 0 ]; then
        longrun_start_time_log "set ttl end success ttl_ms=${ttl_ms}"
    else
        longrun_start_time_log "set ttl end failed ttl_ms=${ttl_ms}"
    fi

    return "${failed}"
}

# 功能：复制当前测试所需的配置、数据或运行文件
copy_benchmark_config() {
    local source_config="$1"
    local target_benchmark_path="$2"
    local target_config="${target_benchmark_path}/conf/config.properties"

    install_benchmark_config "${source_config}" "${target_config}"
}

# 功能：准备当前步骤所需的目录、配置或测试数据
prepare_benchmark_configs() {
    copy_benchmark_config "${ATMOS_PATH}/conf/${TEST_TYPE}/aligned" "${BM_PATH_TREE}"
    copy_benchmark_config "${ATMOS_PATH}/conf/${TEST_TYPE}/tablemode" "${BM_PATH_TABLE}"
    copy_benchmark_config "${ATMOS_PATH}/conf/${TEST_TYPE}/aligned_query" "${BM_PATH_TREE_QUERY}"
    copy_benchmark_config "${ATMOS_PATH}/conf/${TEST_TYPE}/tablemode_query" "${BM_PATH_TABLE_QUERY}"
}

# 功能：清理指定 Benchmark 实例的日志和输出数据
clean_benchmark_runtime() {
    local benchmark_path="$1"
    safe_rm "${benchmark_path}/logs"
    safe_rm "${benchmark_path}/data"
}

# 功能：执行指定测试阶段或外部工具命令
run_benchmark() {
    local benchmark_path="$1"

    (
        cd "${benchmark_path}" || exit 1
        ./benchmark.sh >/dev/null 2>&1 &
    )
}

# 功能：启动指定服务、工具或测试步骤
start_benchmarks() {
    clean_benchmark_runtime "${BM_PATH_TREE}"
    clean_benchmark_runtime "${BM_PATH_TABLE}"
    clean_benchmark_runtime "${BM_PATH_TREE_QUERY}"
    clean_benchmark_runtime "${BM_PATH_TABLE_QUERY}"

    update_benchmark_start_time "${BM_PATH_TREE}"
    set_longrun_ttl || log "failed to set TTL, continue benchmark."
    apply_benchmark_start_time "${BM_PATH_TABLE}"
    apply_benchmark_start_time "${BM_PATH_TREE_QUERY}"
    apply_benchmark_start_time "${BM_PATH_TABLE_QUERY}"

    run_benchmark "${BM_PATH_TREE}"
    run_benchmark "${BM_PATH_TABLE}"
    run_benchmark "${BM_PATH_TREE_QUERY}"
    run_benchmark "${BM_PATH_TABLE_QUERY}"
}

# 功能：为超时或卡死场景生成失败占位结果
create_stuck_result_csv() {
    local csv_file="$1"
    shift

    local label=""
    mkdir -p "${csv_file%/*}"
    : > "${csv_file}"
    for label in "$@"; do
        echo "${label} ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1" >> "${csv_file}"
        echo "${label} ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1" >> "${csv_file}"
    done
}

# 功能：确保当前测试依赖的资源或结果存在
ensure_output_or_stuck() {
    local benchmark_path="$1"
    local output_dir="${benchmark_path}/data/csvOutput"
    shift

    if [ ! -d "${output_dir}" ]; then
        create_stuck_result_csv "${output_dir}/Stuck_result.csv" "$@"
    fi
}

# 功能：轮询测试进程和结果文件，处理完成或超时状态
monitor_test_status() {
    local output_tree="${BM_PATH_TREE}/data/csvOutput"
    local output_table="${BM_PATH_TABLE}/data/csvOutput"
    local output_tree_query="${BM_PATH_TREE_QUERY}/data/csvOutput"
    local output_table_query="${BM_PATH_TABLE_QUERY}/data/csvOutput"
    local now_epoch=0
    local elapsed=0

    while true; do
        if [ -d "${output_tree}" ] && [ -d "${output_table}" ] && [ -d "${output_tree_query}" ] && [ -d "${output_table_query}" ]; then
            end_time="$(current_datetime)"
            log "longrun benchmark finished."
            return 0
        fi

        now_epoch="$(date +%s)"
        elapsed=$((now_epoch - m_start_time))
        if [ "${elapsed}" -ge "${MONITOR_TIMEOUT_SECONDS}" ]; then
            end_time="$(current_datetime)"
            log "longrun benchmark timed out, writing stuck results."
            ensure_output_or_stuck "${BM_PATH_TREE}" INGESTION
            ensure_output_or_stuck "${BM_PATH_TABLE}" INGESTION
            ensure_output_or_stuck "${BM_PATH_TREE_QUERY}" "${OP_TYPE_LABELS[@]}"
            ensure_output_or_stuck "${BM_PATH_TABLE_QUERY}" "${OP_TYPE_LABELS[@]}"
            return 1
        fi

        sleep "${MONITOR_POLL_INTERVAL_SECONDS}"
    done
}

# 功能：采集当前测试窗口内的资源和文件指标
collect_monitor_data() {
    local ip="$1"
    local metric_window=$((m_end_time - m_start_time))
    local maxNumofThread_C=0
    local maxNumofThread_D=0
    local datanode_error_log_size=0
    local confignode_error_log_size=0

    [ "${metric_window}" -gt 0 ] || metric_window=1

    dataFileSize="$(get_single_index "sum(file_global_size{instance=~\"${ip}:9091\"})" "${m_end_time}")"
    dataFileSize="$(bytes_to_gib "${dataFileSize}")"
    numOfSe0Level="$(get_single_index "sum(file_global_count{instance=~\"${ip}:9091\",name=\"seq\"})" "${m_end_time}")"
    numOfUnse0Level="$(get_single_index "sum(file_global_count{instance=~\"${ip}:9091\",name=\"unseq\"})" "${m_end_time}")"
    maxNumofThread_C="$(get_single_index "max_over_time(process_threads_count{instance=~\"${ip}:9081\"}[${metric_window}s])" "${m_end_time}")"
    maxNumofThread_D="$(get_single_index "max_over_time(process_threads_count{instance=~\"${ip}:9091\"}[${metric_window}s])" "${m_end_time}")"
    maxNumofThread=$(( $(to_int "${maxNumofThread_C}") + $(to_int "${maxNumofThread_D}") ))
    maxNumofOpenFiles="$(get_single_index "max_over_time(file_count{instance=~\"${ip}:9091\",name=\"open_file_handlers\"}[${metric_window}s])" "${m_end_time}")"
    walFileSize="$(get_single_index "max_over_time(file_size{instance=~\"${ip}:9091\",name=~\"wal\"}[${metric_window}s])" "${m_end_time}")"
    walFileSize="$(bytes_to_gib "${walFileSize}")"
    maxCPULoad="$(get_single_index "max_over_time(sys_cpu_load{instance=~\"${ip}:9091\"}[${metric_window}s])" "${m_end_time}")"
    avgCPULoad="$(get_single_index "avg_over_time(sys_cpu_load{instance=~\"${ip}:9091\"}[${metric_window}s])" "${m_end_time}")"
    maxDiskIOOpsRead="$(get_single_index "sum(rate(disk_io_ops{instance=~\"${ip}:9091\",disk_id=~\"${DEFAULT_DISK_ID}\",type=~\"read\"}[${metric_window}s]))" "${m_end_time}")"
    maxDiskIOOpsWrite="$(get_single_index "sum(rate(disk_io_ops{instance=~\"${ip}:9091\",disk_id=~\"${DEFAULT_DISK_ID}\",type=~\"write\"}[${metric_window}s]))" "${m_end_time}")"
    maxDiskIOSizeRead="$(get_single_index "sum(rate(disk_io_size{instance=~\"${ip}:9091\",disk_id=~\"${DEFAULT_DISK_ID}\",type=~\"read\"}[${metric_window}s]))" "${m_end_time}")"
    maxDiskIOSizeWrite="$(get_single_index "sum(rate(disk_io_size{instance=~\"${ip}:9091\",disk_id=~\"${DEFAULT_DISK_ID}\",type=~\"write\"}[${metric_window}s]))" "${m_end_time}")"

    datanode_error_log_size="$(file_size_bytes "${TEST_IOTDB_PATH}/logs/log_datanode_error.log")"
    confignode_error_log_size="$(file_size_bytes "${TEST_IOTDB_PATH}/logs/log_confignode_error.log")"
    if [ "$((datanode_error_log_size + confignode_error_log_size))" -eq 0 ]; then
        errorLogSize=0
    else
        errorLogSize=1
    fi
}

# 功能：定位 Benchmark 生成的结果 CSV 文件
find_result_csv() {
    local benchmark_path="$1"
    local had_nullglob=0
    local files=()

    if shopt -q nullglob; then
        had_nullglob=1
    else
        shopt -s nullglob
    fi

    files=("${benchmark_path}/data/csvOutput/"*result.csv)

    if [ "${had_nullglob}" -eq 0 ]; then
        shopt -u nullglob
    fi

    if [ "${#files[@]}" -gt 0 ]; then
        printf '%s\n' "${files[0]}"
    fi
}

# 功能：解析 Benchmark 输出并更新结果指标
parse_benchmark_result() {
    local csv_file="$1"
    local result_label="$2"
    local throughput_line=""
    local latency_line=""

    [ -f "${csv_file}" ] || return 1

    throughput_line="$(
        awk -F, -v label="${result_label}" '
            {
                name = $1
                gsub(/^[ \t]+|[ \t]+$/, "", name)
            }
            name == label {
                for (i = 2; i <= 6; i++) {
                    gsub(/^[ \t]+|[ \t]+$/, "", $i)
                    printf "%s%s", $i, (i == 6 ? ORS : OFS)
                }
                exit
            }
        ' OFS=$'\t' "${csv_file}"
    )"

    latency_line="$(
        awk -F, -v label="${result_label}" '
            {
                name = $1
                gsub(/^[ \t]+|[ \t]+$/, "", name)
            }
            name == label {
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

# 功能：将当前测试结果写入结果数据库
insert_result_row() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local current_data_type="$3"
    local current_op_type="$4"
    local result_max_time="$5"
    local insert_sql=""

    insert_sql=$(cat <<EOF
insert into ${result_table} (
    commit_date_time,test_date_time,commit_id,author,ts_type,data_type,op_type,okPoint,okOperation,failPoint,failOperation,throughput,
    Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,max_time,cost_time,
    numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,walFileSize,avgCPULoad,maxCPULoad,
    maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,protocol
) values (
    ${commit_date_time},
    ${test_date_time},
    $(sql_quote "${commit_id}"),
    $(sql_quote "${author}"),
    $(sql_quote "${current_ts_type}"),
    $(sql_quote "${current_data_type}"),
    $(sql_quote "${current_op_type}"),
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
    $(sql_quote "${result_max_time}"),
    ${cost_time},
    ${numOfUnse0Level},
    ${dataFileSize},
    ${maxNumofOpenFiles},
    ${maxNumofThread},
    ${errorLogSize},
    ${walFileSize},
    ${avgCPULoad},
    ${maxCPULoad},
    ${maxDiskIOSizeRead},
    ${maxDiskIOSizeWrite},
    ${maxDiskIOOpsRead},
    ${maxDiskIOOpsWrite},
    ${protocol_code}
)
EOF
)

    mysql_exec "${insert_sql}"
}

# 功能：构造并写入当前场景的结果记录
insert_result_from_csv() {
    local protocol_code="$1"
    local benchmark_path="$2"
    local current_ts_type="$3"
    local current_data_type="$4"
    local current_op_type="$5"
    local result_label="$6"
    local result_max_time=""
    local csv_file=""

    reset_benchmark_metrics
    result_max_time="$(get_result_max_time "${current_ts_type}")"
    csv_file="$(find_result_csv "${benchmark_path}" || true)"

    if [ -z "${csv_file}" ] || ! parse_benchmark_result "${csv_file}" "${result_label}"; then
        log "failed to parse ${result_label} from ${benchmark_path}, writing negative result."
        set_negative_benchmark_metrics -2
        insert_result_row "${protocol_code}" "${current_ts_type}" "${current_data_type}" "${current_op_type}" "${result_max_time}"
        return 1
    fi

    insert_result_row "${protocol_code}" "${current_ts_type}" "${current_data_type}" "${current_op_type}" "${result_max_time}"
}

# 功能：构造并写入当前场景的结果记录
insert_all_results() {
    local protocol_code="$1"
    local failed=0
    local index=0

    insert_result_from_csv "${protocol_code}" "${BM_PATH_TREE}" "tree" "${DATA_TYPE}" "INGESTION" "INGESTION" || failed=1
    insert_result_from_csv "${protocol_code}" "${BM_PATH_TABLE}" "table" "${DATA_TYPE}" "INGESTION" "INGESTION" || failed=1

    for ((index = 0; index < ${#OP_TYPE_LABELS[@]}; index++)); do
        insert_result_from_csv "${protocol_code}" "${BM_PATH_TREE_QUERY}" "tree" "${DATA_TYPE}" "${OP_TYPE_NAMES[${index}]}" "${OP_TYPE_LABELS[${index}]}" || failed=1
    done

    for ((index = 0; index < ${#OP_TYPE_LABELS[@]}; index++)); do
        insert_result_from_csv "${protocol_code}" "${BM_PATH_TABLE_QUERY}" "table" "${DATA_TYPE}" "${OP_TYPE_NAMES[${index}]}" "${OP_TYPE_LABELS[${index}]}" || failed=1
    done

    return "${failed}"
}

# 功能：归档测试日志、配置、数据或结果文件
backup_test_data() {
    local protocol_code="$1"
    local backup_dir="${BACKUP_PATH}/${commit_date_time}_${commit_id}_${protocol_code}"
    local name=""
    local path=""

    sudo_safe_rm "${backup_dir}"
    path_is_safe "${backup_dir}" || die "refuse unexpected backup path: ${backup_dir}"
    sudo mkdir -p -- "${backup_dir}/benchmark"

    if [ -d "${TEST_IOTDB_PATH}" ]; then
        path_is_safe "${TEST_IOTDB_PATH}" || die "refuse unexpected IoTDB path: ${TEST_IOTDB_PATH}"
        sudo mv "${TEST_IOTDB_PATH}" "${backup_dir}/"
    fi

    for name in tree table tree_query table_query; do
        case "${name}" in
            tree) path="${BM_PATH_TREE}" ;;
            table) path="${BM_PATH_TABLE}" ;;
            tree_query) path="${BM_PATH_TREE_QUERY}" ;;
            table_query) path="${BM_PATH_TABLE_QUERY}" ;;
        esac

        if [ -d "${path}/data/csvOutput" ]; then
            sudo cp -rf -- "${path}/data/csvOutput" "${backup_dir}/benchmark/${name}_csvOutput"
        fi
        if [ -d "${path}/logs" ]; then
            sudo cp -rf -- "${path}/logs" "${backup_dir}/benchmark/${name}_logs"
        fi
    done
}

# 功能：写入当前测试的日志、状态或失败结果
write_start_failure_result() {
    local protocol_code="$1"
    local failure_value="$2"
    local result_max_time=""

    set_negative_benchmark_metrics "${failure_value}"
    result_max_time="$(get_result_max_time "tree")"
    [ -n "${start_time}" ] || start_time="$(current_datetime)"
    [ -n "${end_time}" ] || end_time="$(current_datetime)"
    cost_time="${failure_value}"
    insert_result_row "${protocol_code}" "tree" "${DATA_TYPE}" "INGESTION" "${result_max_time}"
}

# 功能：执行单个测试组合并收集、解析和保存结果
test_operation() {
    run_isolated_case test_operation_impl "$@"
}

# 功能：执行单轮长稳测试；由 test_operation 隔离运行状态
test_operation_impl() {
    local protocol_code="$1"
    local monitor_failed=0
    local result_failed=0

    log "start ${TEST_TYPE}: protocol=${protocol_code}"
    init_items
    cleanup_processes
    set_env
    modify_iotdb_config

    if ! set_protocol_class "${protocol_code}"; then
        log "invalid protocol code: ${protocol_code}"
        return 1
    fi

    if ! start_iotdb_and_wait; then
        log "IoTDB failed to start, writing negative result."
        write_start_failure_result "${protocol_code}" -3
        cleanup_processes
        return 1
    fi

    if ! change_root_password; then
        log "failed to change root password, writing negative result."
        write_start_failure_result "${protocol_code}" -4
        cleanup_processes
        return 1
    fi

    prepare_benchmark_configs
    start_benchmarks
    start_time="$(current_datetime)"
    m_start_time="$(date +%s)"
    sleep "${BENCHMARK_WARMUP_SECONDS}"

    if ! monitor_test_status; then
        monitor_failed=1
    fi

    m_end_time="$(date +%s)"
    "${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw "${IOTDB_PASSWORD}" -h 127.0.0.1 -p 6667 -e "flush" >/dev/null 2>&1 || true
    collect_monitor_data "${TEST_IP}"
    [ -n "${end_time}" ] || end_time="$(current_datetime)"
    cost_time=$(( $(datetime_to_epoch "${end_time}") - $(datetime_to_epoch "${start_time}") ))

    stop_iotdb
    sleep "${STARTUP_GRACE_SECONDS}"

    if ! insert_all_results "${protocol_code}"; then
        result_failed=1
    fi

    sleep "${BENCHMARK_STOP_WAIT_SECONDS}"
    cleanup_processes
    backup_test_data "${protocol_code}"

    [ "${monitor_failed}" -eq 0 ] && [ "${result_failed}" -eq 0 ]
}

# 功能：校验运行环境并编排当前脚本的完整测试流程
main() {
    local protocol=""
    local task_failed=0

    trap restore_test_type_file EXIT

    ensure_runtime_dependencies
    check_password
    check_benchmark_version
    init_longrun_route

    mark_test_in_progress
    if ! fetch_next_commit; then
        sleep 60
        return 0
    fi

    update_task_status "ontesting"
    log "current commit ${commit_id} is pending, start test."

    test_date_time="$(date +%Y%m%d%H%M%S)"
    for protocol in "${PROTOCOL_LIST[@]}"; do
        if ! test_operation "${protocol}"; then
            task_failed=1
        fi
    done

    log "test round ${test_date_time} finished."
    if [ "${task_failed}" -eq 0 ]; then
        update_task_status "done"
        mark_older_commits_skip
    else
        update_task_status "RError"
    fi
}

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/runtime_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/monitor_common.sh"

main "$@"
