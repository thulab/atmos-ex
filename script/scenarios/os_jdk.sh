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

readonly ACCOUNT="${ACCOUNT:-root}"
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

readonly -a protocol_class=(
    0
    org.apache.iotdb.consensus.simple.SimpleConsensus
    org.apache.iotdb.consensus.ratis.RatisConsensus
    org.apache.iotdb.consensus.iot.IoTConsensus
    org.apache.iotdb.consensus.iot.IoTConsensusV2
)
readonly -a protocol_list=(223)
readonly -a os_list=(ubuntu22 ubuntu24 centos7 centos8)
readonly -a jdk_list=(OpenJDK17 OpenJDK21 TencentKona17 TencentKona21 DragonWell17 DragonWell21)
readonly -a ts_list=(aligned tablemode)
readonly -a IP_list=(0 172.20.70.37 172.20.70.28 172.20.70.39 172.20.70.41)

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
readonly DEFAULT_DISK_ID="${DEFAULT_DISK_ID:-sdb}"
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
    if [ "$(( ${#IP_list[*]} - 1 ))" -ne "${#os_list[*]}" ]; then
        log "IP_list和os_list数量不匹配！"
        exit 1
    fi
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
    local config_file=""
    local -a config_files=(
        "${TEST_IOTDB_PATH}/conf/confignode-env.sh"
        "${TEST_IOTDB_PATH}/conf/datanode-env.sh"
        "${TEST_IOTDB_PATH}/sbin/start-cli.sh"
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
    local i=0
    local t_wait=0

    log "开始重置环境！"
    for ((i = 1; i < ${#IP_list[*]}; i++)); do
        host="${IP_list[$i]}"
        ssh "${ACCOUNT}@${host}" "sudo reboot"
    done
    sleep 120

    for ((i = 1; i < ${#IP_list[*]}; i++)); do
        host="${IP_list[$i]}"
        log "开始部署${host}！"
        log "setting env to ${host} ..."
        ssh "${ACCOUNT}@${host}" "rm -rf ${TEST_INIT_PATH}"
        ssh "${ACCOUNT}@${host}" "mkdir -p ${TEST_INIT_PATH}"
        mv_config_file "${ts_type}"
        rm -rf -- "${TEST_INIT_PATH}/apache-iotdb/activation"
        mkdir -p -- "${TEST_INIT_PATH}/apache-iotdb/activation"
        cp -rf -- "${ATMOS_PATH}/conf/${test_type}/license/${host}" "${TEST_INIT_PATH}/apache-iotdb/activation/license"
        cp -rf -- "${ATMOS_PATH}/conf/${test_type}/env/${host}" "${TEST_INIT_PATH}/apache-iotdb/.env"
        scp -r -- "${TEST_INIT_PATH}/." "${ACCOUNT}@${host}:${TEST_INIT_PATH}/"
    done

    sleep 3
    for ((i = 1; i < ${#IP_list[*]}; i++)); do
        host="${IP_list[$i]}"
        log "starting IoTDB ConfigNode on ${host} ..."
        ssh "${ACCOUNT}@${host}" "${TEST_IOTDB_PATH}/sbin/start-confignode.sh > /dev/null 2>&1 &"
        sleep 5

        log "starting IoTDB DataNode on ${host} ..."
        ssh "${ACCOUNT}@${host}" "${TEST_IOTDB_PATH}/sbin/start-datanode.sh -H ${TEST_IOTDB_PATH}/dn_dump.hprof > /dev/null 2>&1 &"
        sleep 10

        for ((t_wait = 0; t_wait <= 50; t_wait++)); do
            if ssh "${ACCOUNT}@${host}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -e \"show cluster\" | grep -q 'Total line number = 2'"; then
                log "All Nodes is ready"
                ssh "${ACCOUNT}@${host}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -e \"ALTER USER root SET PASSWORD '${IoTDB_PW}';\"" >/dev/null 2>&1
                break
            fi

            log "All Nodes is not ready.Please wait ..."
            sleep 3
        done

        if [ "${t_wait}" -gt 50 ]; then
            log "All Nodes is not ready!"
            exit 1
        fi
    done
}

# 功能：轮询远端 benchmark 状态并在结束后执行 flush
monitor_test_status() {
    local active_nodes=$(( ${#IP_list[*]} - 1 ))
    local elapsed=0
    local finished_nodes=0
    local host=""
    local i=0
    local running_count=""

    while true; do
        elapsed=$(( $(date +%s) - m_start_time ))
        if [ "${elapsed}" -ge "${MONITOR_TIMEOUT_SECONDS}" ]; then
            log "测试失败"
            end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
            cost_time=-1
            return 1
        fi

        finished_nodes=0
        for ((i = 1; i < ${#IP_list[*]}; i++)); do
            host="${IP_list[$i]}"
            running_count="$(ssh "${ACCOUNT}@${host}" "jps | awk '/App/ {count++} END {print count + 0}'" 2>/dev/null || true)"
            if [ "${running_count}" = "1" ]; then
                :
            else
                log "BM写入已结束:${host}"
                finished_nodes=$((finished_nodes + 1))
            fi
        done

        if [ "${finished_nodes}" -ge "${active_nodes}" ]; then
            if [ "${ts_type}" = "tablemode" ]; then
                for ((i = 1; i < ${#IP_list[*]}; i++)); do
                    host="${IP_list[$i]}"
                    ssh "${ACCOUNT}@${host}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -sql_dialect table -e \"flush\"" >/dev/null 2>&1
                done
            else
                for ((i = 1; i < ${#IP_list[*]}; i++)); do
                    host="${IP_list[$i]}"
                    ssh "${ACCOUNT}@${host}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -e \"flush\"" >/dev/null 2>&1
                done
            fi

            end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
            cost_time=$(( $(date +%s) - m_start_time ))
            return 0
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
    local i=0

    sudo rm -rf -- "${backup_dir}"
    sudo mkdir -p -- "${backup_dir}"
    for ((i = 1; i < ${#IP_list[*]}; i++)); do
        host="${IP_list[$i]}"
        sudo mkdir -p -- "${backup_dir}/${host}/"
        ssh "${ACCOUNT}@${host}" "rm -rf ${TEST_IOTDB_PATH}/data" >/dev/null 2>&1 || true
        scp -r -- "${ACCOUNT}@${host}:${TEST_IOTDB_PATH}/" "${backup_dir}/${host}/"
    done
    sudo cp -rf -- "${TEST_BM_PATH}/TestResult/" "${backup_dir}/"
}

# 功能：安装当前时间序列类型对应的 benchmark 配置
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

# 功能：停止所有远端 IoTDB 节点
stop_remote_iotdb_nodes() {
    local host=""
    local i=0

    for ((i = 1; i < ${#IP_list[*]}; i++)); do
        host="${IP_list[$i]}"
        ssh "${ACCOUNT}@${host}" "${TEST_IOTDB_PATH}/sbin/stop-standalone.sh" >/dev/null 2>&1 || true
    done
}

# 功能：在所有远端节点启动 benchmark 写入进程
start_remote_benchmarks() {
    local host=""
    local i=0

    for ((i = 1; i < ${#IP_list[*]}; i++)); do
        host="${IP_list[$i]}"
        log "开始写入！"
        ssh "${ACCOUNT}@${host}" "cd ${TEST_BM_PATH};${TEST_BM_PATH}/benchmark.sh > /dev/null 2>&1 &" >/dev/null 2>&1
    done
}

# 功能：解析单个节点的 benchmark 结果并写入 MySQL
insert_node_result() {
    local node_index="$1"
    local host="${IP_list[$node_index]}"
    local os_name="${os_list[$((node_index - 1))]}"
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

    csv_output_file="$(find "${TEST_BM_PATH}/TestResult/csvOutput" -maxdepth 1 -type f -name '*result.csv' -print -quit 2>/dev/null || true)"
    if [ -n "${csv_output_file}" ]; then
        read -r okOperation okPoint failOperation failPoint throughput <<< "$(awk -F, '/^INGESTION/ {print $2,$3,$4,$5,$6; exit}' "${csv_output_file}")"
        read -r Latency MIN P10 P25 MEDIAN P75 P90 P95 P99 P999 MAX <<< "$(awk -F, '/^INGESTION/ {count++; if (count == 2) print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12}' "${csv_output_file}")"
    fi

    insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,os_type,jdk_type,ts_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,walFileSize,avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${os_name}','${jdk_type}','${ts_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},${walFileSize},${avgCPULoad},${maxCPULoad},${maxDiskIOSizeRead},${maxDiskIOSizeWrite},${maxDiskIOOpsRead},${maxDiskIOOpsWrite},${protocol_class_input})"
    mysql -h"${MYSQLHOSTNAME}" -P"${PORT}" -u"${USERNAME}" -p"${MYSQL_PASSWORD}" "${DBNAME}" -e "${insert_sql}"
}

# 功能：执行单个 protocol、时间序列和 JDK 组合的完整测试
test_operation() {
    protocol_class_input=$1
    ts_type=$2
    jdk_type=$3
    local i=0

    log "开始测试${ts_type}时间序列！"
    set_env
    modify_iotdb_config "${jdk_type}"
    case "${protocol_class_input}" in
        111)
            set_protocol_class 111
            ;;
        222)
            set_protocol_class 222
            ;;
        223)
            set_protocol_class 223
            ;;
        211)
            set_protocol_class 211
            ;;
        224)
            set_protocol_class 224
            ;;
        *)
            log "协议设置错误！"
            return 1
            ;;
    esac

    setup_env
    sleep 60
    start_remote_benchmarks
    start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
    m_start_time=$(date +%s)
    sleep 10
    monitor_test_status
    if [ "${cost_time}" = "-1" ]; then
        stop_remote_iotdb_nodes
        return 1
    fi

    m_end_time=$(date +%s)
    for ((i = 1; i < ${#IP_list[*]}; i++)); do
        rm -rf -- "${TEST_BM_PATH}/TestResult/csvOutput"/*
        mkdir -p -- "${TEST_BM_PATH}/TestResult/csvOutput/"
        scp -r -- "${ACCOUNT}@${IP_list[$i]}:${TEST_BM_PATH}/data/csvOutput/*result.csv" "${TEST_BM_PATH}/TestResult/csvOutput/"
        insert_node_result "${i}"
    done

    stop_remote_iotdb_nodes
    backup_test_data "${ts_type}" "${os_type}" "${jdk_type}"
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
