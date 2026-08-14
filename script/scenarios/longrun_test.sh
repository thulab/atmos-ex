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
readonly REPOS_PATH="/nasdata/repository/master"
readonly BM_REPOS_PATH="/nasdata/repository/iot-benchmark"

readonly TEST_INIT_PATH="/data/atmos"
readonly TEST_IOTDB_PATH="${TEST_INIT_PATH}/apache-iotdb"
readonly LONGRUN_START_TIME_LOG="${TEST_IOTDB_PATH}/logs/longrun_start_time_debug.log"
readonly IOTDB_HDD_DATA_DIR="/data/data_dir"
readonly IOTDB_SSD_DATA_DIR="/ssd_dcpmm/data_dir"
readonly IOTDB_DATA_DIRS="${IOTDB_HDD_DATA_DIR},${IOTDB_SSD_DATA_DIR}"
readonly IOTDB_CONF_DIR="/ssd_dcpmm/conf_dir"

readonly -a protocol_class=(
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
readonly MONITOR_TIMEOUT_SECONDS=864000
readonly MONITOR_POLL_INTERVAL_SECONDS=10
readonly IOTDB_READY_RETRIES=10
readonly IOTDB_READY_INTERVAL_SECONDS=5
readonly STARTUP_GRACE_SECONDS=10
readonly BENCHMARK_WARMUP_SECONDS=60
readonly BENCHMARK_STOP_WAIT_SECONDS=30
COPY_IOTDB_ENV=1

result_table="${TABLENAME}"
TASK_AUTHOR_FILTER_SQL="author != 'Timecho'"
commit_id=""
author=""
commit_date_time=""
test_date_time=""

TREE_QUERY_MAX_TIME="${DEFAULT_QUERY_MAX_TIME}"
TABLE_QUERY_MAX_TIME="${DEFAULT_QUERY_MAX_TIME}"
QUERY_MAX_TIME="${DEFAULT_QUERY_MAX_TIME}"
BENCHMARK_START_TIME="${DEFAULT_BENCHMARK_START_TIME}"
LONGRUN_TTL_MS=0

# 功能：探测当前主机、磁盘或运行环境信息
detect_local_ips() {
    {
        hostname -I 2>/dev/null || true
        hostname -i 2>/dev/null || true
        if command -v ip >/dev/null 2>&1; then
            ip -o -4 addr show scope global 2>/dev/null | awk '{split($4, address, "/"); print address[1]}'
        fi
        if command -v ifconfig >/dev/null 2>&1; then
            ifconfig -a 2>/dev/null | awk '
                $1 == "inet" {print $2}
                /inet addr:/ {
                    value=$0
                    sub(/^.*inet addr:/, "", value)
                    sub(/[[:space:]].*$/, "", value)
                    print value
                }
            '
        fi
    } | tr ' ' '\n' | sed 's#/.*##' | awk 'NF && $0 !~ /^127\./ && !seen[$0]++'
}

# 功能：根据本机地址选择长稳测试的数据表和任务过滤条件
init_longrun_route() {
    local local_ips=""
    local first_ip=""
    local configured_ip="${LONGRUN_HOST_IP:-}"

    if [ -n "${configured_ip}" ]; then
        local_ips="${configured_ip}"
    else
        local_ips="$(detect_local_ips)"
    fi
    first_ip="$(printf '%s\n' "${local_ips}" | awk 'NF {print; exit}')"

    [ -n "${first_ip}" ] || die "unable to detect local IPv4 address; set LONGRUN_HOST_IP explicitly"

    if printf '%s\n' "${local_ips}" | grep -Fxq "${TIMECHO_LONGRUN_IP}"; then
        TASK_AUTHOR_FILTER_SQL="author = 'Timecho'"
        result_table="${TABLENAME_T}"
        TEST_IP="${TIMECHO_LONGRUN_IP}"
    else
        TASK_AUTHOR_FILTER_SQL="author != 'Timecho'"
        result_table="${TABLENAME}"
        if [ -n "${first_ip}" ]; then
            TEST_IP="${first_ip}"
        fi
    fi

    log "route: local_ips=$(printf '%s' "${local_ips}" | tr '\n' ','), TASK_AUTHOR_FILTER_SQL=${TASK_AUTHOR_FILTER_SQL}, result_table=${result_table}, TEST_IP=${TEST_IP}"
}

# 功能：校验领取结果与当前机器负责的作者分流一致
longrun_author_matches_route() {
    if [ "${TASK_AUTHOR_FILTER_SQL}" = "author = 'Timecho'" ]; then
        [ "${author}" = "Timecho" ]
    else
        [ "${author}" != "Timecho" ]
    fi
}

# 功能：比较本地与仓库版本并同步 IoT-Benchmark
check_benchmark_version() {
    sync_benchmark_distribution "${BM_REPOS_PATH}" "${BM_PATH_TREE}"
    sync_benchmark_distribution "${BM_REPOS_PATH}" "${BM_PATH_TABLE}"
    sync_benchmark_distribution "${BM_REPOS_PATH}" "${BM_PATH_TREE_QUERY}"
    sync_benchmark_distribution "${BM_REPOS_PATH}" "${BM_PATH_TABLE_QUERY}"
}

# 功能：重置当前测试用例使用的指标和运行状态
init_scenario_state() {
    TREE_QUERY_MAX_TIME="${DEFAULT_QUERY_MAX_TIME}"
    TABLE_QUERY_MAX_TIME="${DEFAULT_QUERY_MAX_TIME}"
    QUERY_MAX_TIME="${DEFAULT_QUERY_MAX_TIME}"
    BENCHMARK_START_TIME="${DEFAULT_BENCHMARK_START_TIME}"
    LONGRUN_TTL_MS=0
}

# 功能：补充 longrun 分发安装后的专用数据目录
after_prepare_iotdb_distribution() {
    mkdir -p "${IOTDB_HDD_DATA_DIR}" "${IOTDB_SSD_DATA_DIR}" "${IOTDB_CONF_DIR}"
}

# 功能：按当前测试场景修改 IoTDB 配置
modify_iotdb_config() {
    local datanode_env="${TEST_IOTDB_PATH}/conf/datanode-env.sh"
    local properties_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"

    [ -f "${datanode_env}" ] || die "missing config file: ${datanode_env}"
    [ -f "${properties_file}" ] || die "missing config file: ${properties_file}"
    set_iotdb_heap_memory 40G
    upsert_properties "${properties_file}" \
        "enable_seq_space_compaction=true" \
        "enable_unseq_space_compaction=true" \
        "enable_cross_space_compaction=true" \
        "cluster_name=${TEST_TYPE}" \
        "cn_system_dir=${IOTDB_CONF_DIR}/confignode/system" \
        "cn_consensus_dir=${IOTDB_CONF_DIR}/confignode/consensus" \
        "cn_pipe_receiver_file_dir=${IOTDB_CONF_DIR}/confignode/system/pipe/receiver" \
        "dn_system_dir=${IOTDB_SSD_DATA_DIR}/datanode/system" \
        "dn_data_dirs=${IOTDB_DATA_DIRS}" \
        "dn_consensus_dir=${IOTDB_SSD_DATA_DIR}/datanode/consensus" \
        "dn_wal_dirs=${IOTDB_SSD_DATA_DIR}/datanode/wal" \
        "dn_tracing_dir=${IOTDB_SSD_DATA_DIR}/datanode/tracing" \
        "dn_sync_dir=${IOTDB_SSD_DATA_DIR}/datanode/sync" \
        "sort_tmp_dir=${IOTDB_SSD_DATA_DIR}/datanode/tmp" \
        "dn_pipe_receiver_file_dirs=${IOTDB_SSD_DATA_DIR}/datanode/system/pipe/receiver" \
        "iot_consensus_v2_receiver_file_dirs=${IOTDB_SSD_DATA_DIR}/datanode/system/pipe/consensus/receiver" \
        "iot_consensus_v2_deletion_file_dir=${IOTDB_SSD_DATA_DIR}/datanode/system/pipe/consensus/deletion" \
        "remote_tsfile_cache_dirs=${IOTDB_SSD_DATA_DIR}/datanode/data/cache"
    apply_iotdb_profile metrics
}

# 功能：记录长稳测试当前使用的 Benchmark 起始时间
longrun_start_time_log() {
    local log_line=""

    log_line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    mkdir -p "${TEST_IOTDB_PATH}/logs"
    printf '%s\n' "${log_line}" >> "${LONGRUN_START_TIME_LOG}"
    printf '%s\n' "${log_line}" >&2
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

    db_name="$(get_property_value "${config_file}" DB_NAME test)"
    group_name_prefix="$(get_property_value "${config_file}" GROUP_NAME_PREFIX g_)"
    device_name_prefix="$(get_property_value "${config_file}" DEVICE_NAME_PREFIX d_)"
    sensor_name_prefix="$(get_property_value "${config_file}" SENSOR_NAME_PREFIX s_)"
    sensor_name="${sensor_name_prefix}0"
    query_sql="select max_time(${sensor_name}) from root.${db_name}.${group_name_prefix}0.${device_name_prefix}0"

    longrun_start_time_log "query config=${config_file} db=${db_name} group_prefix=${group_name_prefix} device_prefix=${device_name_prefix} sensor=${sensor_name}"
    longrun_start_time_log "query sql=${query_sql}"

    cli_output="$(iotdb_cli_run -u root -pw "${IOTDB_PASSWORD}" -sql_dialect tree -h 127.0.0.1 -p 6667 -e "${query_sql}" 2>&1)"
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

# 功能：计算当前测试所需的时间、大小或统计值
calculate_ttl_ms() {
    local raw_timestamp="$1"
    local timestamp_precision="$2"
    local max_time_epoch=0
    local now_epoch=0
    local keep_seconds=0
    local ttl_seconds=0

    [[ "${LONGRUN_TTL_KEEP_DAYS}" =~ ^[0-9]+$ ]] || return 1
    max_time_epoch="$(iotdb_timestamp_to_epoch "${raw_timestamp}" "${timestamp_precision}" 2>/dev/null)" || return 1
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
    timestamp_precision="$(get_property_value "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" timestamp_precision ms)"
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

        format_output="$(format_iotdb_timestamp "${last_sensor_time}" "${timestamp_precision}" 0 '+%Y-%m-%d %H:%M:%S' 2>&1)"
        format_status=$?
        if [ "${format_status}" -eq 0 ] && [ -n "${format_output}" ]; then
            formatted_max_time="${format_output}"
        else
            longrun_start_time_log "format max time failed status=${format_status} raw=${last_sensor_time} precision=${timestamp_precision} output=${format_output}"
        fi

        format_output="$(format_iotdb_timestamp "${last_sensor_time}" "${timestamp_precision}" 3600 2>&1)"
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

# 功能：执行指定测试阶段或外部工具命令
run_iotdb_sql_for_ttl() {
    local dialect="$1"
    local sql="$2"
    local cli_output=""
    local cli_status=0

    cli_output="$(iotdb_cli_run -u root -pw "${IOTDB_PASSWORD}" -sql_dialect "${dialect}" -h 127.0.0.1 -p 6667 -e "${sql}" 2>&1)"
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

    tree_db_name="$(get_property_value "${tree_config}" DB_NAME tree)"
    table_db_name="$(get_property_value "${table_config}" DB_NAME table)"
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

# 功能：准备当前步骤所需的目录、配置或测试数据
prepare_benchmark_configs() {
    install_benchmark_case_config "$(config_build_case_id model aligned workload insert)" "${BM_PATH_TREE}"
    install_benchmark_case_config "$(config_build_case_id model tablemode workload insert)" "${BM_PATH_TABLE}"
    install_benchmark_case_config "$(config_build_case_id model aligned workload query)" "${BM_PATH_TREE_QUERY}"
    install_benchmark_case_config "$(config_build_case_id model tablemode workload query)" "${BM_PATH_TABLE_QUERY}"
}

# 功能：启动指定服务、工具或测试步骤
start_benchmarks() {
    update_benchmark_start_time "${BM_PATH_TREE}"
    set_longrun_ttl || log "failed to set TTL, continue benchmark."
    apply_benchmark_overrides "${BM_PATH_TABLE}" "START_TIME=${BENCHMARK_START_TIME}"
    apply_benchmark_overrides "${BM_PATH_TREE_QUERY}" "START_TIME=${BENCHMARK_START_TIME}"
    apply_benchmark_overrides "${BM_PATH_TABLE_QUERY}" "START_TIME=${BENCHMARK_START_TIME}"

    start_benchmark "${BM_PATH_TREE}"
    start_benchmark "${BM_PATH_TABLE}"
    start_benchmark "${BM_PATH_TREE_QUERY}"
    start_benchmark "${BM_PATH_TABLE_QUERY}"
}

# 功能：确保当前测试依赖的资源或结果存在
ensure_output_or_stuck() {
    local benchmark_path="$1"
    local output_dir="${benchmark_path}/data/csvOutput"
    shift

    if [ ! -d "${output_dir}" ]; then
        create_benchmark_stuck_result_csv "${output_dir}/Stuck_result.csv" 2 "$@"
    fi
}

# 功能：轮询测试进程和结果文件，处理完成或超时状态
monitor_test_status() {
    local output_tree="${BM_PATH_TREE}/data/csvOutput"
    local output_table="${BM_PATH_TABLE}/data/csvOutput"
    local output_tree_query="${BM_PATH_TREE_QUERY}/data/csvOutput"
    local output_table_query="${BM_PATH_TABLE_QUERY}/data/csvOutput"
    if wait_for_benchmark_output_dirs \
        "${MONITOR_TIMEOUT_SECONDS}" "${MONITOR_POLL_INTERVAL_SECONDS}" "${m_start_time}" \
        "${output_tree}" "${output_table}" "${output_tree_query}" "${output_table_query}"; then
        log "longrun benchmark finished."
        return 0
    fi
    log "longrun benchmark timed out, writing stuck results."
    ensure_output_or_stuck "${BM_PATH_TREE}" INGESTION
    ensure_output_or_stuck "${BM_PATH_TABLE}" INGESTION
    ensure_output_or_stuck "${BM_PATH_TREE_QUERY}" "${OP_TYPE_LABELS[@]}"
    ensure_output_or_stuck "${BM_PATH_TABLE_QUERY}" "${OP_TYPE_LABELS[@]}"
    return 1
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

    set_standard_negative_benchmark_metrics 0
    result_max_time="$(get_result_max_time "${current_ts_type}")"
    csv_file="$(find_result_csv "${benchmark_path}/data/csvOutput" || true)"
    log "benchmark parse start path=${benchmark_path} label=[${result_label}] selected_csv=${csv_file:-missing}"

    if [ -z "${csv_file}" ] || ! parse_standard_benchmark_result "${csv_file}" "${result_label}"; then
        log_benchmark_parse_diagnostics "${benchmark_path}" "${csv_file}" "${result_label}"
        log "failed to parse ${result_label} from ${benchmark_path}, writing negative result."
        set_standard_negative_benchmark_metrics -2
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
    local name=""
    local path=""
    local case_id=""

    case_id="$(backup_build_case_id protocol "${protocol_code}" workload longrun)"
    backup_begin_case "${case_id}" || return 1
    backup_add_iotdb_runtime

    for name in tree table tree_query table_query; do
        case "${name}" in
            tree) path="${BM_PATH_TREE}" ;;
            table) path="${BM_PATH_TABLE}" ;;
            tree_query) path="${BM_PATH_TREE_QUERY}" ;;
            table_query) path="${BM_PATH_TABLE_QUERY}" ;;
        esac

        backup_add_benchmark_runtime "${path}" "benchmark-${name}"
    done
    backup_finish_case completed
}

# 功能：写入当前测试的日志、状态或失败结果
write_start_failure_result() {
    local protocol_code="$1"
    local failure_value="$2"
    local result_max_time=""

    set_standard_negative_benchmark_metrics "${failure_value}"
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
    iotdb_cli_exec "flush" 127.0.0.1 6667 root "${IOTDB_PASSWORD}" >/dev/null 2>&1 || true
    disk_id_regex="${DEFAULT_DISK_ID}"
    collect_standard_monitor_snapshot "${TEST_IP}" "$((m_end_time - m_start_time))"
    errorLogSize=$(( $(file_size_bytes "${TEST_IOTDB_PATH}/logs/log_datanode_error.log") + $(file_size_bytes "${TEST_IOTDB_PATH}/logs/log_confignode_error.log") > 0 ? 1 : 0 ))
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
        log "no ${TEST_TYPE} task matched ${TASK_AUTHOR_FILTER_SQL}"
        sleep 60
        return 0
    fi

    if ! longrun_author_matches_route; then
        log "ERROR: task author ${author} does not match route ${TASK_AUTHOR_FILTER_SQL}; refuse to claim commit ${commit_id}"
        return 1
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
        finish_task_success
    else
        finish_task_failure
    fi
}

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/runtime_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/benchmark_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/monitor_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/iotdb_distribution_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/iotdb_service_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/protocol_common.sh"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
