#!/bin/sh
# ------------------------------------------------------------------------------
# IoTDB SE Insert Script (AI Optimized)
# ------------------------------------------------------------------------------
# Author: qingxin.feng
# Description: 自动化执行IoTDB SE写入测试，结构优化，提升可维护性和可读性。
# ------------------------------------------------------------------------------

# -------------------- 基础环境变量 --------------------
TEST_IP="11.101.17.136"           # 测试服务器IP
ACCOUNT=atmos                     # 登录用户名
test_type=unse_insert

# -------------------- 路径相关变量 --------------------
INIT_PATH=/data/atmos/zk_test     # 初始环境存放路径
ATMOS_PATH=${INIT_PATH}/atmos-ex
BM_PATH=${INIT_PATH}/iot-benchmark
BUCKUP_PATH=/nasdata/repository/unse_insert
REPOS_PATH=/nasdata/repository/master

# -------------------- 测试数据路径 --------------------
TEST_INIT_PATH=/data/atmos
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb

# -------------------- 协议相关变量 --------------------
# 1. org.apache.iotdb.consensus.simple.SimpleConsensus
# 2. org.apache.iotdb.consensus.ratis.RatisConsensus
# 3. org.apache.iotdb.consensus.iot.IoTConsensus
protocol_class=(0 org.apache.iotdb.consensus.simple.SimpleConsensus org.apache.iotdb.consensus.ratis.RatisConsensus org.apache.iotdb.consensus.iot.IoTConsensus)
protocol_list=(223)
ts_list=(common aligned template tempaligned tablemode)

# -------------------- MySQL 配置信息 --------------------
MYSQLHOSTNAME="111.200.37.158"   # 数据库主机
PORT="13306"                     # 端口
USERNAME="iotdbatm"              # 用户名
PASSWORD=${ATMOS_DB_PASSWORD}     # 密码
DBNAME="QA_ATM"                  # 数据库名称
TABLENAME="ex_unse_insert"         # 结果表名
TASK_TABLENAME="ex_commit_history" # 数据库中任务表的名称

# -------------------- Prometheus 配置信息 --------------------
metric_server="111.200.37.158:19090"

# -------------------- 公用函数 --------------------
function check_password() {
    if [ -z "${PASSWORD}" ]; then
        echo "需要关注密码设置！"
    fi
}

function check_benchmark_version() {
    BM_REPOS_PATH=/nasdata/repository/iot-benchmark
    BM_NEW=$(awk -F= '/git.commit.id.abbrev/ {print $2}' ${BM_REPOS_PATH}/git.properties)
    BM_OLD=$(awk -F= '/git.commit.id.abbrev/ {print $2}' ${BM_PATH}/git.properties 2>/dev/null)
    if [ -n "${BM_OLD}" ] && [ "${BM_OLD}" != "${BM_NEW}" ]; then
        rm -rf ${BM_PATH}
        cp -rf ${BM_REPOS_PATH} ${BM_PATH}
    fi
}

function init_items() {
    # 定义监控采集项初始值
    ts_type=0; okPoint=0; okOperation=0; failPoint=0; failOperation=0
    throughput=0; Latency=0; MIN=0; P10=0; P25=0; MEDIAN=0; P75=0; P90=0; P95=0; P99=0; P999=0; MAX=0
    numOfSe0Level=0; start_time=0; end_time=0; cost_time=0; numOfUnse0Level=0; dataFileSize=0
    maxNumofOpenFiles=0; maxNumofThread=0; errorLogSize=0; walFileSize=0; maxCPULoad=0; avgCPULoad=0
    maxDiskIOOpsRead=0; maxDiskIOOpsWrite=0; maxDiskIOSizeRead=0; maxDiskIOSizeWrite=0
}

function sendEmail() {
    sendEmail=$(${TOOLS_PATH}/sendEmail.sh $1 >/dev/null 2>&1 &)
}

function check_pid_and_kill() {
    local pname=$1
    local desc=$2
    local pid=$(jps | grep "$pname" | awk '{print $1}')
    if [ -n "$pid" ]; then
        kill -9 $pid
        echo "$desc 已停止！"
    else
        echo "未检测到$desc！"
    fi
}

function check_benchmark_pid() { check_pid_and_kill "App" "BM程序"; }
function check_iotdb_pid() {
    check_pid_and_kill "DataNode" "DataNode程序"
    check_pid_and_kill "ConfigNode" "ConfigNode程序"
    check_pid_and_kill "IoTDB" "IoTDB程序"
    echo "程序检测和清理操作已完成！"
}

function set_env() {
    [ -d "${TEST_IOTDB_PATH}" ] && rm -rf ${TEST_IOTDB_PATH}
    mkdir -p ${TEST_IOTDB_PATH}/activation
    cp -rf ${REPOS_PATH}/${commit_id}/apache-iotdb/* ${TEST_IOTDB_PATH}/
    cp -rf ${ATMOS_PATH}/conf/${test_type}/license ${TEST_IOTDB_PATH}/activation/
}

function modify_iotdb_config() {
    #修改IoTDB的配置
    sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"20G\"/g" ${TEST_IOTDB_PATH}/conf/datanode-env.sh
    #清空配置文件
    # echo "只保留要修改的参数" > ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
    #关闭影响写入性能的其他功能
    echo "enable_seq_space_compaction=false" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
    echo "enable_unseq_space_compaction=false" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
    echo "enable_cross_space_compaction=false" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
    #修改集群名称
    echo "cluster_name=${test_type}" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
    #添加启动监控功能
    echo "cn_enable_metric=true" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
    echo "cn_enable_performance_stat=true" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
    echo "cn_metric_reporter_list=PROMETHEUS" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
    echo "cn_metric_level=ALL" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
    echo "cn_metric_prometheus_reporter_port=9081" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
    #添加启动监控功能
    echo "dn_enable_metric=true" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
    echo "dn_enable_performance_stat=true" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
    echo "dn_metric_reporter_list=PROMETHEUS" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
    echo "dn_metric_level=ALL" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
    echo "dn_metric_prometheus_reporter_port=9091" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
}

function set_protocol_class() {
    local config_node=$1; local schema_region=$2; local data_region=$3
    echo "config_node_consensus_protocol_class=${protocol_class[${config_node}]}" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
    echo "schema_region_consensus_protocol_class=${protocol_class[${schema_region}]}" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
    echo "data_region_consensus_protocol_class=${protocol_class[${data_region}]}" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
}

function start_iotdb() {
    cd ${TEST_IOTDB_PATH}
    conf_start=$(./sbin/start-confignode.sh >/dev/null 2>&1 &)
    sleep 10
    data_start=$(./sbin/start-datanode.sh -H ${TEST_IOTDB_PATH}/dn_dump.hprof >/dev/null 2>&1 &)
    cd ~/
}

function stop_iotdb() {
    cd ${TEST_IOTDB_PATH}
    data_stop=$(./sbin/stop-datanode.sh >/dev/null 2>&1 &)
    sleep 10
    conf_stop=$(./sbin/stop-confignode.sh >/dev/null 2>&1 &)
    cd ~/
}

function start_benchmark() {
    cd ${BM_PATH}
    [ -d "${BM_PATH}/logs" ] && rm -rf ${BM_PATH}/logs
    [ -d "${BM_PATH}/data" ] && rm -rf ${BM_PATH}/data
    ${BM_PATH}/benchmark.sh >/dev/null 2>&1 &
    cd ~/
}

function monitor_test_status() {
    while true; do
        csvOutput=${BM_PATH}/data/csvOutput
        if [ ! -d "$csvOutput" ]; then
            now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
            t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
            if [ $t_time -ge 7200 ]; then
                echo "测试失败"
                mkdir -p ${BM_PATH}/data/csvOutput
                cd ${BM_PATH}/data/csvOutput
                touch Stuck_result.csv
                for ((i=0;i<100;i++)); do
                    echo "INGESTION ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1" >> Stuck_result.csv
                done
                cd ~
                break
            fi
            continue
        else
            end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
            echo "${ts_type}写入已完成！"
            break
        fi
    done
}

function get_single_index() {
    local query=$1; local end=$2
    local url="http://${metric_server}/api/v1/query"
    local data_param="--data-urlencode query=$query --data-urlencode 'time=${end}'"
    local index_value=$(curl -G -s $url ${data_param} | jq '.data.result[0].value[1]' | tr -d '"')
    [ -z "$index_value" ] && index_value=0
    echo $index_value
}

function collect_monitor_data() {
    local ip=$1
    dataFileSize=$(get_single_index "sum(file_global_size{instance=~\"${ip}:9091\"})" $m_end_time)
    dataFileSize=$(awk 'BEGIN{printf "%.2f\n",'$dataFileSize'/1048576/1024}')
    numOfSe0Level=$(get_single_index "sum(file_global_count{instance=~\"${ip}:9091\",name=\"seq\"})" $m_end_time)
    numOfUnse0Level=$(get_single_index "sum(file_global_count{instance=~\"${ip}:9091\",name=\"unseq\"})" $m_end_time)
    maxNumofThread_C=$(get_single_index "max_over_time(process_threads_count{instance=~\"${ip}:9081\"}[$((m_end_time-m_start_time))s])" $m_end_time)
    maxNumofThread_D=$(get_single_index "max_over_time(process_threads_count{instance=~\"${ip}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
    let maxNumofThread=${maxNumofThread_C}+${maxNumofThread_D}
    maxNumofOpenFiles=$(get_single_index "max_over_time(file_count{instance=~\"${ip}:9091\",name=\"open_file_handlers\"}[$((m_end_time-m_start_time))s])" $m_end_time)
    walFileSize=$(get_single_index "max_over_time(file_size{instance=~\"${ip}:9091\",name=~\"wal\"}[$((m_end_time-m_start_time))s])" $m_end_time)
    walFileSize=$(awk 'BEGIN{printf "%.2f\n",'$walFileSize'/1048576/1024}')
    maxCPULoad=$(get_single_index "max_over_time(sys_cpu_load{instance=~\"${ip}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
    avgCPULoad=$(get_single_index "avg_over_time(sys_cpu_load{instance=~\"${ip}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
    maxDiskIOOpsRead=$(get_single_index "rate(disk_io_ops{instance=~\"${ip}:9091\",disk_id=~\"sdb\",type=~\"read\"}[$((m_end_time-m_start_time))s])" $m_end_time)
    maxDiskIOOpsWrite=$(get_single_index "rate(disk_io_ops{instance=~\"${ip}:9091\",disk_id=~\"sdb\",type=~\"write\"}[$((m_end_time-m_start_time))s])" $m_end_time)
    maxDiskIOSizeRead=$(get_single_index "rate(disk_io_size{instance=~\"${ip}:9091\",disk_id=~\"sdb\",type=~\"read\"}[$((m_end_time-m_start_time))s])" $m_end_time)
    maxDiskIOSizeWrite=$(get_single_index "rate(disk_io_size{instance=~\"${ip}:9091\",disk_id=~\"sdb\",type=~\"write\"}[$((m_end_time-m_start_time))s])" $m_end_time)
}

function backup_test_data() {
    local ts_type=$1
    local backup_dir="${BUCKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${protocol_class}"
    sudo rm -rf $backup_dir
    sudo mkdir -p $backup_dir
    sudo rm -rf ${TEST_IOTDB_PATH}/data
    sudo mv ${TEST_IOTDB_PATH} $backup_dir
    sudo cp -rf ${BM_PATH}/data/csvOutput $backup_dir
}

function mv_config_file() {
    local ts_type=$1
    rm -rf ${BM_PATH}/conf/config.properties
    cp -rf ${ATMOS_PATH}/conf/${test_type}/$ts_type ${BM_PATH}/conf/config.properties
}

function test_operation() {
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
        *) echo "协议设置错误！"; return ;;
    esac
    start_iotdb
    sleep 10
    for (( t_wait = 0; t_wait <= 20; t_wait++ )); do
        iotdb_state=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -e "show cluster" | grep 'Total line number = 2')
        [ "${iotdb_state}" = "Total line number = 2" ] && break || sleep 30
    done
    if [ "${iotdb_state}" != "Total line number = 2" ]; then
        echo "IoTDB未能正常启动，写入负值测试结果！"
        cost_time=-3; throughput=-3
        insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,ts_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,walFileSize,avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},${walFileSize},${avgCPULoad},${maxCPULoad},${maxDiskIOSizeRead},${maxDiskIOSizeWrite},${maxDiskIOOpsRead},${maxDiskIOOpsWrite},${protocol_class})"
        mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
        update_sql="update ${TASK_TABLENAME} set ${test_type} = 'RError' where commit_id = '${commit_id}'"
        mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}"
        return
    fi
    mv_config_file ${ts_type}
    start_benchmark
    start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
    m_start_time=$(date +%s)
    sleep 60
    monitor_test_status
    m_end_time=$(date +%s)
    ${TEST_IOTDB_PATH}/sbin/start-cli.sh -h 127.0.0.1 -p 6667 -u root -pw root -e "flush"
    collect_monitor_data ${TEST_IP}
    csvOutputfile=${BM_PATH}/data/csvOutput/*result.csv
    read okOperation okPoint failOperation failPoint throughput <<<$(cat ${csvOutputfile} | grep ^INGESTION | sed -n '1,1p' | awk -F, '{print $2,$3,$4,$5,$6}')
    read Latency MIN P10 P25 MEDIAN P75 P90 P95 P99 P999 MAX <<<$(cat ${csvOutputfile} | grep ^INGESTION | sed -n '2,2p' | awk -F, '{print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12}')
    cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
    insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,ts_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,walFileSize,avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},${walFileSize},${avgCPULoad},${maxCPULoad},${maxDiskIOSizeRead},${maxDiskIOSizeWrite},${maxDiskIOOpsRead},${maxDiskIOOpsWrite},${protocol_class})"
    mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
    stop_iotdb
    sleep 30
    check_benchmark_pid
    check_iotdb_pid
    backup_test_data ${ts_type}
}

# -------------------- 主流程 --------------------
check_password
check_benchmark_version

echo "ontesting" > ${INIT_PATH}/test_type_file
query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${test_type} = 'retest' ORDER BY commit_date_time desc limit 1 "
result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${query_sql}")
commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
if [ -z "${commit_id}" ]; then
    query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${test_type} is NULL ORDER BY commit_date_time desc limit 1 "
    result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${query_sql}")
    commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
    author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
    commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
fi
if [ -z "${commit_id}" ]; then
    sleep 60s
else
    update_sql="update ${TASK_TABLENAME} set ${test_type} = 'ontesting' where commit_id = '${commit_id}'"
    mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}"
    echo "当前版本${commit_id}未执行过测试，即将编译后启动"
    test_date_time=$(date +%Y%m%d%H%M%S)
    for protocol in ${protocol_list[@]}; do
        for ts in ${ts_list[@]}; do
            init_items
            echo "开始测试${protocol}协议下的${ts}时间序列！"
            test_operation $protocol $ts
        done
    done
    echo "本轮测试${test_date_time}已结束."
    update_sql="update ${TASK_TABLENAME} set ${test_type} = 'done' where commit_id = '${commit_id}'"
    mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}"
    update_sql02="update ${TASK_TABLENAME} set ${test_type} = 'skip' where ${test_type} is NULL and commit_date_time < '${commit_date_time}'"
    mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql02}"
fi
echo "${test_type}" > ${INIT_PATH}/test_type_file