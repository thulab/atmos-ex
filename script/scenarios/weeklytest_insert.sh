#!/usr/bin/env bash
set -o pipefail

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
BENCHMARK_DEFAULT_RESULT_LABEL="INGESTION"

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
# 功能：重置当前测试用例使用的指标和运行状态
init_items() {
    # 定义监控采集项初始值
    ts_type=0; okPoint=0; okOperation=0; failPoint=0; failOperation=0
    throughput=0; Latency=0; MIN=0; P10=0; P25=0; MEDIAN=0; P75=0; P90=0; P95=0; P99=0; P999=0; MAX=0
    numOfSe0Level=0; start_time=0; end_time=0; cost_time=0; numOfUnse0Level=0; dataFileSize=0
    maxNumofOpenFiles=0; maxNumofThread=0; errorLogSize=0; walFileSize=0; maxCPULoad=0; avgCPULoad=0
    maxDiskIOOpsRead=0; maxDiskIOOpsWrite=0; maxDiskIOSizeRead=0; maxDiskIOSizeWrite=0
}

# 功能：保留或执行测试异常通知逻辑
sendEmail() {
    sendEmail=$(${TOOLS_PATH}/sendEmail.sh $1 >/dev/null 2>&1 &)
}

# 功能：准备当前测试所需的本地安装目录与运行环境
set_env() {
    [ -d "${TEST_IOTDB_PATH}" ] && rm -rf ${TEST_IOTDB_PATH}
    mkdir -p ${TEST_IOTDB_PATH}/activation
    cp -rf ${REPOS_PATH}/${commit_id}/apache-iotdb/* ${TEST_IOTDB_PATH}/
    cp -rf ${ATMOS_PATH}/conf/${TEST_TYPE}/license ${TEST_IOTDB_PATH}/activation/
    cp -rf ${ATMOS_PATH}/conf/${TEST_TYPE}/env ${TEST_IOTDB_PATH}/.env
}

# 功能：按当前测试场景修改 IoTDB 配置
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

# 功能：根据协议编号设置各共识组使用的协议实现
set_protocol_class() {
    local config_node=$1; local schema_region=$2; local data_region=$3
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "config_node_consensus_protocol_class" "${protocol_class[${config_node}]}"
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "schema_region_consensus_protocol_class" "${protocol_class[${schema_region}]}"
    set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "data_region_consensus_protocol_class" "${protocol_class[${data_region}]}"
}

# 功能：启动当前场景中的 IoTDB 服务
start_iotdb() {
    (cd "${TEST_IOTDB_PATH}" && ./sbin/start-confignode.sh >/dev/null 2>&1 &)
    sleep 10
    (cd "${TEST_IOTDB_PATH}" && ./sbin/start-datanode.sh -H "${TEST_IOTDB_PATH}/dn_dump.hprof" >/dev/null 2>&1 &)
}

# 功能：停止当前场景中的 IoTDB 服务
stop_iotdb() {
    (cd "${TEST_IOTDB_PATH}" && ./sbin/stop-datanode.sh >/dev/null 2>&1 &)
    sleep 10
    (cd "${TEST_IOTDB_PATH}" && ./sbin/stop-confignode.sh >/dev/null 2>&1 &)
}

# 功能：清理运行目录并启动 IoT-Benchmark
start_benchmark() {
    rm -rf "${BM_PATH}/logs" "${BM_PATH}/data"
    (cd "${BM_PATH}" && ./benchmark.sh >/dev/null 2>&1 &)
}

# 功能：轮询测试进程和结果文件，处理完成或超时状态
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

# 功能：采集当前测试窗口内的资源和文件指标
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

# 功能：归档测试日志、配置、数据或结果文件
backup_test_data() {
    local ts_type=$1
    local backup_dir="${BACKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${protocol_class}"
    sudo rm -rf -- "${backup_dir:?}"
    sudo mkdir -p $backup_dir
    sudo rm -rf -- "${TEST_IOTDB_PATH}/data"
    sudo mv ${TEST_IOTDB_PATH} $backup_dir
    sudo cp -rf ${BM_PATH}/data/csvOutput $backup_dir
}

# 功能：选择并安装当前用例对应的配置文件
mv_config_file() {
    local ts_type=$1
    rm -rf -- "${BM_PATH}/conf/config.properties"
    cp -rf ${ATMOS_PATH}/conf/${TEST_TYPE}/$ts_type ${BM_PATH}/conf/config.properties
}

# 功能：执行单个测试组合并收集、解析和保存结果
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
        mysql_exec "${insert_sql}"
        update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'RError' where commit_id = '${commit_id}'"
        mysql_exec "${update_sql}"
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
    mysql_exec "${insert_sql}"
    stop_iotdb
    sleep 30
    check_benchmark_pid
    check_iotdb_pid
    backup_test_data ${ts_type}
}

# -------------------- 主流程 --------------------
check_password
check_benchmark_version
# 功能：校验运行环境并编排当前脚本的完整测试流程
main() {
    ensure_runtime_dependencies
    check_password
    trap restore_test_type_file EXIT
printf 'ontesting\n' > "${INIT_PATH}/test_type_file"
query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${TEST_TYPE} = 'retest' ORDER BY commit_date_time desc limit 1 "
result_string=$(mysql_exec "${query_sql}")
commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
if [ -z "${commit_id}" ]; then
    query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${TEST_TYPE} is NULL ORDER BY commit_date_time desc limit 1 "
    result_string=$(mysql_exec "${query_sql}")
    commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
    author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
    commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
fi
if [ -z "${commit_id}" ]; then
    sleep 60s
else
    update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'ontesting' where commit_id = '${commit_id}'"
    mysql_exec "${update_sql}"
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
    mysql_exec "${update_sql}"
    update_sql02="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'skip' where ${TEST_TYPE} is NULL and commit_date_time < '${commit_date_time}'"
	if [ "${author}" != "Timecho" ]; then
		result_string=$(mysql_exec "${update_sql02}")
	fi
fi
    printf '%s\n' "${TEST_TYPE}" > "${INIT_PATH}/test_type_file"
}

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/runtime_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/standard_benchmark_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/monitor_common.sh"

main "$@"
