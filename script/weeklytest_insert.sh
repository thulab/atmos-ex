#!/usr/bin/env bash
set -o pipefail

set_iotdb_property() {
    local properties_file="$1"
    local property_name="$2"
    local property_value="$3"
    local temp_file="${properties_file}.tmp.$$"

    [ -f "${properties_file}" ] || {
        printf '[ERROR] missing properties file: %s\n' "${properties_file}" >&2
        return 1
    }
    awk -F= -v key="${property_name}" -v value="${property_value}" '
        BEGIN { updated = 0 }
        $1 == key {
            if (!updated) {
                print key "=" value
                updated = 1
            }
            next
        }
        { print }
        END {
            if (!updated) {
                print key "=" value
            }
        }
    ' "${properties_file}" > "${temp_file}" &&
        mv -- "${temp_file}" "${properties_file}"
}
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
if shopt -oq posix; then
    exec bash "${BASH_SOURCE[0]}" "$@"
fi
# ----------------------------------------------------------------------------
# IoTDB WeeklyTest Insert Script (Based on se_insert.sh)
# ----------------------------------------------------------------------------
# Author: qingxin.feng
# Description: 自动化执行IoTDB weeklytest_insert写入测试，结构与se_insert.sh完全一致。
# ------------------------------------------------------------------------------

# -------------------- 基础环境变量 --------------------
TEST_IP="11.101.17.111"           # 测试服务器IP
ACCOUNT=atmos                     # 登录用户名
IOTDB_PASSWORD="${IOTDB_PASSWORD:-TimechoDB@2021}"
TEST_TYPE="${TEST_TYPE:-weeklytest_insert}"

# -------------------- 路径相关变量 --------------------
INIT_PATH="${INIT_PATH:-/data/atmos/zk_test}"  # 初始环境存放路径
ATMOS_PATH=${INIT_PATH}/atmos-ex
BM_PATH=${INIT_PATH}/iot-benchmark
BACKUP_PATH="${BACKUP_PATH:-/nasdata/repository/weeklytest_insert}"
REPOS_PATH="${REPOS_PATH:-/nasdata/repository/master}"
TEST_INIT_PATH="${TEST_INIT_PATH:-/data/atmos}"
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb

# -------------------- 协议相关变量 --------------------
# 1. org.apache.iotdb.consensus.simple.SimpleConsensus
# 2. org.apache.iotdb.consensus.ratis.RatisConsensus
# 3. org.apache.iotdb.consensus.iot.IoTConsensus
protocol_class=(0 org.apache.iotdb.consensus.simple.SimpleConsensus org.apache.iotdb.consensus.ratis.RatisConsensus org.apache.iotdb.consensus.iot.IoTConsensus org.apache.iotdb.consensus.iot.IoTConsensusV2)
protocol_list=(223 224)
ts_list=(seq_w unseq_w tablemode_seq_w tablemode_unseq_w)

# -------------------- MySQL 配置信息 --------------------
MYSQL_HOST="${MYSQL_HOST:-111.200.37.158}"
MYSQL_PORT="${MYSQL_PORT:-13306}"
MYSQL_USERNAME="${MYSQL_USERNAME:-iotdbatm}"
MYSQL_PASSWORD="${ATMOS_DB_PASSWORD:-}"     # 密码
DBNAME="${DBNAME:-QA_ATM}"
TABLENAME="ex_weeklytest_insert" # 结果表名
TABLENAME_T="ex_weeklytest_insert_T" # 企业版结果表名
TASK_TABLENAME="ex_commit_history" # 数据库中任务表的名称

# -------------------- Prometheus 配置信息 --------------------
METRIC_SERVER="${METRIC_SERVER:-111.200.37.158:19090}"
MONITOR_TIMEOUT_SECONDS=${MONITOR_TIMEOUT_SECONDS:-7200}
MONITOR_POLL_INTERVAL_SECONDS=${MONITOR_POLL_INTERVAL_SECONDS:-10}

# -------------------- 公用函数 --------------------
check_password() {
    if [ -z "${MYSQL_PASSWORD}" ]; then
        printf '[ERROR] ATMOS_DB_PASSWORD is required\n' >&2
        return 1
    fi
}

current_datetime() {
    date +"%Y-%m-%d %H:%M:%S"
}

datetime_to_epoch() {
    date -d "$1" +%s
}

git_commit_abbrev() {
    awk -F= '/git.commit.id.abbrev/ {print $2; exit}' "$1" 2>/dev/null
}

find_result_csv() {
    find "${BM_PATH}/data/csvOutput" -type f -name "*result.csv" -print -quit 2>/dev/null
}

create_stuck_result_csv() {
    local result_label="${1:-INGESTION}"
    local csv_file="${BM_PATH}/data/csvOutput/Stuck_result.csv"
    local index=0

    result_label="${result_label%,}"
    mkdir -p "${csv_file%/*}"
    : > "${csv_file}"
    for ((index = 0; index < 100; index++)); do
        echo "${result_label}, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1" >> "${csv_file}"
    done
}

bytes_to_gib() {
    awk -v value="${1:-0}" 'BEGIN { printf "%.2f\n", value / 1073741824 }'
}

to_int() {
    awk -v value="${1:-0}" 'BEGIN { printf "%d\n", value }'
}

set_negative_benchmark_metrics() {
    local value=$1
    okPoint=${value}
    okOperation=${value}
    failPoint=${value}
    failOperation=${value}
    throughput=${value}
    Latency=${value}
    MIN=${value}
    P10=${value}
    P25=${value}
    MEDIAN=${value}
    P75=${value}
    P90=${value}
    P95=${value}
    P99=${value}
    P999=${value}
    MAX=${value}
}

parse_benchmark_result() {
    local csv_file=$1
    local result_label="${2:-INGESTION}"
    local throughput_line=""
    local latency_line=""

    [ -f "${csv_file}" ] || return 1
    result_label="${result_label%,}"
    throughput_line=$(awk -F, -v label="${result_label}" '
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
    ' OFS=$'\t' "${csv_file}")

    latency_line=$(awk -F, -v label="${result_label}" '
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
    ' OFS=$'\t' "${csv_file}")

    [ -n "${throughput_line}" ] || return 1
    [ -n "${latency_line}" ] || return 1
    IFS=$'\t' read -r okOperation okPoint failOperation failPoint throughput <<< "${throughput_line}"
    IFS=$'\t' read -r Latency MIN P10 P25 MEDIAN P75 P90 P95 P99 P999 MAX <<< "${latency_line}"
}

check_benchmark_version() {
    BM_REPOS_PATH=/nasdata/repository/iot-benchmark
    BM_NEW=$(git_commit_abbrev "${BM_REPOS_PATH}/git.properties")
    BM_OLD=$(git_commit_abbrev "${BM_PATH}/git.properties")
    if [ -n "${BM_NEW}" ] && { [ ! -d "${BM_PATH}" ] || [ "${BM_OLD}" != "${BM_NEW}" ]; }; then
        rm -rf "${BM_PATH}"
        cp -rf "${BM_REPOS_PATH}" "${BM_PATH}"
    fi
}

init_items() {
    # 定义监控采集项初始值
    ts_type=0; okPoint=0; okOperation=0; failPoint=0; failOperation=0
    throughput=0; Latency=0; MIN=0; P10=0; P25=0; MEDIAN=0; P75=0; P90=0; P95=0; P99=0; P999=0; MAX=0
    numOfSe0Level=0; start_time=0; end_time=0; cost_time=0; numOfUnse0Level=0; dataFileSize=0
    maxNumofOpenFiles=0; maxNumofThread=0; errorLogSize=0; walFileSize=0; maxCPULoad=0; avgCPULoad=0
    maxDiskIOOpsRead=0; maxDiskIOOpsWrite=0; maxDiskIOSizeRead=0; maxDiskIOSizeWrite=0
}

sendEmail() {
    sendEmail=$(${TOOLS_PATH}/sendEmail.sh $1 >/dev/null 2>&1 &)
}

check_pid_and_kill() {
    local pname=$1
    local desc=$2
    local pid=$(jps | awk -v pname="$pname" '$2 == pname {print $1}')
    if [ -n "$pid" ]; then
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        kill -KILL "$pid" 2>/dev/null || true
        echo "$desc 已停止！"
    else
        echo "未检测到$desc！"
    fi
}

check_benchmark_pid() { check_pid_and_kill "App" "BM程序"; }
check_iotdb_pid() {
    check_pid_and_kill "DataNode" "DataNode程序"
    check_pid_and_kill "ConfigNode" "ConfigNode程序"
    check_pid_and_kill "IoTDB" "IoTDB程序"
    echo "程序检测和清理操作已完成！"
}

set_env() {
    [ -d "${TEST_IOTDB_PATH}" ] && rm -rf ${TEST_IOTDB_PATH}
    mkdir -p ${TEST_IOTDB_PATH}/activation
    cp -rf ${REPOS_PATH}/${commit_id}/apache-iotdb/* ${TEST_IOTDB_PATH}/
    cp -rf ${ATMOS_PATH}/conf/${TEST_TYPE}/license ${TEST_IOTDB_PATH}/activation/
    cp -rf ${ATMOS_PATH}/conf/${TEST_TYPE}/env ${TEST_IOTDB_PATH}/.env
}

modify_iotdb_config() {
    #修改IoTDB的配置
    sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"20G\"/g" ${TEST_IOTDB_PATH}/conf/datanode-env.sh
    #清空配置文件
    # echo "只保留要修改的参数" > ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
    #关闭影响写入性能的其他功能
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "enable_seq_space_compaction" "false"
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "enable_unseq_space_compaction" "false"
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "enable_cross_space_compaction" "false"
    #修改集群名称
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "cluster_name" "${TEST_TYPE}"
    #添加启动监控功能
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "cn_enable_metric" "true"
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "cn_enable_performance_stat" "true"
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "cn_metric_reporter_list" "PROMETHEUS"
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "cn_metric_level" "ALL"
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "cn_metric_prometheus_reporter_port" "9081"
    #添加启动监控功能
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "dn_enable_metric" "true"
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "dn_enable_performance_stat" "true"
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "dn_metric_reporter_list" "PROMETHEUS"
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "dn_metric_level" "ALL"
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "dn_metric_prometheus_reporter_port" "9091"
}

set_protocol_class() {
    local config_node=$1; local schema_region=$2; local data_region=$3
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "config_node_consensus_protocol_class" "${protocol_class[${config_node}]}"
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "schema_region_consensus_protocol_class" "${protocol_class[${schema_region}]}"
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "data_region_consensus_protocol_class" "${protocol_class[${data_region}]}"
}

start_iotdb() {
    (cd "${TEST_IOTDB_PATH}" && ./sbin/start-confignode.sh >/dev/null 2>&1 &)
    sleep 10
    (cd "${TEST_IOTDB_PATH}" && ./sbin/start-datanode.sh -H "${TEST_IOTDB_PATH}/dn_dump.hprof" >/dev/null 2>&1 &)
}

stop_iotdb() {
    (cd "${TEST_IOTDB_PATH}" && ./sbin/stop-datanode.sh >/dev/null 2>&1 &)
    sleep 10
    (cd "${TEST_IOTDB_PATH}" && ./sbin/stop-confignode.sh >/dev/null 2>&1 &)
}

start_benchmark() {
    rm -rf "${BM_PATH}/logs" "${BM_PATH}/data"
    (cd "${BM_PATH}" && ./benchmark.sh >/dev/null 2>&1 &)
}

monitor_test_status() {
    local result_label="${1:-INGESTION}"
    local csv_file=""
    local now_epoch=0
    local elapsed=0

    while true; do
        csv_file=$(find_result_csv || true)
        if [ -n "${csv_file}" ]; then
            end_time=$(current_datetime)
            echo "${ts_type} benchmark completed."
            return 0
        fi

        now_epoch=$(date +%s)
        elapsed=$((now_epoch - m_start_time))
        if [ "${elapsed}" -ge "${MONITOR_TIMEOUT_SECONDS}" ]; then
            end_time=$(current_datetime)
            echo "${ts_type} benchmark timed out."
            create_stuck_result_csv "${result_label}"
            return 1
        fi

        sleep "${MONITOR_POLL_INTERVAL_SECONDS}"
    done
}

get_single_index() {
    local query=$1; local end=$2
    local index_value=$(curl -G -s "http://${METRIC_SERVER}/api/v1/query" --data-urlencode "query=${query}" --data-urlencode "time=${end}" | jq -r '.data.result[0].value[1] // 0')
    if [[ "$index_value" == "null" || -z "$index_value" ]]; then 
        index_value=0
    fi
    echo "$index_value"
}

collect_monitor_data() {
    local ip=$1
    local metric_window=$((m_end_time-m_start_time))
    local maxNumofThread_C=0
    local maxNumofThread_D=0

    [ "${metric_window}" -gt 0 ] || metric_window=1
    dataFileSize=$(get_single_index "sum(file_global_size{instance=~\"${ip}:9091\"})" $m_end_time)
    dataFileSize=$(bytes_to_gib "${dataFileSize}")
    numOfSe0Level=$(get_single_index "sum(file_global_count{instance=~\"${ip}:9091\",name=\"seq\"})" $m_end_time)
    numOfUnse0Level=$(get_single_index "sum(file_global_count{instance=~\"${ip}:9091\",name=\"unseq\"})" $m_end_time)
    maxNumofThread_C=$(get_single_index "max_over_time(process_threads_count{instance=~\"${ip}:9081\"}[${metric_window}s])" $m_end_time)
    maxNumofThread_D=$(get_single_index "max_over_time(process_threads_count{instance=~\"${ip}:9091\"}[${metric_window}s])" $m_end_time)
    maxNumofThread=$(( $(to_int "${maxNumofThread_C}") + $(to_int "${maxNumofThread_D}") ))
    maxNumofOpenFiles=$(get_single_index "max_over_time(file_count{instance=~\"${ip}:9091\",name=\"open_file_handlers\"}[${metric_window}s])" $m_end_time)
    walFileSize=$(get_single_index "max_over_time(file_size{instance=~\"${ip}:9091\",name=~\"wal\"}[${metric_window}s])" $m_end_time)
    walFileSize=$(bytes_to_gib "${walFileSize}")
    maxCPULoad=$(get_single_index "max_over_time(sys_cpu_load{instance=~\"${ip}:9091\"}[${metric_window}s])" $m_end_time)
    avgCPULoad=$(get_single_index "avg_over_time(sys_cpu_load{instance=~\"${ip}:9091\"}[${metric_window}s])" $m_end_time)
    maxDiskIOOpsRead=$(get_single_index "rate(disk_io_ops{instance=~\"${ip}:9091\",disk_id=~\"sdb\",type=~\"read\"}[${metric_window}s])" $m_end_time)
    maxDiskIOOpsWrite=$(get_single_index "rate(disk_io_ops{instance=~\"${ip}:9091\",disk_id=~\"sdb\",type=~\"write\"}[${metric_window}s])" $m_end_time)
    maxDiskIOSizeRead=$(get_single_index "rate(disk_io_size{instance=~\"${ip}:9091\",disk_id=~\"sdb\",type=~\"read\"}[${metric_window}s])" $m_end_time)
    maxDiskIOSizeWrite=$(get_single_index "rate(disk_io_size{instance=~\"${ip}:9091\",disk_id=~\"sdb\",type=~\"write\"}[${metric_window}s])" $m_end_time)
}

backup_test_data() {
    local ts_type=$1
    local backup_dir="${BACKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${protocol_class}"
    sudo rm -rf -- "${backup_dir:?}"
    sudo mkdir -p $backup_dir
    sudo rm -rf -- "${TEST_IOTDB_PATH}/data"
    sudo mv ${TEST_IOTDB_PATH} $backup_dir
    sudo cp -rf ${BM_PATH}/data/csvOutput $backup_dir
}

mv_config_file() {
    local ts_type=$1
    rm -rf -- "${BM_PATH}/conf/config.properties"
    cp -rf ${ATMOS_PATH}/conf/${TEST_TYPE}/$ts_type ${BM_PATH}/conf/config.properties
}

test_operation() {
    local protocol_class_input=$1
    local ts_type=$2
    echo "开始测试${ts_type}时间序列！"
    check_benchmark_pid
    check_iotdb_pid
    set_env
    modify_iotdb_config
    case $protocol_class_input in
        111) set_protocol_class 1 1 1 ;;
        222) set_protocol_class 2 2 2 ;;
        223) set_protocol_class 2 2 3 ;;
        211) set_protocol_class 2 1 1 ;;
		224) set_protocol_class 2 2 4 ;;
        *) echo "协议设置错误！"; return ;;
    esac
    start_iotdb
    sleep 10
    for (( t_wait = 0; t_wait <= 10; t_wait++ )); do
        iotdb_state=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -e "show cluster" | grep 'Total line number = 2')
        [ "${iotdb_state}" = "Total line number = 2" ] && break || sleep 5
    done
    if [ "${iotdb_state}" != "Total line number = 2" ]; then
        echo "IoTDB未能正常启动，写入负值测试结果！"
        cost_time=-3; throughput=-3
        insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,ts_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,walFileSize,avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},${walFileSize},${avgCPULoad},${maxCPULoad},${maxDiskIOSizeRead},${maxDiskIOSizeWrite},${maxDiskIOOpsRead},${maxDiskIOOpsWrite},${protocol_class_input})"
        mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${DBNAME} -e "${insert_sql}"
        update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'RError' where commit_id = '${commit_id}'"
        mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${DBNAME} -e "${update_sql}"
        return
    fi
	change_pwd=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -e "ALTER USER root SET PASSWORD '${IOTDB_PASSWORD}'")
    mv_config_file ${ts_type}
    start_benchmark
    start_time=$(current_datetime)
    m_start_time=$(date +%s)
    sleep 60
    monitor_test_status "INGESTION"
    m_end_time=$(date +%s)
    pid=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -h 127.0.0.1 -p 6667 -e "flush")
    collect_monitor_data ${TEST_IP}
    csvOutputfile=$(find_result_csv || true)
    if ! parse_benchmark_result "${csvOutputfile}" "INGESTION"; then
        set_negative_benchmark_metrics -2
    fi
    cost_time=$(($(datetime_to_epoch "${end_time}") - $(datetime_to_epoch "${start_time}")))
    insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,ts_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,walFileSize,avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},${walFileSize},${avgCPULoad},${maxCPULoad},${maxDiskIOSizeRead},${maxDiskIOSizeWrite},${maxDiskIOOpsRead},${maxDiskIOOpsWrite},${protocol_class_input})"
    mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${DBNAME} -e "${insert_sql}"
    stop_iotdb
    sleep 30
    check_benchmark_pid
    check_iotdb_pid
    backup_test_data ${ts_type}
}

# -------------------- 主流程 --------------------
check_password
check_benchmark_version
restore_test_type_file() {
    printf '%s\n' "${TEST_TYPE}" > "${INIT_PATH}/test_type_file"
}
main() {
    trap restore_test_type_file EXIT
printf 'ontesting\n' > "${INIT_PATH}/test_type_file"
query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${TEST_TYPE} = 'retest' ORDER BY commit_date_time desc limit 1 "
result_string=$(mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${DBNAME} -e "${query_sql}")
commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
if [ -z "${commit_id}" ]; then
    query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${TEST_TYPE} is NULL ORDER BY commit_date_time desc limit 1 "
    result_string=$(mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${DBNAME} -e "${query_sql}")
    commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
    author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
    commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
fi
if [ -z "${commit_id}" ]; then
    sleep 60s
else
    update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'ontesting' where commit_id = '${commit_id}'"
    mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${DBNAME} -e "${update_sql}"
    echo "当前版本${commit_id}未执行过测试，即将编译后启动"
	if [ "${author}" != "Timecho" ]; then
		TABLENAME=${TABLENAME}
	else
		TABLENAME=${TABLENAME_T}
	fi
    test_date_time=$(date +%Y%m%d%H%M%S)
    for protocol in ${protocol_list[@]}; do
        for ts in ${ts_list[@]}; do
            init_items
            echo "开始测试${protocol}协议下的${ts}写入！"
            test_operation $protocol $ts
        done
    done
    echo "本轮测试${test_date_time}已结束."
    update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'done' where commit_id = '${commit_id}'"
    mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${DBNAME} -e "${update_sql}"
    update_sql02="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'skip' where ${TEST_TYPE} is NULL and commit_date_time < '${commit_date_time}'"
	if [ "${author}" != "Timecho" ]; then
		result_string=$(mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${DBNAME} -e "${update_sql02}")
	fi
fi
    printf '%s\n' "${TEST_TYPE}" > "${INIT_PATH}/test_type_file"
}

main "$@"
