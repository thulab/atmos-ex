#!/usr/bin/env bash
set -o pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/runtime_common.sh"

#登录用户名
ACCOUNT=root
IOTDB_PASSWORD="${IOTDB_PASSWORD:-TimechoDB@2021}"
TEST_TYPE="${TEST_TYPE:-cluster_insert}"
CLUSTER_CREATE_QA_USER="${CLUSTER_CREATE_QA_USER:-1}"
#初始环境存放路径
INIT_PATH="${INIT_PATH:-/data/atmos/zk_test}"
ATMOS_PATH=${INIT_PATH}/atmos-ex
BM_PATH=${INIT_PATH}/iot-benchmark
BACKUP_PATH="${BACKUP_PATH:-/nasdata/repository/cluster_insert}"
REPOS_PATH="${REPOS_PATH:-/nasdata/repository/master}"
TEST_PATH=/data/atmos/zk_test/first-rest-test
TEST_DATANODE_PATH=${TEST_PATH}/DN/apache-iotdb
TEST_CONFIGNODE_PATH=${TEST_PATH}/CN/apache-iotdb
# 1. org.apache.iotdb.consensus.simple.SimpleConsensus
# 2. org.apache.iotdb.consensus.ratis.RatisConsensus
# 3. org.apache.iotdb.consensus.iot.IoTConsensus
protocol_class=(0 org.apache.iotdb.consensus.simple.SimpleConsensus org.apache.iotdb.consensus.ratis.RatisConsensus org.apache.iotdb.consensus.iot.IoTConsensus)
protocol_list=(111 223)
ts_list=(common aligned template tempaligned)

IP_list=(0 11.101.17.131 11.101.17.132 11.101.17.133)
D_IP_list=(0 11.101.17.131 11.101.17.132 11.101.17.133)
C_IP_list=(0 11.101.17.131 11.101.17.132 11.101.17.133)
B_IP_list=(0 11.101.17.131)
config_schema_replication_factor=(0 3 3 3 3 3 3)
config_data_replication_factor=(0 3 3 3 3 3 3)
config_node_config_nodes=(0 11.101.17.131:10710 11.101.17.131:10710 11.101.17.131:10710)
data_node_config_nodes=(0 11.101.17.131:10710 11.101.17.132:10710 11.101.17.133:10710)
Control=11.101.17.130
query_type_csv=(PRECISE_POINT, TIME_RANGE, VALUE_RANGE, AGG_RANGE, AGG_VALUE, AGG_RANGE_VALUE, GROUP_BY, LATEST_POINT, RANGE_QUERY_DESC, VALUE_RANGE_QUERY_DESC, GROUP_BY_DESC)
query_type_name=(PRECISE_POINT TIME_RANGE VALUE_RANGE AGG_RANGE AGG_VALUE AGG_RANGE_VALUE GROUP_BY LATEST_POINT RANGE_QUERY_DESC VALUE_RANGE_QUERY_DESC GROUP_BY_DESC)
############mysql信息##########################
MYSQL_HOST="${MYSQL_HOST:-111.200.37.158}"
MYSQL_PORT="${MYSQL_PORT:-13306}"
MYSQL_USERNAME="${MYSQL_USERNAME:-iotdbatm}"
MYSQL_PASSWORD="${ATMOS_DB_PASSWORD:-}"
DBNAME="${DBNAME:-QA_ATM}"
TABLENAME="ex_cluster_insert" #数据库中表的名称
TABLENAME_T="ex_cluster_insert_T" #企业版结果表名
TABLENAME_QUERY="ex_cluster_insert_query" #数据库中表的名称
TABLENAME_QUERY_T="ex_cluster_insert_query_T" #企业版结果表名
TASK_TABLENAME="ex_commit_history" #数据库中任务表的名称
############prometheus##########################
METRIC_SERVER="${METRIC_SERVER:-111.200.37.158:19090}"
############公用函数##########################
if [ -z "${MYSQL_PASSWORD}" ]; then
    printf '[ERROR] ATMOS_DB_PASSWORD is required\n' >&2
    exit 1
fi
for required_command in awk date mysql sed; do
    if ! command -v "${required_command}" >/dev/null 2>&1; then
        printf '[ERROR] required command not found: %s\n' "${required_command}" >&2
        exit 1
    fi
done
unset required_command
#echo "Started at: " date -d today +"%Y-%m-%d %H:%M:%S"
log "检查iot-benchmark版本"
BM_REPOS_PATH="${BM_REPOS_PATH:-/nasdata/repository/iot-benchmark}"
BM_NEW=$(cat ${BM_REPOS_PATH}/git.properties | grep git.commit.id.abbrev | awk -F= '{print $2}')
BM_OLD=$(cat ${BM_PATH}/git.properties | grep git.commit.id.abbrev | awk -F= '{print $2}')
if [ "${BM_OLD}" != "cat: git.properties: No such file or directory" ] && [ "${BM_OLD}" != "${BM_NEW}" ]; then
	rm -rf -- "${BM_PATH}"
	cp -rf ${BM_REPOS_PATH} ${BM_PATH}
fi
# 功能：重置当前测试用例使用的指标和运行状态
init_items() {
############定义监控采集项初始值##########################
test_date_time=0
ts_type=0
query_type=0
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
############定义监控采集项初始值##########################
}
local_ip=`ifconfig -a|grep inet|grep -v 127.0.0.1|grep -v inet6|awk '{print $2}'|tr -d "addr:"`
# 功能：保留或执行测试异常通知逻辑
sendEmail() {
sendEmail=$(${TOOLS_PATH}/sendEmail.sh $1 >/dev/null 2>&1 &)
}
# 功能：准备当前测试所需的本地安装目录与运行环境
set_env() { # 拷贝编译好的iotdb到测试路径
	if [ ! -d "${TEST_PATH}" ]; then
		mkdir -p ${TEST_PATH}
		mkdir -p ${TEST_PATH}/CN/apache-iotdb
		mkdir -p ${TEST_PATH}/DN/apache-iotdb
	else
		rm -rf -- "${TEST_PATH}"
		mkdir -p ${TEST_PATH}
		mkdir -p ${TEST_PATH}/CN/apache-iotdb
		mkdir -p ${TEST_PATH}/DN/apache-iotdb
	fi
	
	cp -rf ${REPOS_PATH}/${commit_id}/apache-iotdb/* ${TEST_PATH}/CN/apache-iotdb/
	mkdir -p ${TEST_PATH}/CN/apache-iotdb/activation
	cp -rf ${ATMOS_PATH}/conf/${TEST_TYPE}/license ${TEST_PATH}/CN/apache-iotdb/activation/
	
	cp -rf ${REPOS_PATH}/${commit_id}/apache-iotdb/* ${TEST_PATH}/DN/apache-iotdb/
}
# 功能：按当前测试场景修改 IoTDB 配置
modify_iotdb_config() { # iotdb调整内存，关闭合并
	#修改IoTDB的配置
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"20G\"/g" ${TEST_DATANODE_PATH}/conf/datanode-env.sh
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"6G\"/g" ${TEST_CONFIGNODE_PATH}/conf/confignode-env.sh
	#清空配置文件
	# echo "只保留要修改的参数" > ${TEST_DATANODE_PATH}/conf/iotdb-system.properties
	#关闭影响写入性能的其他功能
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "enable_seq_space_compaction" "false"
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "enable_unseq_space_compaction" "false"
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "enable_cross_space_compaction" "false"
	#修改集群名称
	set_iotdb_property "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "cluster_name" "Apache-IoTDB"
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "cluster_name" "Apache-IoTDB"
	#添加启动监控功能
	set_iotdb_property "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "cn_enable_metric" "true"
	set_iotdb_property "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "cn_enable_performance_stat" "true"
	set_iotdb_property "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "cn_metric_reporter_list" "PROMETHEUS"
	set_iotdb_property "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "cn_metric_level" "ALL"
	set_iotdb_property "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "cn_metric_prometheus_reporter_port" "9081"
	#添加启动监控功能
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "dn_enable_metric" "true"
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "dn_enable_performance_stat" "true"
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "dn_metric_reporter_list" "PROMETHEUS"
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "dn_metric_level" "ALL"
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "dn_metric_prometheus_reporter_port" "9091"
}
# 功能：根据协议编号设置各共识组使用的协议实现
set_protocol_class() { 
	config_node=$1
	schema_region=$2
	data_region=$3
	#设置协议
	set_iotdb_property "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "config_node_consensus_protocol_class" "${protocol_class[${config_node}]}"
	set_iotdb_property "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "schema_region_consensus_protocol_class" "${protocol_class[${schema_region}]}"
	set_iotdb_property "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "data_region_consensus_protocol_class" "${protocol_class[${data_region}]}"
	#设置协议
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "config_node_consensus_protocol_class" "${protocol_class[${config_node}]}"
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "schema_region_consensus_protocol_class" "${protocol_class[${schema_region}]}"
	set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "data_region_consensus_protocol_class" "${protocol_class[${data_region}]}"
}
# 功能：按指定 ConfigNode、DataNode 和 Benchmark 数量部署远程集群
setup_nCmD() {
while getopts 'c:d:t:' OPT; do
    case $OPT in
        c) config_num="$OPTARG";;
        d) data_num="$OPTARG";;
		t) bm_num="$OPTARG";;
        ?) echo "ERROR";;
    esac
done
###检查参数
if [[ "$config_num" == '' ]] || [[ "$data_num" == '' ]] 
then
  log "Enter the number of ConfigNodes and datanodes to start."
  exit -1
fi
#拼接config_node参数
dcn_str=''
for (( j = 1; j <= ${config_num}; j++ ))
do
	if [ "$dcn_str" == '' ]; then
		dcn_str=${data_node_config_nodes[${j}]}
	else
		dcn_str=${dcn_str},${data_node_config_nodes[${j}]}
	fi
done
log "开始重置环境！"
for (( i = 1; i < ${#IP_list[*]}; i++ ))
do
	#ssh ${ACCOUNT}@${IP_list[${i}]} "killall -u ${ACCOUNT} > /dev/null 2>&1 &"
	remote_reboot "${IP_list[${i}]}"
done
sleep 180
for (( i = 1; i < ${#IP_list[*]}; i++ ))
do
	log "setting env to ${IP_list[${i}]} ..."
	#删除原有路径下所有
	remote_reset_dir "${IP_list[${i}]}" "${TEST_PATH}"
	remote_clear_configured_roots "${IP_list[${i}]}"
	#复制三项到客户机
	remote_copy_contents "${TEST_PATH}" "${IP_list[${i}]}" "${TEST_PATH}"
done
for ((j = 1; j <= $bm_num; j++)); do
	remote_clean_benchmark_runtime "${B_IP_list[${j}]}" "${BM_PATH}"
done
log "开始部署ConfigNode！"
for (( i = 1; i <= $config_num; i++ ))
do
	#修改IoTDB ConfigNode的配置
	remote_append_property "${C_IP_list[${i}]}" "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "cn_internal_address" "${C_IP_list[${i}]}"
	remote_append_property "${C_IP_list[${i}]}" "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "cn_seed_config_node" "${config_node_config_nodes[${i}]}"
	remote_append_property "${C_IP_list[${i}]}" "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "schema_replication_factor" "${config_schema_replication_factor[${i}]}"
	remote_append_property "${C_IP_list[${i}]}" "${TEST_CONFIGNODE_PATH}/conf/iotdb-system.properties" "data_replication_factor" "${config_data_replication_factor[${i}]}"
done
log "开始部署DataNode！"
for (( i = 1; i <= $data_num; i++ ))
do
	#修改IoTDB DataNode的配置
	remote_append_property "${D_IP_list[${i}]}" "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "dn_rpc_address" "${D_IP_list[${i}]}"
	remote_append_property "${D_IP_list[${i}]}" "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "dn_internal_address" "${D_IP_list[${i}]}"
	remote_append_property "${D_IP_list[${i}]}" "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "dn_seed_config_node" "${dcn_str}"
done
#启动config_num个IoTDB ConfigNode节点
for (( j = 1; j <= $config_num; j++ ))
do
	log "starting IoTDB ConfigNode on ${C_IP_list[${j}]} ..."
	remote_start_background "${C_IP_list[${j}]}" "${TEST_CONFIGNODE_PATH}/sbin/start-confignode.sh -H ${TEST_CONFIGNODE_PATH}/cn_dump.hprof"
	#主节点需要先启动，所以等待10秒是为了保证主节点启动完毕
	sleep 10
done
#启动data_num个IoTDB DataNode节点
for (( j = 1; j <= $data_num; j++ ))
do
	log "starting IoTDB DataNode on ${D_IP_list[${j}]} ..."
	remote_start_background "${D_IP_list[${j}]}" "${TEST_DATANODE_PATH}/sbin/start-datanode.sh -H ${TEST_DATANODE_PATH}/dn_dump.hprof"
done
#等待60s，让服务器完成前期准备
sleep 60
#检查IoTDB ConfigNode节点
check_config_num=0
for (( j = 1; j <= $config_num; j++ ))
do
	for (( t_wait = 0; t_wait <= 3; t_wait++ ))
	do
	  str1=$(remote_java_process_count "${C_IP_list[${j}]}" "ConfigNode")
	  if [ "$str1" = "1" ]; then
		log "ConfigNode has been started on PC:${C_IP_list[${j}]}"
		check_config_num=$[${check_config_num}+1]
		break
	  else
		log "ConfigNode has not been started on PC:${C_IP_list[${j}]}"
		sleep 30
		continue
	  fi
	done
done
#检查IoTDB DataNode节点
check_data_num=0
for (( j = 1; j <= $data_num; j++ ))
do
	for (( t_wait = 0; t_wait <= 3; t_wait++ ))
	do
	  str1=$(remote_java_process_count "${D_IP_list[${j}]}" "DataNode")
	  if [ "$str1" = "1" ]; then
		log "DataNode has been started on PC:${D_IP_list[${j}]}"
		check_data_num=$[${check_data_num}+1]
		break
	  else
		log "DataNode has not been started on PC:${D_IP_list[${j}]}"
		sleep 30
		continue
	  fi
	done
done
#检查iotdb DataNode是否可连接节点
total_nodes=$(($config_num+$data_num))
for (( j = 1; j <= $data_num; j++ ))
do
	if wait_for_remote_iotdb_cluster "${D_IP_list[${j}]}" "${TEST_DATANODE_PATH}/sbin/start-cli.sh" "${total_nodes}"; then
	  log "All Nodes is ready"
	else
	  log "All Nodes is not ready!"
	  exit -1
	fi
done
change_pwd=$(ssh ${ACCOUNT}@${D_IP_list[1]} "${TEST_DATANODE_PATH}/sbin/start-cli.sh -h ${D_IP_list[1]} -p 6667 -e \"ALTER USER root SET PASSWORD '${IOTDB_PASSWORD}'\"")
if [ "$check_config_num" == "$config_num" ] && [ "$check_data_num" == "$data_num" ]; then
	log "All ${check_config_num} ConfigNodes and ${check_data_num} DataNodes have been started"
	if [ "${CLUSTER_CREATE_QA_USER}" = "1" ]; then
		remote_exec "${D_IP_list[1]}" "${TEST_DATANODE_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -h ${D_IP_list[1]} -p 6667 -e \"CREATE USER qa_user 'test123456789';\""
		remote_exec "${D_IP_list[1]}" "${TEST_DATANODE_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -h ${D_IP_list[1]} -p 6667 -e \"GRANT ALL ON root.** TO USER qa_user WITH GRANT OPTION;\""
		remote_exec "${D_IP_list[1]}" "${TEST_DATANODE_PATH}/sbin/start-cli.sh -u root -pw ${IOTDB_PASSWORD} -h ${D_IP_list[1]} -p 6667 -sql_dialect table -e \"GRANT ALL TO USER qa_user;\""
	fi
	#启动benchmark
	sleep 60
	if [ "$bm_num" != '' ];
	then
		for ((j = 1; j <= $bm_num; j++)); do
			remote_deploy_benchmark "${B_IP_list[${j}]}" "${BM_PATH}"
			log "正在启动Benchmark:${B_IP_list[${j}]}，启动日志:${BM_PATH}/logs/atmos-startup.log"
			if ! remote_start_benchmark "${B_IP_list[${j}]}" "${BM_PATH}"; then
				log "Benchmark远程启动命令执行失败:${B_IP_list[${j}]}，本轮测试按失败处理"
				exit 1
			fi
		done
		for ((j = 1; j <= $bm_num; j++)); do
			if wait_for_attempts \
				"${BENCHMARK_START_CHECK_RETRIES:-6}" \
				"${BENCHMARK_START_CHECK_INTERVAL_SECONDS:-5}" \
				remote_java_process_running "${B_IP_list[${j}]}" "App"; then
				log "Benchmark已启动:${B_IP_list[${j}]}"
			else
				log "Benchmark启动失败:${B_IP_list[${j}]}，本轮测试按失败处理"
				remote_exec "${B_IP_list[${j}]}" \
					"if [ -f $(printf '%q' "${BM_PATH}/logs/atmos-startup.log") ]; then tail -n 100 $(printf '%q' "${BM_PATH}/logs/atmos-startup.log"); else echo 'Benchmark启动日志不存在'; fi" >&2 || true
				exit 1
			fi
		done
		log "All BMs have been started and verified"
	fi	
fi
}
# 功能：轮询测试进程和结果文件，处理完成或超时状态
monitor_test_status() { # 监控测试运行状态，获取最大打开文件数量和最大线程数
	while true; do
		flag=0
		for (( j = 1; j <= 1; j++ ))
		do
			str1=$(ssh ${ACCOUNT}@${B_IP_list[${j}]} "jps | grep -w App | grep -v grep | wc -l" 2>/dev/null)
			if [ "$str1" = "1" ]; then
				log "测试未结束:${B_IP_list[${j}]}"  > /dev/null 2>&1 &
				sleep 180
			else
				log "测试已结束:${B_IP_list[${j}]}"
				flag=$[${flag}+1]
			fi
		done
		now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
		t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
		if [ $t_time -ge 6000 ]; then
			log "测试失败"
			end_time=-1
			cost_time=-1
			ssh ${ACCOUNT}@${B_IP_list[1]} "test -f ${BM_PATH}/data/*result.csv"
			if [ $? -eq 0 ]; then
				log "文件存在"
				remote_safe_rm "${B_IP_list[1]}" "${BM_PATH}/data/csvOutput"
			else
				log "文件不存在"
				remote_reset_dir "${B_IP_list[1]}" "${BM_PATH}/data/csvOutput"
				ssh ${ACCOUNT}@${B_IP_list[1]} "touch ${BM_PATH}/data/csvOutput/Stuck_result.csv"
				array1="INGESTION ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1"
				for ((i=0;i<100;i++))
				do
					ssh ${ACCOUNT}@${B_IP_list[1]} "echo $array1 >> ${BM_PATH}/data/csvOutput/Stuck_result.csv"
				done
				break
			fi
		fi
		if [ "$flag" = "1" ]; then
			end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
			break
		fi
	done
}
# 功能：采集当前测试窗口内的资源和文件指标
collect_monitor_data() { # 收集iotdb数据大小，顺、乱序文件数量
	TEST_IP=$1
	dataFileSize=0
	walFileSize=0
	numOfSe0Level=0
	numOfUnse0Level=0
	maxNumofOpenFiles=0
	maxNumofThread_C=0
	maxNumofThread_D=0
	maxNumofThread=0
	#调用监控获取数值
	dataFileSize=$(get_single_index "sum(file_global_size{instance=~\"${D_IP_list[${TEST_IP}]}:9091\"})" $m_end_time)
	dataFileSize=`awk 'BEGIN{printf "%.2f\n",'$dataFileSize'/'1048576'}'`
	dataFileSize=`awk 'BEGIN{printf "%.2f\n",'$dataFileSize'/'1024'}'`
	numOfSe0Level=$(get_single_index "sum(file_global_count{instance=~\"${D_IP_list[${TEST_IP}]}:9091\",name=\"seq\"})" $m_end_time)
	numOfUnse0Level=$(get_single_index "sum(file_global_count{instance=~\"${D_IP_list[${TEST_IP}]}:9091\",name=\"unseq\"})" $m_end_time)
	maxNumofThread_C=$(get_single_index "max_over_time(process_threads_count{instance=~\"${D_IP_list[${TEST_IP}]}:9081\"}[$((m_end_time-m_start_time))s])" $m_end_time)
	maxNumofThread_D=$(get_single_index "max_over_time(process_threads_count{instance=~\"${D_IP_list[${TEST_IP}]}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
	let maxNumofThread=${maxNumofThread_C}+${maxNumofThread_D}
	maxNumofOpenFiles=$(get_single_index "max_over_time(file_count{instance=~\"${D_IP_list[${TEST_IP}]}:9091\",name=\"open_file_handlers\"}[$((m_end_time-m_start_time))s])" $m_end_time)
	walFileSize=$(get_single_index "max_over_time(file_size{instance=~\"${D_IP_list[${TEST_IP}]}:9091\",name=~\"wal\"}[$((m_end_time-m_start_time))s])" $m_end_time)
	walFileSize=`awk 'BEGIN{printf "%.2f\n",'$walFileSize'/'1048576'}'`
	walFileSize=`awk 'BEGIN{printf "%.2f\n",'$walFileSize'/'1024'}'`
	maxCPULoad=$(get_single_index "max_over_time(sys_cpu_load{instance=~\"${TEST_IP}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
	avgCPULoad=$(get_single_index "avg_over_time(sys_cpu_load{instance=~\"${TEST_IP}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
	maxDiskIOOpsRead=$(get_single_index "rate(disk_io_ops{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"read\"}[$((m_end_time-m_start_time))s])" $m_end_time)
	maxDiskIOOpsWrite=$(get_single_index "rate(disk_io_ops{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"write\"}[$((m_end_time-m_start_time))s])" $m_end_time)
	maxDiskIOSizeRead=$(get_single_index "rate(disk_io_size{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"read\"}[$((m_end_time-m_start_time))s])" $m_end_time)
	maxDiskIOSizeWrite=$(get_single_index "rate(disk_io_size{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"write\"}[$((m_end_time-m_start_time))s])" $m_end_time)
}
# 功能：归档测试日志、配置、数据或结果文件
backup_test_data() { # 备份测试数据
	sudo rm -rf -- "${BACKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}"
	sudo mkdir -p ${BACKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
    sudo rm -rf -- "${TEST_DATANODE_PATH}/data"
	sudo mv ${TEST_DATANODE_PATH} ${BACKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
	sudo cp -rf ${BM_PATH}/data/csvOutput ${BACKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
}
# 功能：选择并安装当前用例对应的配置文件
mv_config_file() { # 移动配置文件
	rm -rf -- "${BM_PATH}/conf/config.properties"
	cp -rf ${ATMOS_PATH}/conf/${TEST_TYPE}/$1/$2 ${BM_PATH}/conf/config.properties
}
# 功能：执行单个测试组合并收集、解析和保存结果
test_operation() {
	run_isolated_case test_operation_impl "$@"
}

# 功能：执行单轮集群写入测试；由 test_operation 隔离运行状态
test_operation_impl() {
	ts_type=$1
	data_type=$2
	protocol_class=$3
	log "开始测试${ts_type}时间序列！"
	#复制当前程序到执行位置
	set_env
	modify_iotdb_config
	if [ "${protocol_class}" = "111" ]; then
		set_protocol_class 1 1 1
	elif [ "${protocol_class}" = "222" ]; then
		set_protocol_class 2 2 2
		set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "schema_region_ratis_rpc_leader_election_timeout_min_ms" "8000"
		set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "data_region_ratis_rpc_leader_election_timeout_min_ms" "8000"
		set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "schema_region_ratis_rpc_leader_election_timeout_max_ms" "16000"
		set_iotdb_property "${TEST_DATANODE_PATH}/conf/iotdb-system.properties" "data_region_ratis_rpc_leader_election_timeout_max_ms" "16000"
	elif [ "${protocol_class}" = "223" ]; then
		set_protocol_class 2 2 3
    elif [ "${protocol_class}" = "211" ]; then
        set_protocol_class 2 1 1
	else
		log "协议设置错误！"
		return
	fi
	
	mv_config_file ${ts_type} ${data_type}
	sed -i "s/^HOST=.*$/HOST=${D_IP_list[1]}/g" ${BM_PATH}/conf/config.properties
	setup_nCmD -c3 -d3 -t1	
	log "测试开始！"
	start_time=`date -d today +"%Y-%m-%d %H:%M:%S"`
	m_start_time=$(date +%s)
	#等待1分钟
	sleep 60
	monitor_test_status
	m_end_time=$(date +%s)
	#测试结果收集写入数据库
	if [ ! -d "${BM_PATH}/TestResult/csvOutput/" ]; then
		mkdir -p ${BM_PATH}/TestResult/csvOutput/
	fi
	rm -rf -- "${BM_PATH:?}/TestResult/csvOutput/"*
	scp -r ${ACCOUNT}@${B_IP_list[1]}:${BM_PATH}/data/csvOutput/*result.csv ${BM_PATH}/TestResult/csvOutput/
	for ((j = 1; j <= 3; j++)); do
		#收集启动后基础监控数据
		collect_monitor_data ${j}
		csvOutputfile=${BM_PATH}/TestResult/csvOutput/*result.csv
		read okOperation okPoint failOperation failPoint throughput <<<$(cat ${csvOutputfile} | grep ^INGESTION | sed -n '1,1p' | awk -F, '{print $2,$3,$4,$5,$6}')
		read Latency MIN P10 P25 MEDIAN P75 P90 P95 P99 P999 MAX <<<$(cat ${csvOutputfile} | grep ^INGESTION | sed -n '2,2p' | awk -F, '{print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12}')
		#cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
		node_id=${j}
		insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,node_id,ts_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,walFileSize,avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark,protocol) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${node_id},'${ts_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${walFileSize},${avgCPULoad},${maxCPULoad},${maxDiskIOSizeRead},${maxDiskIOSizeWrite},${maxDiskIOOpsRead},${maxDiskIOOpsWrite},'${data_type}','${protocol_class}')"
		mysql_exec "${insert_sql}"
		
		sudo mkdir -p ${BACKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}_${protocol_class}/${j}/CN
		sudo mkdir -p ${BACKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}_${protocol_class}/${j}/DN
		ssh ${ACCOUNT}@${C_IP_list[${j}]} "sudo cp -rf ${TEST_CONFIGNODE_PATH}/logs ${BACKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}_${protocol_class}/${j}/CN"
		ssh ${ACCOUNT}@${D_IP_list[${j}]} "sudo cp -rf ${TEST_DATANODE_PATH}/logs ${BACKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}_${protocol_class}/${j}/DN"
		ssh ${ACCOUNT}@${D_IP_list[${j}]} "sudo mv ${TEST_DATANODE_PATH}/dn_dump.hprof ${INIT_PATH}/${ts_type}_${commit_date_time}_${commit_id}_${data_type}_${protocol_class}_dn_dump.hprof"
		ssh ${ACCOUNT}@${C_IP_list[${j}]} "sudo mv ${TEST_CONFIGNODE_PATH}/cn_dump.hprof ${INIT_PATH}/${ts_type}_${commit_date_time}_${commit_id}_${data_type}_${protocol_class}_cn_dump.hprof"
	done
	
	if  [ "${data_type}" = "unseq_rw" ] || [ "${data_type}" = "seq_rw" ]; then
		csvOutputfile=${BM_PATH}/TestResult/csvOutput/*result.csv
		for (( i = 0; i < ${#query_type_csv[*]}; i++ ))
		do
			read okOperation okPoint failOperation failPoint throughput <<<$(cat ${csvOutputfile} | grep ^${query_type_csv[${i}]} | sed -n '1,1p' | awk -F, '{print $2,$3,$4,$5,$6}')
			read Latency MIN P10 P25 MEDIAN P75 P90 P95 P99 P999 MAX <<<$(cat ${csvOutputfile} | grep ^${query_type_csv[${i}]} | sed -n '2,2p' | awk -F, '{print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12}')
			node_id=1
			insert_sql="insert into ${TABLENAME_QUERY} (commit_date_time,test_date_time,commit_id,author,node_id,ts_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,walFileSize,avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark,protocol,query_type) values(${commit_date_time},${test_date_time},'${commit_id}','${author}',${node_id},'${ts_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${walFileSize},${avgCPULoad},${maxCPULoad},${maxDiskIOSizeRead},${maxDiskIOSizeWrite},${maxDiskIOOpsRead},${maxDiskIOOpsWrite},'${data_type}','${protocol_class}','${query_type_name[${i}]}')"
			mysql_exec "${insert_sql}"
		done
	fi
	
	sudo cp -rf ${BM_PATH}/TestResult/csvOutput/* ${BACKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}_${protocol_class}/
	sudo scp -r ${ACCOUNT}@${B_IP_list[1]}:${BM_PATH}/logs ${BACKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${data_type}_${protocol_class}/
}

##准备开始测试
# 功能：在脚本退出时恢复测试类型状态文件
restore_test_type_file() {
    printf '%s\n' "${TEST_TYPE}" > "${INIT_PATH}/test_type_file"
}
# 功能：校验运行环境并编排当前脚本的完整测试流程
main() {
    ensure_runtime_dependencies
    check_password
    trap restore_test_type_file EXIT
printf 'ontesting\n' > "${INIT_PATH}/test_type_file"
log "开始从MySQL领取${TEST_TYPE}任务"
if ! claim_next_task; then
	log "MySQL中没有符合条件的${TEST_TYPE}任务"
	sleep 60s
else
	log "当前版本${commit_id}未执行过测试，即将编译后启动"
	if [ "${author}" != "Timecho" ]; then
		TABLENAME=${TABLENAME}
		TABLENAME_QUERY=${TABLENAME_QUERY}
	else
		TABLENAME=${TABLENAME_T}
		TABLENAME_QUERY=${TABLENAME_QUERY_T}
	fi
	init_items
	test_date_time=`date +%Y%m%d%H%M%S`
	########优先测试
	log "开始测试普通时间序列顺序写入！"
	test_operation common seq_w 223
	log "开始测试对齐时间序列顺序写入！"
	test_operation aligned seq_w 223
	test_operation aligned seq_w 222
	###############################非ROOT账户###############################
	log "开始测试非ROOT账户表模型顺序写入！"
	test_operation tablemode seq_w_non 223
	log "开始测试非ROOT账户普通时间序列顺序写入！"
	test_operation common seq_w_non 223
	###############################普通时间序列###############################
	#echo "开始测试普通时间序列顺序写入！"
	#test_operation common seq_w 223
	log "开始测试普通时间序列乱序写入！"
	test_operation common unseq_w 223
	#echo "开始测试普通时间序列顺序读写混合！"
	#test_operation common seq_rw 223
	#echo "开始测试普通时间序列乱序读写混合！"
	#test_operation common unseq_rw 223
	###############################对齐时间序列###############################
	#echo "开始测试对齐时间序列顺序写入！"
	#test_operation aligned seq_w 223
	#test_operation aligned seq_w 222
	log "开始测试对齐时间序列乱序写入！"
	test_operation aligned unseq_w 223
	test_operation aligned unseq_w 222
	log "开始测试对齐时间序列顺序读写混合！"
	test_operation aligned seq_rw 223
	log "开始测试对齐时间序列乱序读写混合！"
	test_operation aligned unseq_rw 223
	###############################模板时间序列###############################
	#echo "开始测试模板时间序列顺序写入！"
	#test_operation template seq_w 223
	#echo "开始测试模板时间序列乱序写入！"
	#test_operation template unseq_w 223
	#echo "开始测试模板时间序列顺序读写混合！"
	#test_operation template seq_rw 223
	#echo "开始测试模板时间序列乱序读写混合！"
	#test_operation template unseq_rw 223
	###############################对齐模板时间序列###############################
	#echo "开始测试对齐模板时间序列顺序写入！"
	#test_operation tempaligned seq_w 223
	#echo "开始测试对齐模板时间序列乱序写入！"
	#test_operation tempaligned unseq_w 223
	#echo "开始测试对齐模板时间序列顺序读写混合！"
	#test_operation tempaligned seq_rw 223
	#echo "开始测试对齐模板时间序列乱序读写混合！"
	#test_operation tempaligned unseq_rw 223
	###############################表模型###############################
	log "开始测试表模型顺序写入！"
	test_operation tablemode seq_w 223
	log "开始测试表模型乱序写入！"
	test_operation tablemode unseq_w 223
	log "开始测试表模型顺序读写混合！"
	test_operation tablemode seq_rw 223
	log "开始测试表模型乱序读写混合！"
	test_operation tablemode unseq_rw 223
	###############################测试完成###############################
	log "本轮测试${test_date_time}已结束."
	update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'done' where commit_id = '${commit_id}'"
	result_string=$(mysql_exec "${update_sql}")
	update_sql02="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'skip' where ${TEST_TYPE} is NULL and commit_date_time < '${commit_date_time}'"
	if [ "${author}" != "Timecho" ]; then
		result_string=$(mysql_exec "${update_sql02}")
	fi
fi
    printf '%s\n' "${TEST_TYPE}" > "${INIT_PATH}/test_type_file"
}

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/remote_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/monitor_common.sh"

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
