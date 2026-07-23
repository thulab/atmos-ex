#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
if shopt -oq posix; then
    exec bash "${BASH_SOURCE[0]}" "$@"
fi

set -u
set -o pipefail

readonly TEST_IP="11.101.17.141"
readonly TEST_TYPE="last_cache_query"
readonly -a PROTOCOL_LIST=(223)
readonly -a TS_LIST=(common aligned tablemode)
readonly -a API_LIST=(LATEST_POINT)
readonly QUERY_BM_PATH="/data/atmos/zk_test/query-benchmark"
readonly QUERY_RESULT_LABEL="LATEST_POINT"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/common/insert_common.sh
source "${SCRIPT_DIR}/../common/insert_common.sh"

# 功能：同步本地与目标位置的版本或目录内容
sync_benchmark_path() {
    sync_benchmark_distribution "${BM_REPOS_PATH}" "$1"
    return
    local target_path="$1"
    local source_version=""
    local target_version=""

    [ -f "${BM_REPOS_PATH}/git.properties" ] || die "missing benchmark git.properties: ${BM_REPOS_PATH}/git.properties"
    source_version="$(awk -F= '/git.commit.id.abbrev/ {print $2}' "${BM_REPOS_PATH}/git.properties")"
    [ -n "${source_version}" ] || die "failed to read benchmark version."

    if [ -f "${target_path}/git.properties" ]; then
        target_version="$(awk -F= '/git.commit.id.abbrev/ {print $2}' "${target_path}/git.properties")"
    fi

    if [ ! -d "${target_path}" ] || [ "${target_version}" != "${source_version}" ]; then
        log "sync benchmark to ${target_path}"
        safe_rm "${target_path}"
        cp -rf -- "${BM_REPOS_PATH}" "${target_path}"
    fi
}

# 功能：比较本地与仓库版本并同步 IoT-Benchmark
check_benchmark_version() {
    sync_benchmark_path "${BM_PATH}"
    sync_benchmark_path "${QUERY_BM_PATH}"
}

# 功能：启用当前测试场景要求的功能配置
enable_last_cache() {
    printf 'enable_last_cache=true\n' >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
}

# 功能：复制当前测试所需的配置、数据或运行文件
copy_benchmark_config() {
    local source_config="$1"
    local target_benchmark_path="$2"
    local target_config="${target_benchmark_path}/conf/config.properties"

    install_benchmark_config "${source_config}" "${target_config}"
}

# 功能：生成或修改当前测试步骤所需的配置
configure_background_benchmark() {
    local current_ts_type="$1"
    copy_benchmark_config "${ATMOS_PATH}/conf/${TEST_TYPE}/${current_ts_type}" "${BM_PATH}"
}

# 功能：生成或修改当前测试步骤所需的配置
configure_query_benchmark() {
    local current_ts_type="$1"
    local target_config="${QUERY_BM_PATH}/conf/config.properties"

    copy_benchmark_config "${ATMOS_PATH}/conf/${TEST_TYPE}/Q8" "${QUERY_BM_PATH}"
    if [ "${current_ts_type}" = "tablemode" ]; then
        sed -i 's/^IoTDB_DIALECT_MODE=.*$/IoTDB_DIALECT_MODE=table/' "${target_config}"
    fi
}

# 功能：启动指定服务、工具或测试步骤
start_query_benchmark() {
    safe_rm "${QUERY_BM_PATH}/logs"
    safe_rm "${QUERY_BM_PATH}/data"
    (
        cd "${QUERY_BM_PATH}" || exit 1
        ./benchmark.sh >/dev/null 2>&1 &
    )
}

# 功能：定位后台查询 Benchmark 生成的结果 CSV
find_query_result_csv() {
    local had_nullglob=0
    local files=()

    if shopt -q nullglob; then
        had_nullglob=1
    else
        shopt -s nullglob
    fi

    files=("${QUERY_BM_PATH}/data/csvOutput/"*result.csv)

    if [ "${had_nullglob}" -eq 0 ]; then
        shopt -u nullglob
    fi

    if [ "${#files[@]}" -gt 0 ]; then
        printf '%s\n' "${files[0]}"
    fi
}

# 功能：创建当前测试需要的数据、文件或数据库对象
create_query_stuck_result_csv() {
    local csv_file="$1"
    local index=0

    mkdir -p "${csv_file%/*}"
    : > "${csv_file}"
    for ((index = 0; index < 100; index++)); do
        echo "${QUERY_RESULT_LABEL} ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1" >> "${csv_file}"
    done
}

# 功能：监控后台查询 Benchmark 直到完成或超时
monitor_query_status() {
    local current_ts_type="$1"
    local csv_file=""
    local now_epoch=0
    local elapsed=0

    while true; do
        csv_file="$(find_query_result_csv || true)"
        if [ -n "${csv_file}" ]; then
            end_time="$(current_datetime)"
            log "${current_ts_type} query finished."
            return 0
        fi

        now_epoch="$(date +%s)"
        elapsed=$((now_epoch - m_start_time))
        if [ "${elapsed}" -ge "${MONITOR_TIMEOUT_SECONDS}" ]; then
            end_time="$(current_datetime)"
            log "${current_ts_type} query timed out, writing stuck result."
            create_query_stuck_result_csv "${QUERY_BM_PATH}/data/csvOutput/Stuck_result.csv"
            return 1
        fi

        sleep "${MONITOR_POLL_INTERVAL_SECONDS}"
    done
}

# 功能：解析外部输出并转换为脚本使用的结果字段
parse_query_benchmark_result() {
    local csv_file="$1"
    local throughput_line=""
    local latency_line=""

    [ -f "${csv_file}" ] || return 1

    throughput_line="$(
        awk -F, -v label="${QUERY_RESULT_LABEL}" '
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
        awk -F, -v label="${QUERY_RESULT_LABEL}" '
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
    local insert_sql=""

    insert_sql=$(cat <<EOF
insert into ${result_table} (
    commit_date_time,test_date_time,commit_id,author,ts_type,okPoint,okOperation,failPoint,failOperation,throughput,
    Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,
    numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,walFileSize,avgCPULoad,maxCPULoad,
    maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark
) values (
    ${commit_date_time},
    ${test_date_time},
    $(sql_quote "${commit_id}"),
    $(sql_quote "${author}"),
    $(sql_quote "${current_ts_type}"),
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
    ${avgCPULoad},
    ${maxCPULoad},
    ${maxDiskIOSizeRead},
    ${maxDiskIOSizeWrite},
    ${maxDiskIOOpsRead},
    ${maxDiskIOOpsWrite},
    $(sql_quote "${protocol_code}")
)
EOF
)

    mysql_exec "${insert_sql}"
}

# 功能：归档测试日志、配置、数据或结果文件
backup_test_data() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local backup_parent="${BACKUP_PATH}/${current_ts_type}"
    local backup_dir="${backup_parent}/${commit_date_time}_${commit_id}_${protocol_code}"

    sudo_safe_rm "${backup_dir}"
    path_is_safe "${backup_parent}" || die "refuse unexpected backup path: ${backup_parent}"
    sudo mkdir -p -- "${backup_parent}"
    path_is_safe "${backup_dir}" || die "refuse unexpected backup path: ${backup_dir}"
    sudo mkdir -p -- "${backup_dir}"

    sudo_safe_rm "${TEST_IOTDB_PATH}/data"
    path_is_safe "${TEST_IOTDB_PATH}" || die "refuse unexpected IoTDB path: ${TEST_IOTDB_PATH}"
    sudo mv "${TEST_IOTDB_PATH}" "${backup_dir}"
    if [ -d "${QUERY_BM_PATH}/data/csvOutput" ]; then
        sudo cp -rf -- "${QUERY_BM_PATH}/data/csvOutput" "${backup_dir}"
    fi
    if [ -d "${QUERY_BM_PATH}/logs" ]; then
        sudo cp -rf -- "${QUERY_BM_PATH}/logs" "${backup_dir}"
    fi
}

# 功能：执行单个测试组合并收集、解析和保存结果
test_operation() {
    run_isolated_case test_operation_impl "$@"
}

# 功能：执行单轮 Last Cache 查询测试；由 test_operation 隔离运行状态
test_operation_impl() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local csv_file=""
    local monitor_failed=0
    local parse_failed=0

    log "start ${TEST_TYPE}: protocol=${protocol_code}, ts_type=${current_ts_type}"
    init_items
    cleanup_processes
    set_env
    modify_iotdb_config
    enable_last_cache

    if ! set_protocol_class "${protocol_code}"; then
        log "invalid protocol code: ${protocol_code}"
        return 1
    fi

    start_iotdb
    sleep "${STARTUP_GRACE_SECONDS}"
    if ! wait_for_iotdb_ready; then
        log "IoTDB failed to start, writing negative result."
        cost_time=-3
        throughput=-3
        insert_result_row "${protocol_code}" "${current_ts_type}"
        cleanup_processes
        return 1
    fi

    if ! change_root_password; then
        log "failed to change root password, writing negative result."
        cost_time=-4
        throughput=-4
        insert_result_row "${protocol_code}" "${current_ts_type}"
        cleanup_processes
        return 1
    fi

    configure_background_benchmark "${current_ts_type}"
    start_benchmark
    sleep "${BENCHMARK_WARMUP_SECONDS}"

    configure_query_benchmark "${current_ts_type}"
    start_query_benchmark
    start_time="$(current_datetime)"
    m_start_time="$(date +%s)"
    sleep "${BENCHMARK_WARMUP_SECONDS}"

    if ! monitor_query_status "${current_ts_type}"; then
        monitor_failed=1
    fi
    m_end_time="$(date +%s)"

    "${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw "${IOTDB_PASSWORD}" -h 127.0.0.1 -p 6667 -e "flush" >/dev/null 2>&1 || true
    collect_monitor_data "${TEST_IP}"

    csv_file="$(find_query_result_csv || true)"
    if [ -z "${csv_file}" ] || ! parse_query_benchmark_result "${csv_file}"; then
        log "failed to parse benchmark result, writing negative result."
        parse_failed=1
        [ -n "${end_time}" ] || end_time="$(current_datetime)"
        cost_time=-2
        throughput=-2
    else
        [ -n "${end_time}" ] || end_time="$(current_datetime)"
        cost_time=$(( $(datetime_to_epoch "${end_time}") - $(datetime_to_epoch "${start_time}") ))
    fi

    insert_result_row "${protocol_code}" "${current_ts_type}"

    stop_iotdb
    sleep "${BENCHMARK_STOP_WAIT_SECONDS}"
    cleanup_processes
    [ -d "${TEST_IOTDB_PATH}" ] && backup_test_data "${protocol_code}" "${current_ts_type}"

    [ "${monitor_failed}" -eq 0 ] && [ "${parse_failed}" -eq 0 ]
}

main "$@"
