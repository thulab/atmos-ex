#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
if shopt -oq posix; then
    exec bash "${BASH_SOURCE[0]}" "$@"
fi

set -u
set -o pipefail

ACCOUNT="${ACCOUNT:-root}"
readonly IOTDB_PASSWORD="${IOTDB_PASSWORD:-TimechoDB@2021}"
readonly TEST_TYPE="${TEST_TYPE:-os_jdk}"
readonly BENCHMARK_DEFAULT_RESULT_LABEL="INGESTION"

readonly INIT_PATH="${INIT_PATH:-/data/atmos/zk_test}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly ATMOS_PATH="${ATMOS_PATH:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
readonly BM_PATH="${BM_PATH:-${INIT_PATH}/iot-benchmark}"
readonly BM_REPOS_PATH="${BM_REPOS_PATH:-/nasdata/repository/iot-benchmark}"
readonly JDK_ROOT="${JDK_ROOT:-${INIT_PATH}/jdk}"
readonly REPOS_PATH="${REPOS_PATH:-/nasdata/repository/master}"

readonly TEST_INIT_PATH="${TEST_INIT_PATH:-/data/atmos/first-rest-test}"
readonly TEST_IOTDB_PATH="${TEST_IOTDB_PATH:-${TEST_INIT_PATH}/apache-iotdb}"
readonly TEST_BM_PATH="${TEST_BM_PATH:-${TEST_INIT_PATH}/iot-benchmark}"

BACKUP_ROOT="${BACKUP_ROOT:-/nasdata/repository/os_jdk}"

readonly MYSQL_HOST="${MYSQL_HOST:-111.200.37.158}"
readonly MYSQL_PORT="${MYSQL_PORT:-13306}"
readonly MYSQL_USERNAME="${MYSQL_USERNAME:-iotdbatm}"
readonly MYSQL_PASSWORD="${MYSQL_PASSWORD:-${ATMOS_DB_PASSWORD:-}}"
readonly DBNAME="${DBNAME:-QA_ATM}"
readonly TABLENAME="${TABLENAME:-ex_os_jdk_T}"
readonly TASK_TABLENAME="${TASK_TABLENAME:-commit_history}"

readonly METRIC_SERVER="${METRIC_SERVER:-111.200.37.158:19090}"
readonly DEFAULT_DISK_ID="${DEFAULT_DISK_ID:-sdb}"
readonly MONITOR_TIMEOUT_SECONDS="${MONITOR_TIMEOUT_SECONDS:-3600}"
readonly MONITOR_POLL_INTERVAL_SECONDS="${MONITOR_POLL_INTERVAL_SECONDS:-5}"
readonly REMOTE_REBOOT_GRACE_SECONDS="${REMOTE_REBOOT_GRACE_SECONDS:-120}"
readonly REMOTE_IOTDB_READY_RETRIES="${REMOTE_IOTDB_READY_RETRIES:-51}"
readonly REMOTE_IOTDB_READY_INTERVAL_SECONDS="${REMOTE_IOTDB_READY_INTERVAL_SECONDS:-3}"
readonly IOTDB_READY_NODE_COUNT="${IOTDB_READY_NODE_COUNT:-2}"
readonly STARTUP_GRACE_SECONDS="${STARTUP_GRACE_SECONDS:-10}"
readonly IOTDB_SETTLE_SECONDS="${IOTDB_SETTLE_SECONDS:-60}"
readonly BENCHMARK_WARMUP_SECONDS="${BENCHMARK_WARMUP_SECONDS:-10}"

readonly -a protocol_class=(
    ""
    "org.apache.iotdb.consensus.simple.SimpleConsensus"
    "org.apache.iotdb.consensus.ratis.RatisConsensus"
    "org.apache.iotdb.consensus.iot.IoTConsensus"
    "org.apache.iotdb.consensus.iot.IoTConsensusV2"
)
readonly -a PROTOCOL_LIST=(223)
readonly -a OS_LIST=(ubuntu22 ubuntu24 centos7 centos8)
readonly -a JDK_LIST=(OpenJDK17 OpenJDK21 TencentKona17 TencentKona21 DragonWell17 DragonWell21)
readonly -a TS_LIST=(aligned tablemode)
readonly -a IP_LIST=(172.20.70.37 172.20.70.28 172.20.70.39 172.20.70.41)

commit_id=""
author=""
commit_date_time=""
test_date_time=""
protocol_class_input=""
ts_type=""
jdk_type=""
os_type=""

# shellcheck source=script/common/runtime_common.sh
source "${SCRIPT_DIR}/../common/runtime_common.sh"
# shellcheck source=script/common/benchmark_common.sh
source "${SCRIPT_DIR}/../common/benchmark_common.sh"
# shellcheck source=script/common/monitor_common.sh
source "${SCRIPT_DIR}/../common/monitor_common.sh"
# shellcheck source=script/common/remote_common.sh
source "${SCRIPT_DIR}/../common/remote_common.sh"
# shellcheck source=script/common/protocol_common.sh
source "${SCRIPT_DIR}/../common/protocol_common.sh"

# 功能：重置本轮场景执行过程中使用的临时状态变量
init_scenario_state() {
    protocol_class_input=""
    ts_type=""
    jdk_type=""
    os_type=""
}

# 功能：校验节点 IP 列表与 OS 列表是否一一对应
validate_matrix() {
    [ "${#IP_LIST[@]}" -eq "${#OS_LIST[@]}" ] ||
        die "IP_LIST and OS_LIST must have the same length"
}

# 功能：清空并重建本地测试目录
reset_test_dir() {
    case "${TEST_INIT_PATH}" in
        ""|/|/data|/nasdata|/root|.) die "refuse to reset unsafe test path: ${TEST_INIT_PATH}" ;;
    esac
    rm -rf -- "${TEST_INIT_PATH}"
    mkdir -p "${TEST_IOTDB_PATH}"
}

# 功能：准备本地 IoTDB 和 benchmark 的运行目录
set_env() {
    local source_iotdb="${REPOS_PATH}/${commit_id}/apache-iotdb"

    [ -d "${source_iotdb}" ] || die "missing IoTDB distribution: ${source_iotdb}"
    reset_test_dir
    cp -rf -- "${source_iotdb}/." "${TEST_IOTDB_PATH}/"
    mkdir -p "${TEST_IOTDB_PATH}/activation"
    prepare_benchmark_runtime "${BM_PATH}"
    cp -rf -- "${BM_PATH}" "${TEST_INIT_PATH}/"
}

# 功能：为 IoTDB 启动脚本替换指定 JDK 路径
set_iotdb_java_home() {
    local jdk_name="$1"
    local java_home="${JDK_ROOT}/${jdk_name}"
    local config_file=""
    local -a config_files=(
        "${TEST_IOTDB_PATH}/conf/confignode-env.sh"
        "${TEST_IOTDB_PATH}/conf/datanode-env.sh"
        "${TEST_IOTDB_PATH}/sbin/start-cli.sh"
    )

    for config_file in "${config_files[@]}"; do
        [ -f "${config_file}" ] || die "missing config file: ${config_file}"
        if grep -Eq '^#?[[:space:]]*export JAVA_HOME=' "${config_file}"; then
            sed -i "s|^#\?[[:space:]]*export JAVA_HOME=.*$|export JAVA_HOME=${java_home}|g" "${config_file}"
        else
            printf '\nexport JAVA_HOME=%s\n' "${java_home}" >> "${config_file}"
        fi
    done
}

# 功能：按当前 JDK 方案修改 IoTDB 配置
modify_iotdb_config() {
    local current_jdk="$1"

    set_iotdb_java_home "${current_jdk}"
    set_iotdb_heap_memory 20G 6G
    apply_iotdb_profile base
}

# 功能：安装当前时间序列类型对应的 benchmark 配置
install_benchmark_config() {
    local current_ts_type="$1"

    install_config_file \
        "${ATMOS_PATH}/conf/${TEST_TYPE}/benchmark/${current_ts_type}" \
        "${TEST_BM_PATH}/conf/config.properties"
}

# 功能：安装单个节点对应的 license 和环境文件
install_node_runtime_config() {
    local host="$1"
    local config_root="${ATMOS_PATH}/conf/${TEST_TYPE}"

    rm -rf -- "${TEST_IOTDB_PATH}/activation"
    rm -f -- "${TEST_IOTDB_PATH}/.env"
    mkdir -p "${TEST_IOTDB_PATH}/activation"
    copy_if_exists "${config_root}/license/${host}" "${TEST_IOTDB_PATH}/activation/license" "${host} license"
    copy_if_exists "${config_root}/env/${host}" "${TEST_IOTDB_PATH}/.env" "${host} env"
}

# 功能：重启所有远端测试节点并等待其恢复
reboot_test_nodes() {
    local host=""

    log "reset remote os_jdk nodes"
    for host in "${IP_LIST[@]}"; do
        remote_reboot "${host}"
    done

    sleep "${REMOTE_REBOOT_GRACE_SECONDS}"
    for host in "${IP_LIST[@]}"; do
        wait_for_remote "${host}" || die "remote host is not available after reboot: ${host}"
    done
}

# 功能：向所有远端节点分发测试目录和配置
deploy_test_nodes() {
    local current_ts_type="$1"
    local host=""

    install_benchmark_config "${current_ts_type}"
    for host in "${IP_LIST[@]}"; do
        log "deploy ${TEST_TYPE} runtime to ${host}"
        install_node_runtime_config "${host}"
        remote_reset_dir "${host}" "${TEST_INIT_PATH}"
        remote_copy_contents "${TEST_INIT_PATH}" "${host}" "${TEST_INIT_PATH}"
    done
}

# 功能：为远端节点设置 root 用户密码
change_remote_root_password() {
    local host="$1"

    if remote_iotdb_cli_exec "${host}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh" "show cluster" -u root -pw "${IOTDB_PASSWORD}" >/dev/null 2>&1; then
        return 0
    fi
    remote_iotdb_cli_exec "${host}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh" "ALTER USER root SET PASSWORD '${IOTDB_PASSWORD}';" -u root -pw root >/dev/null 2>&1
}

# 功能：启动单个远端节点的 ConfigNode 和 DataNode
start_remote_iotdb_node() {
    local host="$1"
    local start_confignode=""
    local start_datanode=""
    local heap_dump=""

    printf -v start_confignode '%q' "${TEST_IOTDB_PATH}/sbin/start-confignode.sh"
    printf -v start_datanode '%q' "${TEST_IOTDB_PATH}/sbin/start-datanode.sh"
    printf -v heap_dump '%q' "${TEST_IOTDB_PATH}/dn_dump.hprof"

    log "starting IoTDB ConfigNode on ${host}"
    remote_start_background "${host}" "${start_confignode}"
    sleep 5

    log "starting IoTDB DataNode on ${host}"
    remote_start_background "${host}" "${start_datanode} -H ${heap_dump}"
    sleep "${STARTUP_GRACE_SECONDS}"

    wait_for_remote_iotdb_cluster "${host}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh" "${IOTDB_READY_NODE_COUNT}" ||
        die "IoTDB is not ready on ${host}"
    change_remote_root_password "${host}" ||
        die "failed to set root password on ${host}"
}

# 功能：执行整轮环境重置、部署和节点启动
setup_env() {
    local current_ts_type="$1"
    local host=""

    reboot_test_nodes
    deploy_test_nodes "${current_ts_type}"
    sleep 3

    for host in "${IP_LIST[@]}"; do
        start_remote_iotdb_node "${host}"
    done
}

# 功能：在所有远端节点上启动 benchmark
start_remote_benchmarks() {
    local host=""

    for host in "${IP_LIST[@]}"; do
        log "start benchmark on ${host}"
        remote_clean_benchmark_runtime "${host}" "${TEST_BM_PATH}"
        remote_start_benchmark "${host}" "${TEST_BM_PATH}"
    done
}

# 功能：在测试结束后触发各节点 flush 落盘
flush_test_nodes() {
    local host=""

    for host in "${IP_LIST[@]}"; do
        if [ "${ts_type}" = "tablemode" ]; then
            remote_iotdb_cli_exec "${host}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh" "flush" -u root -pw "${IOTDB_PASSWORD}" -sql_dialect table >/dev/null 2>&1 ||
                log "flush failed on ${host}"
        else
            remote_iotdb_cli_exec "${host}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh" "flush" -u root -pw "${IOTDB_PASSWORD}" >/dev/null 2>&1 ||
                log "flush failed on ${host}"
        fi
    done
}

# 功能：轮询 benchmark 状态并在超时或完成时收口
monitor_test_status() {
    local host=""
    local running_count=0
    local finished_nodes=0
    local active_nodes="${#IP_LIST[@]}"

    while true; do
        if [ $(( $(date +%s) - m_start_time )) -ge "${MONITOR_TIMEOUT_SECONDS}" ]; then
            log "benchmark timed out after ${MONITOR_TIMEOUT_SECONDS}s"
            end_time="$(current_datetime)"
            cost_time=-1
            return 1
        fi

        finished_nodes=0
        for host in "${IP_LIST[@]}"; do
            running_count="$(remote_java_process_count "${host}" App 2>/dev/null || printf '0')"
            if [ "${running_count:-0}" -eq 0 ]; then
                finished_nodes=$((finished_nodes + 1))
            fi
        done

        if [ "${finished_nodes}" -ge "${active_nodes}" ]; then
            flush_test_nodes
            end_time="$(current_datetime)"
            cost_time=$(( $(date +%s) - m_start_time ))
            return 0
        fi

        sleep "${MONITOR_POLL_INTERVAL_SECONDS}"
    done
}

# 功能：采集单个节点在监控窗口内的资源指标
collect_monitor_data() {
    local host="$1"
    local monitor_window_seconds=$((m_end_time - m_start_time))

    [ "${monitor_window_seconds}" -gt 0 ] || monitor_window_seconds=1
    disk_id_regex="^${DEFAULT_DISK_ID}$"
    collect_standard_monitor_snapshot "${host}" "${monitor_window_seconds}"
}

# 功能：拷贝远端节点生成的结果 CSV 到本地
copy_remote_result_csv() {
    local host="$1"
    local output_dir="${TEST_BM_PATH}/TestResult/${host}/csvOutput"

    safe_rm "${output_dir}"
    mkdir -p "${output_dir}"
    scp -r -- "$(remote_target "${host}"):${TEST_BM_PATH}/data/csvOutput/*result.csv" "${output_dir}/" >/dev/null 2>&1 ||
        return 1
    find_result_csv "${output_dir}"
}

# 功能：将一条测试结果写入 MySQL
insert_result_row() {
    local protocol_code="$1"
    local current_os_type="$2"
    local current_jdk_type="$3"
    local current_ts_type="$4"
    local insert_sql=""

    insert_sql=$(cat <<EOF
insert into ${TABLENAME} (
    commit_date_time,test_date_time,commit_id,author,os_type,jdk_type,ts_type,okPoint,okOperation,failPoint,failOperation,
    throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,
    numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,walFileSize,avgCPULoad,maxCPULoad,
    maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark
) values (
    ${commit_date_time},
    ${test_date_time},
    $(sql_quote "${commit_id}"),
    $(sql_quote "${author}"),
    $(sql_quote "${current_os_type}"),
    $(sql_quote "${current_jdk_type}"),
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
    ${protocol_code}
)
EOF
)

    mysql_exec "${insert_sql}"
}

# 功能：解析单个节点的结果并写入结果表
insert_node_result() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local current_jdk_type="$3"
    local node_index="$4"
    local host="${IP_LIST[${node_index}]}"
    local current_os_type="${OS_LIST[${node_index}]}"
    local csv_file=""

    collect_monitor_data "${host}"
    set_standard_negative_benchmark_metrics 0
    csv_file="$(copy_remote_result_csv "${host}" || true)"
    if [ -z "${csv_file}" ] || ! parse_standard_benchmark_result "${csv_file}" INGESTION; then
        log "failed to parse benchmark result on ${host}, writing zero metrics"
        set_standard_negative_benchmark_metrics 0
    fi

    insert_result_row "${protocol_code}" "${current_os_type}" "${current_jdk_type}" "${current_ts_type}"
}

# 功能：批量处理所有节点的测试结果
insert_all_node_results() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local current_jdk_type="$3"
    local node_index=0
    local failed=0

    for ((node_index = 0; node_index < ${#IP_LIST[@]}; node_index++)); do
        insert_node_result "${protocol_code}" "${current_ts_type}" "${current_jdk_type}" "${node_index}" || failed=1
    done
    return "${failed}"
}

# 功能：停止所有远端 IoTDB 节点
stop_remote_iotdb_nodes() {
    local host=""

    for host in "${IP_LIST[@]}"; do
        remote_stop_iotdb_node "${host}" "${TEST_IOTDB_PATH}"
    done
}

# 功能：备份本轮测试产生的配置、日志和结果
backup_test_data() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local current_jdk_type="$3"
    local host=""
    local case_id=""

    case_id="$(backup_build_case_id protocol "${protocol_code}" model "${current_ts_type}" jdk "${current_jdk_type}")"
    backup_begin_case "${case_id}" || return 1
    backup_add benchmark "${TEST_BM_PATH}/TestResult" test-result optional

    for host in "${IP_LIST[@]}"; do
        remote_safe_rm "${host}" "${TEST_IOTDB_PATH}/data" || true
        backup_add_remote "${host}" "${TEST_IOTDB_PATH}" "iotdb-${host}" optional
        backup_add_remote "${host}" "${TEST_BM_PATH}/logs" benchmark-logs optional
        backup_add_remote "${host}" "${TEST_BM_PATH}/data/csvOutput" benchmark-csv optional
    done

    backup_finish_case completed
}

# 功能：执行单个 protocol / ts / jdk 组合的完整测试流程
test_operation_impl() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local current_jdk_type="$3"
    local result_failed=0

    protocol_class_input="${protocol_code}"
    ts_type="${current_ts_type}"
    jdk_type="${current_jdk_type}"

    log "start ${TEST_TYPE}: protocol=${protocol_code}, model=${current_ts_type}, jdk=${current_jdk_type}"
    set_env
    modify_iotdb_config "${current_jdk_type}"
    if ! set_protocol_class "${protocol_code}"; then
        log "invalid protocol code: ${protocol_code}"
        return 1
    fi

    setup_env "${current_ts_type}"
    sleep "${IOTDB_SETTLE_SECONDS}"
    start_remote_benchmarks

    start_time="$(current_datetime)"
    m_start_time="$(date +%s)"
    sleep "${BENCHMARK_WARMUP_SECONDS}"

    if ! monitor_test_status; then
        stop_remote_iotdb_nodes
        return 1
    fi

    m_end_time="$(date +%s)"
    insert_all_node_results "${protocol_code}" "${current_ts_type}" "${current_jdk_type}" || result_failed=1
    stop_remote_iotdb_nodes
    backup_test_data "${protocol_code}" "${current_ts_type}" "${current_jdk_type}" || result_failed=1

    return "${result_failed}"
}

# 功能：领取任务、执行完整矩阵并完成状态收口
main() {
    local protocol=""
    local jdk=""
    local ts=""
    local task_failed=0

    trap restore_test_type_file EXIT
    ensure_runtime_dependencies
    check_password
    validate_matrix
    mkdir -p "${INIT_PATH}"
    check_standard_benchmark_version

    mark_test_in_progress
    log "claim ${TEST_TYPE} task from MySQL"
    if ! claim_next_task; then
        log "no ${TEST_TYPE} task found"
        sleep 60s
        return 0
    fi

    log "current commit ${commit_id} is pending, start test"
    test_date_time="$(date +%Y%m%d%H%M%S)"
    for protocol in "${PROTOCOL_LIST[@]}"; do
        for jdk in "${JDK_LIST[@]}"; do
            for ts in "${TS_LIST[@]}"; do
                init_items
                if ! run_isolated_case test_operation_impl "${protocol}" "${ts}" "${jdk}"; then
                    task_failed=1
                fi
            done
        done
    done

    log "test round ${test_date_time} finished"
    if [ "${task_failed}" -eq 0 ]; then
        finish_task_success
    else
        finish_task_failure
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
