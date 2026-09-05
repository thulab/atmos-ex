#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
if shopt -oq posix; then
    exec bash "${BASH_SOURCE[0]}" "$@"
fi

set -u
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/common/runtime_common.sh
source "${SCRIPT_DIR}/../common/runtime_common.sh"
# shellcheck source=script/common/benchmark_common.sh
source "${SCRIPT_DIR}/../common/benchmark_common.sh"
# shellcheck source=script/common/protocol_common.sh
source "${SCRIPT_DIR}/../common/protocol_common.sh"
# shellcheck source=script/common/monitor_common.sh
source "${SCRIPT_DIR}/../common/monitor_common.sh"
# shellcheck source=script/common/remote_common.sh
source "${SCRIPT_DIR}/../common/remote_common.sh"

readonly ACCOUNT="${ACCOUNT:-root}"
readonly REMOTE_ACCOUNT="${REMOTE_ACCOUNT:-Administrator}"
readonly IoTDB_PW="${IoTDB_PW:-TimechoDB@2021}"
readonly test_type="${test_type:-os_jdk}"
readonly TEST_TYPE="${TEST_TYPE:-${test_type}}"

readonly INIT_PATH="${INIT_PATH:-/data/atmos/zk_test}"
readonly ATMOS_PATH="${ATMOS_PATH:-${INIT_PATH}/atmos-ex}"
readonly BM_PATH="${BM_PATH:-${INIT_PATH}/iot-benchmark}"
readonly JDK_PATH="${JDK_PATH:-${INIT_PATH}/jdk}"
readonly BUCKUP_PATH="${BUCKUP_PATH:-/nasdata/repository/os_jdk}"
readonly REPOS_PATH="${REPOS_PATH:-/nasdata/repository/master}"
readonly BM_REPOS_PATH="${BM_REPOS_PATH:-/nasdata/repository/iot-benchmark}"

readonly TEST_INIT_PATH="${TEST_INIT_PATH:-/data/atmos/first-rest-test}"
readonly TEST_IOTDB_PATH="${TEST_IOTDB_PATH:-${TEST_INIT_PATH}/apache-iotdb}"
readonly TEST_BM_PATH="${TEST_BM_PATH:-${TEST_INIT_PATH}/iot-benchmark}"
readonly TEST_INIT_PATH_W="D:\\first-rest-test"
readonly TEST_IOTDB_PATH_W="D:\\first-rest-test\\apache-iotdb"
readonly TEST_IOTBM_PATH_W_RP="D:\\first-rest-test\\iot-benchmark\\data\\csvOutput\\*result.csv"
readonly JDK_PATH_W="D:\\jdk"

readonly -a protocol_class=(
    0
    org.apache.iotdb.consensus.simple.SimpleConsensus
    org.apache.iotdb.consensus.ratis.RatisConsensus
    org.apache.iotdb.consensus.iot.IoTConsensus
    org.apache.iotdb.consensus.iot.IoTConsensusV2
)
readonly -a protocol_list=(223)
readonly -a os_list=(0 ubuntu22 ubuntu24 centos7 centos8 WIN16 WIN22)
readonly -a jdk_list=(OpenJDK17 OpenJDK21 TencentKona17 TencentKona21 DragonWell17 DragonWell21)
readonly -a ts_list=(aligned tablemode)
readonly -a IP_list=(0 172.20.70.37 172.20.70.28 172.20.70.39 172.20.70.41 172.20.70.43 172.20.70.50)

readonly MYSQLHOSTNAME="${MYSQLHOSTNAME:-111.200.37.158}"
readonly PORT="${PORT:-13306}"
readonly USERNAME="${USERNAME:-iotdbatm}"
readonly MYSQL_PASSWORD="${ATMOS_DB_PASSWORD:-}"
readonly DBNAME="${DBNAME:-QA_ATM}"
readonly TABLENAME="${TABLENAME:-ex_os_jdk_T}"
readonly TASK_TABLENAME="${TASK_TABLENAME:-commit_history}"
readonly METRIC_SERVER="${METRIC_SERVER:-${metric_server:-111.200.37.158:19090}}"
readonly MONITOR_TIMEOUT_SECONDS="${MONITOR_TIMEOUT_SECONDS:-3600}"
readonly MONITOR_POLL_INTERVAL_SECONDS="${MONITOR_POLL_INTERVAL_SECONDS:-5}"
readonly REMOTE_CONNECT_TIMEOUT_SECONDS="${REMOTE_CONNECT_TIMEOUT_SECONDS:-10}"
readonly REMOTE_REBOOT_GRACE_SECONDS="${REMOTE_REBOOT_GRACE_SECONDS:-120}"
readonly REMOTE_READY_RETRIES="${REMOTE_READY_RETRIES:-60}"
readonly REMOTE_READY_INTERVAL_SECONDS="${REMOTE_READY_INTERVAL_SECONDS:-5}"
readonly DEFAULT_DISK_ID="${DEFAULT_DISK_ID:-vdc}"
readonly -a REMOTE_SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout="${REMOTE_CONNECT_TIMEOUT_SECONDS}")
disk_id_regex="${DEFAULT_DISK_ID}"

commit_id=""
author=""
commit_date_time=""
test_date_time=""
protocol_class_input=""
ts_type=""
jdk_type=""
os_type=0
start_time=""
end_time=""
cost_time=0
m_start_time=0
m_end_time=0
declare -a active_node_indexes=()
declare -a operation_node_indexes=()
declare -a running_node_indexes=()
declare -a completed_node_indexes=()

# 功能：写入测试进行中的状态标记
mark_test_in_progress() {
    printf 'ontesting\n' > "${INIT_PATH}/test_type_file"
}

# 功能：在脚本退出时恢复测试类型状态标记
restore_test_type_file() {
    printf '%s\n' "${test_type}" > "${INIT_PATH}/test_type_file"
}

# 功能：初始化当前测试组合的结果指标
init_items() {
    os_type=0
    jdk_type=0
    ts_type=0
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
    start_time=0
    end_time=0
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
}

# 功能：校验测试节点和操作系统列表是否一一对应
validate_matrix() {
    if [ "${#IP_list[*]}" -ne "${#os_list[*]}" ]; then
        log "IP_list和os_list数量不匹配！"
        exit 1
    fi
}

is_windows_node() {
    local node_index="$1"
    [ "${os_list[$node_index]}" = "WIN16" ] || [ "${os_list[$node_index]}" = "WIN22" ]
}

node_label() {
    local node_index="$1"
    printf '%s/%s' "${IP_list[$node_index]}" "${os_list[$node_index]}"
}

node_is_available() {
    local node_index="$1"
    local host="${IP_list[$node_index]}"

    if is_windows_node "${node_index}"; then
        ssh "${REMOTE_SSH_OPTIONS[@]}" "${REMOTE_ACCOUNT}@${host}" "dir D:" >/dev/null 2>&1
    else
        ssh "${REMOTE_SSH_OPTIONS[@]}" "${ACCOUNT}@${host}" "true" >/dev/null 2>&1
    fi
}

node_iotdb_cluster_ready() {
    local node_index="$1"
    local host="${IP_list[$node_index]}"
    local cluster_output=""

    if is_windows_node "${node_index}"; then
        cluster_output="$(ssh "${REMOTE_SSH_OPTIONS[@]}" "${REMOTE_ACCOUNT}@${host}" \
            "${TEST_IOTDB_PATH_W}\\sbin\\windows\\start-cli.bat -e \"show cluster\"" \
            2>/dev/null || true)"
    else
        cluster_output="$(ssh "${REMOTE_SSH_OPTIONS[@]}" "${ACCOUNT}@${host}" \
            "${TEST_IOTDB_PATH}/sbin/start-cli.sh -e \"show cluster\"" \
            2>/dev/null || true)"
    fi
    grep -Fq 'Total line number = 2' <<< "${cluster_output}"
}

wait_for_node_available() {
    local node_index="$1"
    local attempts="${REMOTE_READY_RETRIES:-60}"
    local interval="${REMOTE_READY_INTERVAL_SECONDS:-5}"
    local attempt=0

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if node_is_available "${node_index}"; then
            return 0
        fi
        sleep "${interval}"
    done
    return 1
}

mark_node_inactive() {
    local failed_node_index="$1"
    local reason="$2"
    local node_index=""
    local -a next_node_indexes=()

    log "skip $(node_label "${failed_node_index}") this round: ${reason}"
    for node_index in "${active_node_indexes[@]}"; do
        [ "${node_index}" = "${failed_node_index}" ] || next_node_indexes+=("${node_index}")
    done
    active_node_indexes=("${next_node_indexes[@]}")

    next_node_indexes=()
    for node_index in "${operation_node_indexes[@]}"; do
        [ "${node_index}" = "${failed_node_index}" ] || next_node_indexes+=("${node_index}")
    done
    operation_node_indexes=("${next_node_indexes[@]}")

    next_node_indexes=()
    for node_index in "${running_node_indexes[@]}"; do
        [ "${node_index}" = "${failed_node_index}" ] || next_node_indexes+=("${node_index}")
    done
    running_node_indexes=("${next_node_indexes[@]}")

    next_node_indexes=()
    for node_index in "${completed_node_indexes[@]}"; do
        [ "${node_index}" = "${failed_node_index}" ] || next_node_indexes+=("${node_index}")
    done
    completed_node_indexes=("${next_node_indexes[@]}")
}

mark_node_completed() {
    local completed_node_index="$1"
    local node_index=""
    local -a next_running_node_indexes=()

    for node_index in "${running_node_indexes[@]}"; do
        [ "${node_index}" = "${completed_node_index}" ] || next_running_node_indexes+=("${node_index}")
    done
    running_node_indexes=("${next_running_node_indexes[@]}")
    if ! contains_value "${completed_node_index}" "${completed_node_indexes[@]}"; then
        completed_node_indexes+=("${completed_node_index}")
    fi
}

discover_active_nodes() {
    local node_index=0

    active_node_indexes=()
    for ((node_index = 1; node_index < ${#IP_list[*]}; node_index++)); do
        if node_is_available "${node_index}"; then
            active_node_indexes+=("${node_index}")
        else
            log "skip $(node_label "${node_index}") this round: server is not reachable"
        fi
    done
    [ "${#active_node_indexes[@]}" -gt 0 ]
}

# 功能：准备当前 commit 对应的 IoTDB 和 benchmark 测试目录
set_env() {
    local source_iotdb="${REPOS_PATH}/${commit_id}/apache-iotdb"

    [ -d "${source_iotdb}" ] || {
        log "缺少IoTDB发行包：${source_iotdb}"
        exit 1
    }

    rm -rf -- "${TEST_INIT_PATH}"
    mkdir -p -- "${TEST_IOTDB_PATH}"
    cp -rf -- "${source_iotdb}/." "${TEST_IOTDB_PATH}/"
    mkdir -p -- "${TEST_IOTDB_PATH}/activation"
    cp -rf -- "${BM_PATH}" "${TEST_INIT_PATH}/"
}

# 功能：按指定 JDK 设置 IoTDB 运行文件的 JAVA_HOME
set_java_home() {
    local JAVA_HOME_TEST="/data/atmos/jdk/$1"
    local JAVA_HOME_TEST_W="D:\\\\jdk\\\\$1"
    local config_file=""
    local -a config_files=(
        "${TEST_IOTDB_PATH}/conf/confignode-env.sh"
        "${TEST_IOTDB_PATH}/conf/datanode-env.sh"
        "${TEST_IOTDB_PATH}/sbin/start-cli.sh"
    )
    local -a config_files_w=(
        "${TEST_IOTDB_PATH}/conf/windows/confignode-env.bat"
        "${TEST_IOTDB_PATH}/conf/windows/datanode-env.bat"
        "${TEST_IOTDB_PATH}/sbin/windows/start-cli.bat"
    )
    for config_file in "${config_files[@]}"; do
        [ -f "${config_file}" ] || {
            log "缺少配置文件：${config_file}"
            exit 1
        }
        if grep -Eq '^#?[[:space:]]*export JAVA_HOME=' "${config_file}"; then
            sed -i "s|^#\?[[:space:]]*export JAVA_HOME=.*$|export JAVA_HOME=${JAVA_HOME_TEST}|g" "${config_file}"
        else
            printf '\nexport JAVA_HOME=%s\n' "${JAVA_HOME_TEST}" >> "${config_file}"
        fi
    done
    for config_file_w in "${config_files_w[@]}"; do
        [ -f "${config_file_w}" ] || {
            log "缺少配置文件：${config_file_w}"
            exit 1
        }
        sed -i "s/^@REM set JAVA_HOME=.*$/set JAVA_HOME=${JAVA_HOME_TEST_W}/g" "${config_file_w}"
	    sed -i "s/^REM set JAVA_HOME=.*$/set JAVA_HOME=${JAVA_HOME_TEST_W}/g" "${config_file_w}"
    done
}

# 功能：按指定 JDK 和测试场景修改 IoTDB 配置
modify_iotdb_config() {
    set_java_home "$1"
    set_iotdb_heap_memory 20G 6G
    apply_iotdb_profile base
}

# 功能：重启远端节点、分发测试文件并启动 IoTDB 集群
setup_env() {
    local host=""
    local node_index=""
    local t_wait=0
    local ready=0

    log "reset available node environments"
    for node_index in "${active_node_indexes[@]}"; do
        host="${IP_list[$node_index]}"
        if is_windows_node "${node_index}"; then
            ssh "${REMOTE_SSH_OPTIONS[@]}" "${REMOTE_ACCOUNT}@${host}" \
                "shutdown /f /r /t 0" >/dev/null 2>&1 || true
        else
            ssh "${REMOTE_SSH_OPTIONS[@]}" "${ACCOUNT}@${host}" \
                "sudo reboot" >/dev/null 2>&1 || true
        fi
    done
    sleep "${REMOTE_REBOOT_GRACE_SECONDS:-120}"

    for node_index in "${active_node_indexes[@]}"; do
        if ! wait_for_node_available "${node_index}"; then
            mark_node_inactive "${node_index}" "server did not return after reboot"
        fi
    done
    [ "${#active_node_indexes[@]}" -gt 0 ] || return 1

    mv_config_file "${ts_type}"
    for node_index in "${active_node_indexes[@]}"; do
        host="${IP_list[$node_index]}"
        rm -rf -- "${TEST_IOTDB_PATH}/activation"
        mkdir -p -- "${TEST_IOTDB_PATH}/activation"
        if ! cp -rf -- "${ATMOS_PATH}/conf/${test_type}/license/${host}" \
            "${TEST_IOTDB_PATH}/activation/license" ||
            ! cp -rf -- "${ATMOS_PATH}/conf/${test_type}/env/${host}" \
            "${TEST_IOTDB_PATH}/.env"; then
            mark_node_inactive "${node_index}" "missing node-specific license or environment"
            continue
        fi
        if is_windows_node "${node_index}"; then
            if ! ssh "${REMOTE_SSH_OPTIONS[@]}" "${REMOTE_ACCOUNT}@${host}" \
                "if exist \"${TEST_INIT_PATH_W}\" rmdir /s /q \"${TEST_INIT_PATH_W}\" & md \"${TEST_INIT_PATH_W}\"" ||
                ! scp "${REMOTE_SSH_OPTIONS[@]}" -r -- "${TEST_INIT_PATH}" \
                "${REMOTE_ACCOUNT}@${host}:D://"; then
                mark_node_inactive "${node_index}" "failed to deploy test files"
            fi
        else
            if ! ssh "${REMOTE_SSH_OPTIONS[@]}" "${ACCOUNT}@${host}" \
                "rm -rf -- ${TEST_INIT_PATH}" ||
                ! scp "${REMOTE_SSH_OPTIONS[@]}" -r -- "${TEST_INIT_PATH}" \
                "${ACCOUNT}@${host}:${TEST_INIT_PATH}/"; then
                mark_node_inactive "${node_index}" "failed to deploy test files"
            fi
        fi
    done

    [ "${#active_node_indexes[@]}" -gt 0 ] || return 1
    sleep 3
    for node_index in "${active_node_indexes[@]}"; do
        host="${IP_list[$node_index]}"
        ready=0
        t_wait=0
        log "starting IoTDB on ${host}"
        if is_windows_node "${node_index}"; then
            if ! ssh "${REMOTE_SSH_OPTIONS[@]}" "${REMOTE_ACCOUNT}@${host}" \
                "schtasks /Run /TN \"run_iotdb\"" >/dev/null 2>&1; then
                mark_node_inactive "${node_index}" "failed to start IoTDB"
                continue
            fi
            sleep 20
            for ((t_wait = 0; t_wait <= 50; t_wait++)); do
                if node_iotdb_cluster_ready "${node_index}"; then
                    ready=1
                    break
                fi
                sleep 3
            done
            if [ "${ready}" -eq 1 ]; then
                ssh "${REMOTE_SSH_OPTIONS[@]}" "${REMOTE_ACCOUNT}@${host}" \
                    "${TEST_IOTDB_PATH_W}\\sbin\\windows\\start-cli.bat -e \"ALTER USER root SET PASSWORD '${IoTDB_PW}';\"" \
                    >/dev/null 2>&1 || true
            fi
        else
            if ! ssh "${REMOTE_SSH_OPTIONS[@]}" "${ACCOUNT}@${host}" \
                "${TEST_IOTDB_PATH}/sbin/start-confignode.sh > /dev/null 2>&1 &"; then
                mark_node_inactive "${node_index}" "failed to start ConfigNode"
                continue
            fi
            sleep 5
            if ! ssh "${REMOTE_SSH_OPTIONS[@]}" "${ACCOUNT}@${host}" \
                "${TEST_IOTDB_PATH}/sbin/start-datanode.sh -H ${TEST_IOTDB_PATH}/dn_dump.hprof > /dev/null 2>&1 &"; then
                mark_node_inactive "${node_index}" "failed to start DataNode"
                continue
            fi
            sleep 10
            for ((t_wait = 0; t_wait <= 50; t_wait++)); do
                if node_iotdb_cluster_ready "${node_index}"; then
                    ready=1
                    break
                fi
                sleep 3
            done
            if [ "${ready}" -eq 1 ]; then
                ssh "${REMOTE_SSH_OPTIONS[@]}" "${ACCOUNT}@${host}" \
                    "${TEST_IOTDB_PATH}/sbin/start-cli.sh -e \"ALTER USER root SET PASSWORD '${IoTDB_PW}';\"" \
                    >/dev/null 2>&1 || true
            fi
        fi
        if [ "${ready}" -ne 1 ]; then
            mark_node_inactive "${node_index}" "IoTDB cluster did not become ready"
        fi
    done

    [ "${#active_node_indexes[@]}" -gt 0 ]
}

# 功能：在已完成节点上执行 flush
flush_completed_nodes() {
    local node_index=""
    local host=""
    local flush_status=0

    for node_index in "${completed_node_indexes[@]}"; do
        host="${IP_list[$node_index]}"
        if ! node_is_available "${node_index}"; then
            mark_node_inactive "${node_index}" "server became unreachable before flush"
            continue
        fi
        flush_status=0
        if is_windows_node "${node_index}"; then
            if [ "${ts_type}" = "tablemode" ]; then
                ssh "${REMOTE_SSH_OPTIONS[@]}" "${REMOTE_ACCOUNT}@${host}" \
                    "${TEST_IOTDB_PATH_W}\\sbin\\windows\\start-cli.bat -u root -pw ${IoTDB_PW} -sql_dialect table -e \"flush;\"" \
                    >/dev/null 2>&1 || flush_status=$?
            else
                ssh "${REMOTE_SSH_OPTIONS[@]}" "${REMOTE_ACCOUNT}@${host}" \
                    "${TEST_IOTDB_PATH_W}\\sbin\\windows\\start-cli.bat -u root -pw ${IoTDB_PW} -e \"flush;\"" \
                    >/dev/null 2>&1 || flush_status=$?
            fi
        else
            if [ "${ts_type}" = "tablemode" ]; then
                ssh "${REMOTE_SSH_OPTIONS[@]}" "${ACCOUNT}@${host}" \
                    "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -sql_dialect table -e \"flush\"" \
                    >/dev/null 2>&1 || flush_status=$?
            else
                ssh "${REMOTE_SSH_OPTIONS[@]}" "${ACCOUNT}@${host}" \
                    "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -e \"flush\"" \
                    >/dev/null 2>&1 || flush_status=$?
            fi
        fi
        if [ "${flush_status}" -ne 0 ]; then
            if node_is_available "${node_index}"; then
                log "flush failed on ${host}; keep completed result for collection"
            else
                mark_node_inactive "${node_index}" "server became unreachable during flush"
            fi
        fi
    done
    [ "${#completed_node_indexes[@]}" -gt 0 ]
}

monitor_test_status() {
    local elapsed=0
    local host=""
    local node_index=""
    local running_count=""

    while true; do
        elapsed=$(( $(date +%s) - m_start_time ))
        if [ "${elapsed}" -ge "${MONITOR_TIMEOUT_SECONDS}" ]; then
            log "benchmark monitor timed out; dropping unfinished nodes"
            for node_index in "${running_node_indexes[@]}"; do
                mark_node_inactive "${node_index}" "benchmark timed out"
            done
            m_end_time=$(date +%s)
            cost_time="${elapsed}"
            if flush_completed_nodes; then
                end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
                return 0
            fi
            cost_time=-1
            end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
            return 1
        fi

        for node_index in "${running_node_indexes[@]}"; do
            host="${IP_list[$node_index]}"
            if ! node_is_available "${node_index}"; then
                mark_node_inactive "${node_index}" "server became unreachable during benchmark"
                continue
            fi

            if is_windows_node "${node_index}"; then
                if ssh "${REMOTE_SSH_OPTIONS[@]}" "${REMOTE_ACCOUNT}@${host}" \
                    "dir ${TEST_IOTBM_PATH_W_RP}" >/dev/null 2>&1; then
                    log "benchmark finished on ${host}"
                    mark_node_completed "${node_index}"
                fi
            else
                running_count="$(ssh "${REMOTE_SSH_OPTIONS[@]}" "${ACCOUNT}@${host}" \
                    "jps | awk '/App/ {count++} END {print count + 0}'" 2>/dev/null || true)"
                running_count="$(trim "${running_count}")"
                if [[ "${running_count}" =~ ^[0-9]+$ ]]; then
                    if [ "${running_count}" -eq 0 ]; then
                        log "benchmark finished on ${host}"
                        mark_node_completed "${node_index}"
                    fi
                else
                    mark_node_inactive "${node_index}" "failed to query benchmark status"
                fi
            fi
        done

        if [ "${#running_node_indexes[@]}" -eq 0 ]; then
            m_end_time=$(date +%s)
            cost_time=$((m_end_time - m_start_time))
            if flush_completed_nodes; then
                end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
                return 0
            fi
            cost_time=-1
            end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
            return 1
        fi
        sleep "${MONITOR_POLL_INTERVAL_SECONDS}"
    done
}

# 功能：备份本轮测试产生的 IoTDB 和 benchmark 数据
backup_test_data() {
    local ts_value="$1"
    local os_value="$2"
    local jdk_value="$3"
    local backup_dir="${BUCKUP_PATH}/${commit_date_time}_${commit_id}_${protocol_class_input}/${ts_value}/${os_value}/${jdk_value}"
    local host=""
    local node_index=""

    sudo rm -rf -- "${backup_dir}"
    sudo mkdir -p -- "${backup_dir}"
    for node_index in "${operation_node_indexes[@]}"; do
        host="${IP_list[$node_index]}"
        if ! node_is_available "${node_index}"; then
            log "skip backup for ${host}: server is not reachable"
            continue
        fi
        sudo mkdir -p -- "${backup_dir}/${host}/"
        if is_windows_node "${node_index}"; then
            ssh "${REMOTE_SSH_OPTIONS[@]}" "${REMOTE_ACCOUNT}@${host}" \
                "rmdir /s /q ${TEST_IOTDB_PATH_W}/data" >/dev/null 2>&1 || true
            scp "${REMOTE_SSH_OPTIONS[@]}" -r -- \
                "${REMOTE_ACCOUNT}@${host}:${TEST_IOTDB_PATH_W}/logs" \
                "${backup_dir}/${host}/" >/dev/null 2>&1 || true
        else
            ssh "${REMOTE_SSH_OPTIONS[@]}" "${ACCOUNT}@${host}" \
                "rm -rf ${TEST_IOTDB_PATH}/data" >/dev/null 2>&1 || true
            scp "${REMOTE_SSH_OPTIONS[@]}" -r -- \
                "${ACCOUNT}@${host}:${TEST_IOTDB_PATH}/logs" \
                "${backup_dir}/${host}/" >/dev/null 2>&1 || true
        fi
    done
    sudo cp -rf -- "${TEST_BM_PATH}/TestResult/" "${backup_dir}/" >/dev/null 2>&1 || true
}

mv_config_file() {
    local current_ts_type="$1"
    local source_config="${ATMOS_PATH}/conf/${test_type}/benchmark/${current_ts_type}"

    [ -f "${source_config}" ] || {
        log "缺少benchmark配置：${source_config}"
        exit 1
    }

    rm -rf -- "${TEST_BM_PATH}/conf/config.properties"
    cp -rf -- "${source_config}" "${TEST_BM_PATH}/conf/config.properties"
}

# 功能：停止本轮仍可连接的远端 IoTDB 节点
stop_remote_iotdb_nodes() {
    local host=""
    local node_index=""

    for node_index in "${operation_node_indexes[@]}"; do
        host="${IP_list[$node_index]}"
        if ! node_is_available "${node_index}"; then
            log "skip stop for ${host}: server is not reachable"
            continue
        fi
        if is_windows_node "${node_index}"; then
            ssh "${REMOTE_SSH_OPTIONS[@]}" "${REMOTE_ACCOUNT}@${host}" \
                "${TEST_IOTDB_PATH_W}\\sbin\\windows\\stop-standalone.bat" \
                >/dev/null 2>&1 || true
        else
            ssh "${REMOTE_SSH_OPTIONS[@]}" "${ACCOUNT}@${host}" \
                "${TEST_IOTDB_PATH}/sbin/stop-standalone.sh" \
                >/dev/null 2>&1 || true
        fi
    done
}

# 功能：在本轮仍可用的远端节点启动 benchmark
start_remote_benchmarks() {
    local host=""
    local node_index=""

    running_node_indexes=()
    completed_node_indexes=()
    for node_index in "${active_node_indexes[@]}"; do
        host="${IP_list[$node_index]}"
        if ! node_is_available "${node_index}"; then
            mark_node_inactive "${node_index}" "server is not reachable before benchmark start"
            continue
        fi
        log "start benchmark on ${host}"
        if is_windows_node "${node_index}"; then
            if ssh "${REMOTE_SSH_OPTIONS[@]}" "${REMOTE_ACCOUNT}@${host}" \
                "schtasks /Run /TN \"run_test\"" >/dev/null 2>&1; then
                running_node_indexes+=("${node_index}")
            else
                mark_node_inactive "${node_index}" "failed to start benchmark"
            fi
        elif ssh "${REMOTE_SSH_OPTIONS[@]}" "${ACCOUNT}@${host}" \
            "cd ${TEST_BM_PATH} && ${TEST_BM_PATH}/benchmark.sh > /dev/null 2>&1 &" \
            >/dev/null 2>&1; then
            running_node_indexes+=("${node_index}")
        else
            mark_node_inactive "${node_index}" "failed to start benchmark"
        fi
    done
    [ "${#running_node_indexes[@]}" -gt 0 ]
}

insert_node_result() {
    local node_index="$1"
    local host="${IP_list[$node_index]}"
    local os_name="${os_list[$node_index]}"
    local csv_output_file=""
    local insert_sql=""

    collect_standard_monitor_snapshot "${host}" "$((m_end_time - m_start_time))"
    okOperation=0
    okPoint=0
    failOperation=0
    failPoint=0
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

    csv_output_file="$(find_result_csv "${TEST_BM_PATH}/TestResult/csvOutput" || true)"
    if [ -z "${csv_output_file}" ]; then
        log "missing benchmark result for ${host}"
        return 1
    fi
    if ! parse_standard_benchmark_result "${csv_output_file}"; then
        log "failed to parse benchmark result for ${host}: ${csv_output_file}"
        return 1
    fi

    insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,os_type,jdk_type,ts_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,walFileSize,avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${os_name}','${jdk_type}','${ts_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},${walFileSize},${avgCPULoad},${maxCPULoad},${maxDiskIOSizeRead},${maxDiskIOSizeWrite},${maxDiskIOOpsRead},${maxDiskIOOpsWrite},${protocol_class_input})"
    mysql -h"${MYSQLHOSTNAME}" -P"${PORT}" -u"${USERNAME}" -p"${MYSQL_PASSWORD}" "${DBNAME}" -e "${insert_sql}"
}

# 功能：执行单个组合，并隔离不可用节点
test_operation() {
    protocol_class_input="$1"
    ts_type="$2"
    jdk_type="$3"
    local host=""
    local node_index=""

    if [ "${#active_node_indexes[@]}" -eq 0 ]; then
        log "no reachable node for ${ts_type}/${jdk_type}; skip this combination"
        return 0
    fi

    operation_node_indexes=("${active_node_indexes[@]}")
    running_node_indexes=()
    completed_node_indexes=()

    log "start ${ts_type}/${jdk_type} on ${#operation_node_indexes[@]} reachable nodes"
    set_env
    modify_iotdb_config "${jdk_type}"
    if ! set_protocol_class "${protocol_class_input}"; then
        log "invalid protocol ${protocol_class_input}"
        return 0
    fi

    if ! setup_env; then
        stop_remote_iotdb_nodes
        backup_test_data "${ts_type}" "${os_type}" "${jdk_type}"
        return 0
    fi

    sleep 60
    if ! start_remote_benchmarks; then
        stop_remote_iotdb_nodes
        backup_test_data "${ts_type}" "${os_type}" "${jdk_type}"
        return 0
    fi

    start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
    m_start_time=$(date +%s)
    sleep 10
    monitor_test_status || true

    m_end_time=$(date +%s)
    for node_index in "${completed_node_indexes[@]}"; do
        host="${IP_list[$node_index]}"
        rm -rf -- "${TEST_BM_PATH}/TestResult/csvOutput"/*
        mkdir -p -- "${TEST_BM_PATH}/TestResult/csvOutput"

        if is_windows_node "${node_index}"; then
            if ! scp "${REMOTE_SSH_OPTIONS[@]}" -r -- \
                "${REMOTE_ACCOUNT}@${host}:${TEST_IOTBM_PATH_W_RP}" \
                "${TEST_BM_PATH}/TestResult/csvOutput/"; then
                mark_node_inactive "${node_index}" "failed to fetch benchmark result"
                continue
            fi
        elif ! scp "${REMOTE_SSH_OPTIONS[@]}" -r -- \
            "${ACCOUNT}@${host}:${TEST_BM_PATH}/data/csvOutput/*result.csv" \
            "${TEST_BM_PATH}/TestResult/csvOutput/"; then
            mark_node_inactive "${node_index}" "failed to fetch benchmark result"
            continue
        fi

        if insert_node_result "${node_index}"; then
            log "stored benchmark result for ${host}"
        else
            mark_node_inactive "${node_index}" "result missing, invalid, or database insert failed"
        fi
    done

    stop_remote_iotdb_nodes
    backup_test_data "${ts_type}" "${os_type}" "${jdk_type}"
    return 0
}

# 功能：按指定条件获取一条测试任务
fetch_commit_task() {
    local where_clause="$1"
    local query_sql=""
    local result_string=""

    query_sql="SELECT commit_id, author, commit_date_time FROM ${TASK_TABLENAME} WHERE ${where_clause} ORDER BY commit_date_time desc limit 1"
    result_string="$(mysql -N -B -h"${MYSQLHOSTNAME}" -P"${PORT}" -u"${USERNAME}" -p"${MYSQL_PASSWORD}" "${DBNAME}" -e "${query_sql}")"
    if [ -z "${result_string}" ]; then
        return 1
    fi

    commit_id="$(printf '%s\n' "${result_string}" | awk -F'\t' 'NR == 1 {print $1}')"
    author="$(printf '%s\n' "${result_string}" | awk -F'\t' 'NR == 1 {print $2}')"
    commit_date_time="$(printf '%s\n' "${result_string}" | awk -F'\t' 'NR == 1 {gsub(/[- :]/, "", $3); print $3}')"
}

# 功能：更新测试任务状态
update_task_status() {
    local task_state="$1"
    local where_clause="${2:-commit_id = '${commit_id}'}"
    local update_sql=""

    update_sql="update ${TASK_TABLENAME} set ${test_type} = '${task_state}' where ${where_clause}"
    mysql -h"${MYSQLHOSTNAME}" -P"${PORT}" -u"${USERNAME}" -p"${MYSQL_PASSWORD}" "${DBNAME}" -e "${update_sql}"
}

check_password
mkdir -p "${INIT_PATH}"
trap restore_test_type_file EXIT
mark_test_in_progress
validate_matrix
check_standard_benchmark_version
if ! fetch_commit_task "${test_type} = 'retest'"; then
    if ! fetch_commit_task "${test_type} is NULL"; then
        sleep 60
        exit 0
    fi
fi

update_task_status "ontesting"
if ! discover_active_nodes; then
    log "no reachable OS/JDK node; complete this task without running tests"
    update_task_status "done"
    exit 0
fi
log "当前版本${commit_id}未执行过测试，即将编译后启动"
test_date_time=$(date +%Y%m%d%H%M%S)
for protocol in "${protocol_list[@]}"; do
    for jdk in "${jdk_list[@]}"; do
        for ts in "${ts_list[@]}"; do
            init_items
            log "开始测试${protocol}协议下的${ts}时间序列在${jdk}环境下写入吞吐！"
            test_operation "${protocol}" "${ts}" "${jdk}"
        done
    done
done
log "本轮测试${test_date_time}已结束."
update_task_status "done"
update_task_status "skip" "${test_type} is NULL and commit_date_time < '${commit_date_time}'"
