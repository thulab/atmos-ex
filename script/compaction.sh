#!/usr/bin/env bash
#登录用户名
TEST_IP="11.101.17.114"
test_type=compaction
#初始环境存放路径
INIT_PATH=/data/atmos/zk_test
ATMOS_PATH=${INIT_PATH}/atmos-ex
DATA_PATH=/data/atmos/DataSet
BUCKUP_PATH=/nasdata/repository/compaction
REPOS_PATH=/nasdata/repository/master
#测试数据运行路径
TEST_INIT_PATH=/data/atmos
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb
# 1. org.apache.iotdb.consensus.simple.SimpleConsensus
# 2. org.apache.iotdb.consensus.ratis.RatisConsensus
# 3. org.apache.iotdb.consensus.iot.IoTConsensus
protocol_class=(0 org.apache.iotdb.consensus.simple.SimpleConsensus org.apache.iotdb.consensus.ratis.RatisConsensus org.apache.iotdb.consensus.iot.IoTConsensus)
############mysql信息##########################
MYSQLHOSTNAME="111.200.37.158" #数据库信息
PORT="13306"
USERNAME="iotdbatm"
PASSWORD=${ATMOS_DB_PASSWORD}
DBNAME="QA_ATM"  #数据库名称
TABLENAME="ex_compaction" #数据库中表的名称
TABLENAME_T="ex_compaction_T" # 企业版结果表名
TASK_TABLENAME="ex_commit_history" #数据库中任务表的名称
############prometheus##########################
metric_server="111.200.37.158:19090"
############公用函数##########################
if [ "${PASSWORD}" = "" ]; then
echo "需要关注密码设置！"
fi
run_mysql() {
	mysql -h"${MYSQLHOSTNAME}" -P"${PORT}" -u"${USERNAME}" -p"${PASSWORD}" "${DBNAME}" -e "$1"
}
dir_size_gb() {
	local target_dir=$1
	if [ ! -d "${target_dir}" ]; then
		echo 0
	else
		du -sk "${target_dir}" 2>/dev/null | awk '{printf "%.2f\n", $1 / 1048576}'
	fi
}
count_tsfiles() {
	local target_dir=$1
	local name_pattern=$2
	if [ ! -d "${target_dir}" ]; then
		echo 0
	else
		find "${target_dir}" -name "${name_pattern}" | wc -l
	fi
}
init_items() {
############定义监控采集项初始值##########################
test_date_time=0
ts_type=0
cost_time=0
numOfSe0Level_before=0
numOfSe0Level_after=0
numOfUnse0Level_before=0
numOfUnse0Level_after=0
ts_dataSize=0
ts_numOfPoints=0
compaction_rate=0
comp_start_time=0
comp_end_time=0
dataFileSize_before=0
dataFileSize_after=0
maxNumofOpenFiles=0
maxNumofThread=0
errorLogSize=0
maxCPULoad=0
avgCPULoad=0
maxDiskIOOpsRead=0
maxDiskIOOpsWrite=0
maxDiskIOSizeRead=0
maxDiskIOSizeWrite=0
############定义监控采集项初始值##########################
}
get_single_index() {
    # 获取 prometheus 单个指标的值
    local query=$1
    local end=$2
    local url="http://${metric_server}/api/v1/query"
    local index_value
    index_value=$(curl -G -s "${url}" --data-urlencode "query=${query}" --data-urlencode "time=${end}" | jq -r '.data.result[0].value[1] // 0')
	if [[ "$index_value" == "null" || -z "$index_value" ]]; then 
		index_value=0
	fi
	echo "${index_value}"
}
check_iotdb_pid() { # 检查iotdb的pid，有就停止
	iotdb_pid=$(jps | grep DataNode | awk '{print $1}')
	if [ "${iotdb_pid}" = "" ]; then
		echo "未检测到DataNode程序！"
	else
		kill -9 ${iotdb_pid}
		echo "DataNode程序已停止！"
	fi
	iotdb_pid=$(jps | grep ConfigNode | awk '{print $1}')
	if [ "${iotdb_pid}" = "" ]; then
		echo "未检测到ConfigNode程序！"
	else
		kill -9 ${iotdb_pid}
		echo "ConfigNode程序已停止！"
	fi
	iotdb_pid=$(jps | grep IoTDB | awk '{print $1}')
	if [ "${iotdb_pid}" = "" ]; then
		echo "未检测到IoTDB程序！"
	else
		kill -9 ${iotdb_pid}
		echo "IoTDB程序已停止！"
	fi
	echo "程序检测和清理操作已完成！"
}
set_env() { # 拷贝编译好的iotdb到测试路径
	if [ ! -d "${TEST_IOTDB_PATH}" ]; then
		mkdir -p ${TEST_IOTDB_PATH}
	else
		rm -rf ${TEST_IOTDB_PATH}
		mkdir -p ${TEST_IOTDB_PATH}
	fi
	cp -rf ${REPOS_PATH}/${commit_id}/apache-iotdb/* ${TEST_IOTDB_PATH}/
	mkdir -p ${TEST_IOTDB_PATH}/activation
	cp -rf ${ATMOS_PATH}/conf/${test_type}/license ${TEST_IOTDB_PATH}/activation/
	#添加series_slot_num的替换，防止历史数据无法启动
	echo "series_slot_num=10000" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	#变更合并目标文件大小（因为目前准备的数据文件大小只有1.1G）
	echo "target_compaction_file_size=1073741824" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
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
set_protocol_class() { 
	config_node=$1
	schema_region=$2
	data_region=$3
	#设置协议
	echo "config_node_consensus_protocol_class=${protocol_class[${config_node}]}" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "schema_region_consensus_protocol_class=${protocol_class[${schema_region}]}" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "data_region_consensus_protocol_class=${protocol_class[${data_region}]}" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
}
start_iotdb() { # 启动iotdb
	cd ${TEST_IOTDB_PATH}
	./sbin/start-confignode.sh >/dev/null 2>&1 &
	sleep 10
	./sbin/start-datanode.sh -H ${TEST_IOTDB_PATH}/dn_dump.hprof >/dev/null 2>&1 &
	cd ~/
}
stop_iotdb() { # 停止iotdb
	cd ${TEST_IOTDB_PATH}
	./sbin/stop-datanode.sh >/dev/null 2>&1 &
	sleep 10
	./sbin/stop-confignode.sh >/dev/null 2>&1 &
	cd ~/
}
monitor_test_status() { # 监控测试运行状态，获取最大打开文件数量和最大线程数
	start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
	maxNumofOpenFiles=0
	maxNumofThread=0
	for (( t_wait = 0; t_wait <= 20; ))
	do
		#监控打开文件数量
		pid=$(jps | grep DataNode | awk '{print $1}')
		if [ "${pid}" = "" ]; then
			temp_file_num_d=0
			temp_thread_num_d=0
		else
			temp_file_num_d=$(jps | grep DataNode | awk '{print $1}' | xargs lsof -p | wc -l)
			temp_thread_num_d=$(pstree -p $(ps aux | grep -v grep | grep DataNode | awk '{print $2}') | wc -l)
		fi
		pid=$(jps | grep ConfigNode | awk '{print $1}')
		if [ "${pid}" = "" ]; then
			temp_file_num_c=0
			temp_thread_num_c=0
		else
			temp_file_num_c=$(jps | grep ConfigNode | awk '{print $1}' | xargs lsof -p | wc -l)
			temp_thread_num_c=$(pstree -p $(ps aux | grep -v grep | grep ConfigNode | awk '{print $2}') | wc -l)
		fi
		pid=$(jps | grep IoTDB | awk '{print $1}')
		if [ "${pid}" = "" ]; then
			temp_file_num_i=0
			temp_thread_num_i=0
		else
			temp_file_num_i=$(jps | grep IoTDB | awk '{print $1}' | xargs lsof -p | wc -l)
			temp_thread_num_i=$(pstree -p $(ps aux | grep -v grep | grep IoTDB| awk '{print $2}') | wc -l)
		fi
		let temp_file_num=${temp_file_num_d}+${temp_file_num_c}+${temp_file_num_i}
		if [ ${maxNumofOpenFiles} -lt ${temp_file_num} ]; then
			maxNumofOpenFiles=${temp_file_num}
		fi
		#监控线程数
		let temp_thread_num=${temp_thread_num_d}+${temp_thread_num_c}+${temp_thread_num_i}
		if [ ${maxNumofThread} -lt ${temp_thread_num} ]; then
			maxNumofThread=${temp_thread_num}
		fi
		#监控合并执行情况  
		cd ${TEST_IOTDB_PATH}/data/datanode/data
		numOfcompactioning=$(find . -name "*compaction.log" | wc -l)
		if [ ${numOfcompactioning} -le 0 ]; then
			sleep 70s
			numOfcompactioning=$(find . -name "*compaction.log" | wc -l)
			if [ ${numOfcompactioning} -le 0 ]; then
				log_compaction=${TEST_IOTDB_PATH}/logs/log_datanode_compaction.log
				if [ ! -f "$log_compaction" ]; then
					now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
					t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
					if [ $t_time -ge 7200 ]; then
						echo "测试失败"  #倒序输入形成负数结果
						str1="2022-11-27 16:36:57,753 [pool-21-IoTDB-Compaction-1] INFO  o.a.i.d.e.c.c.CrossSpaceCompactionTask:207 - root.test.g_0-1 [Compaction] CrossSpaceCompaction task finishes successfully, time cost is -1 s, compaction speed is 1.9099134471928962 MB/s"
						str2="2022-11-27 15:54:50,568 [pool-21-IoTDB-Compaction-1] INFO  o.a.i.d.e.c.i.InnerSpaceCompactionTask:239 - root.test.g_0-1 [Compaction] InnerSpaceCompaction task finishes successfully, target file is 1668674556813-1-1-0.tsfile,time cost is -1 s, compaction speed is 16.47907336936178 MB/s"
						echo ${str1} >>$log_compaction
						echo ${str2} >>$log_compaction						
						break
					fi
					continue
				else
					echo "${comp_type}合并已完成"
					break
				fi
			fi
		else
			log_compaction=${TEST_IOTDB_PATH}/logs/log_datanode_compaction.log
			now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
			if [ $t_time -ge 7200 ]; then
				echo "测试失败"  #倒序输入形成负数结果
				str1="2022-11-27 16:36:57,753 [pool-21-IoTDB-Compaction-1] INFO  o.a.i.d.e.c.c.CrossSpaceCompactionTask:207 - root.test.g_0-1 [Compaction] CrossSpaceCompaction task finishes successfully, time cost is -1 s, compaction speed is 1.9099134471928962 MB/s"
				str2="2022-11-27 15:54:50,568 [pool-21-IoTDB-Compaction-1] INFO  o.a.i.d.e.c.i.InnerSpaceCompactionTask:239 - root.test.g_0-1 [Compaction] InnerSpaceCompaction task finishes successfully, target file is 1668674556813-1-1-0.tsfile,time cost is -1 s, compaction speed is 16.47907336936178 MB/s"
				echo ${str1} >>$log_compaction
				echo ${str2} >>$log_compaction								
				break
			fi
			sleep 10
			continue
		fi
	done
}
collect_data_before() { # 收集iotdb数据大小，顺、乱序文件数量
	cd ${TEST_IOTDB_PATH}
	dataFileSize_before=$(dir_size_gb "${TEST_IOTDB_PATH}/data")
	numOfSe0Level_before=$(count_tsfiles "${TEST_IOTDB_PATH}/data/datanode/data/sequence" "*-0-*.tsfile")
	numOfUnse0Level_before=$(count_tsfiles "${TEST_IOTDB_PATH}/data/datanode/data/unsequence" "*-0-*.tsfile")
}
collect_data_after() { # 收集iotdb数据大小，顺、乱序文件数量
	#收集启动后基础监控数据
	cd ${TEST_IOTDB_PATH}
	dataFileSize_after=$(dir_size_gb "${TEST_IOTDB_PATH}/data")
	numOfSe0Level_after=$(count_tsfiles "${TEST_IOTDB_PATH}/data/datanode/data/sequence" "*-0-*.tsfile")
	numOfUnse0Level_after=$(count_tsfiles "${TEST_IOTDB_PATH}/data/datanode/data/unsequence" "*-0-*.tsfile")
	compaction_rate=0
	ts_dataSize=0
	ts_numOfPoints=0
	cost_time=""
	if [ -f "${TEST_IOTDB_PATH}/logs/log_datanode_compaction.log" ]; then
		comp_start_time=$(awk 'NR==1{print $1,$2}' "${TEST_IOTDB_PATH}/logs/log_datanode_compaction.log" | cut -c 1-19)
		comp_end_time=$(awk 'END{print $1,$2}' "${TEST_IOTDB_PATH}/logs/log_datanode_compaction.log" | cut -c 1-19)
		cost_time=$(grep "InnerSpaceCompaction task finishes successfully" "${TEST_IOTDB_PATH}/logs/log_datanode_compaction.log" | tail -n 1 | sed -n 's/.*time cost is \([-0-9.]*\) s.*/\1/p')
		if [ "${cost_time}" = "" ]; then
			cost_time=$(grep "CrossSpaceCompaction task finishes successfully" "${TEST_IOTDB_PATH}/logs/log_datanode_compaction.log" | tail -n 1 | sed -n 's/.*time cost is \([-0-9.]*\) s.*/\1/p')
		fi
	fi
	if [ "${cost_time}" = "" ]; then
		cost_time=-1
	fi
	if [ -s "${TEST_IOTDB_PATH}/logs/log_datanode_error.log" ] || [ -s "${TEST_IOTDB_PATH}/logs/log_confignode_error.log" ]; then
		errorLogSize=1
	else
		errorLogSize=0
	fi
}
insert_database() { # 收集iotdb数据大小，顺、乱序文件数量
	#收集启动后基础监控数据
	remark_value=$1
	insert_sql="insert into ${TABLENAME}\
	(commit_date_time,test_date_time,commit_id,author,ts_type,comp_type,cost_time,numOfSe0Level_before,numOfSe0Level_after,\
	numOfUnse0Level_before,numOfUnse0Level_after,ts_dataSize,ts_numOfPoints,\
	compaction_rate,comp_start_time,comp_end_time,dataFileSize_before,dataFileSize_after,maxNumofOpenFiles,maxNumofThread,errorLogSize,\
	avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark) \
	values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}','${comp_type}',${cost_time},${numOfSe0Level_before},\
	${numOfSe0Level_after},${numOfUnse0Level_before},${numOfUnse0Level_after},\
	${ts_dataSize},${ts_numOfPoints},${compaction_rate},'${comp_start_time}',\
	'${comp_end_time}','${dataFileSize_before}','${dataFileSize_after}',${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},\
	${avgCPULoad},${maxCPULoad},${maxDiskIOSizeRead},${maxDiskIOSizeWrite},${maxDiskIOOpsRead},${maxDiskIOOpsWrite},'${remark_value}')"
	echo ${ts_type}时间序列 ${comp_type} 合并耗时为：${cost_time} 秒
	run_mysql "${insert_sql}"
	echo ${insert_sql}
}
backup_test_data() { # 备份测试数据
	sudo rm -rf ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_id}
	sudo mkdir -p ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_id}
    sudo rm -rf ${TEST_IOTDB_PATH}/data
	sudo mv ${TEST_IOTDB_PATH} ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_id}
}
set_iotdb_property() {
	local key=$1
	local value=$2
	local conf_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	if grep -q "^${key}=" "${conf_file}"; then
		sed -i "s|^${key}=.*$|${key}=${value}|g" "${conf_file}"
	else
		echo "${key}=${value}" >> "${conf_file}"
	fi
}
set_datanode_heap() {
	sed -i "s/^#\?ON_HEAP_MEMORY=.*$/ON_HEAP_MEMORY=\"20G\"/g" "${TEST_IOTDB_PATH}/conf/datanode-env.sh"
}
configure_compaction_case() {
	local seq_enabled=$1
	local unseq_enabled=$2
	local cross_enabled=$3
	local target_size=$4
	set_datanode_heap
	set_iotdb_property "enable_seq_space_compaction" "${seq_enabled}"
	set_iotdb_property "enable_unseq_space_compaction" "${unseq_enabled}"
	set_iotdb_property "enable_cross_space_compaction" "${cross_enabled}"
	set_iotdb_property "target_compaction_file_size" "${target_size}"
}
wait_iotdb_ready() {
	local retry_count=$1
	local sleep_seconds=$2
	local t_wait
	local iotdb_state
	for (( t_wait = 0; t_wait <= retry_count; t_wait++ ))
	do
		iotdb_state=$("${TEST_IOTDB_PATH}/sbin/start-cli.sh" -e "show cluster" | grep 'Total line number = 2')
		if [ "${iotdb_state}" = "Total line number = 2" ]; then
			return 0
		fi
		sleep "${sleep_seconds}"
	done
	return 1
}
collect_prometheus_metrics() {
	local start_time=$1
	local end_time=$2
	local duration=$((end_time-start_time))
	maxCPULoad=$(get_single_index "max_over_time(sys_cpu_load{instance=~\"${TEST_IP}:9091\"}[${duration}s])" "${end_time}")
	avgCPULoad=$(get_single_index "avg_over_time(sys_cpu_load{instance=~\"${TEST_IP}:9091\"}[${duration}s])" "${end_time}")
	maxDiskIOOpsRead=$(get_single_index "rate(disk_io_ops{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"read\"}[${duration}s])" "${end_time}")
	maxDiskIOOpsWrite=$(get_single_index "rate(disk_io_ops{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"write\"}[${duration}s])" "${end_time}")
	maxDiskIOSizeRead=$(get_single_index "rate(disk_io_size{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"read\"}[${duration}s])" "${end_time}")
	maxDiskIOSizeWrite=$(get_single_index "rate(disk_io_size{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"write\"}[${duration}s])" "${end_time}")
}
archive_compaction_logs() {
	local archive_name=$1
	if [ -d "${TEST_IOTDB_PATH}/logs" ]; then
		mkdir -p "${TEST_IOTDB_PATH}/${archive_name}"
		cp -rf "${TEST_IOTDB_PATH}/conf" "${TEST_IOTDB_PATH}/${archive_name}"
		mv "${TEST_IOTDB_PATH}/logs" "${TEST_IOTDB_PATH}/${archive_name}"
	fi
}
mark_restart_error() {
	local remark_value=$1
	cost_time=-3
	insert_database "${remark_value}"
	update_sql="update ${TASK_TABLENAME} set ${test_type} = 'RError' where commit_id = '${commit_id}'"
	result_string=$(run_mysql "${update_sql}")
}
run_compaction_case() {
	comp_type=$1
	local seq_enabled=$2
	local unseq_enabled=$3
	local cross_enabled=$4
	local target_size=$5
	local retry_count=$6
	local sleep_seconds=$7
	local m_start_time
	local m_end_time

	configure_compaction_case "${seq_enabled}" "${unseq_enabled}" "${cross_enabled}" "${target_size}"
	collect_data_before
	start_iotdb
	m_start_time=$(date +%s)
	sleep 10
	if wait_iotdb_ready "${retry_count}" "${sleep_seconds}"; then
		echo "IoTDB正常启动，准备开始测试"
	else
		echo "IoTDB未能正常启动，写入负值测试结果！"
		mark_restart_error "${protocol_id}"
		return 1
	fi
	sleep 30
	monitor_test_status
	stop_iotdb
	sleep 30
	check_iotdb_pid
	collect_data_after
	m_end_time=$(date +%s)
	collect_prometheus_metrics "${m_start_time}" "${m_end_time}"
	insert_database "${protocol_id}"
	archive_compaction_logs "${comp_type}"
	return 0
}
test_operation() {
	protocol_id=$1
	ts_type=$2
	echo "开始测试${ts_type}时间序列！"
	#清理环境，确保无就程序影响
	check_iotdb_pid
	#复制当前程序到执行位置
	set_env
	if [ "${protocol_id}" = "111" ]; then
		set_protocol_class 1 1 1
	elif [ "${protocol_id}" = "222" ]; then
		set_protocol_class 2 2 2
	elif [ "${protocol_id}" = "223" ]; then
		set_protocol_class 2 2 3
	elif [ "${protocol_id}" = "211" ]; then
		set_protocol_class 2 1 1
	else
		echo "协议设置错误！"
		return
	fi
	#mkdir -p ${TEST_IOTDB_PATH}/data
	cp -rf ${DATA_PATH}/${protocol_id}/${ts_type}/data ${TEST_IOTDB_PATH}/
	###############################seq_space合并###############################
	if ! run_compaction_case seq_space true false false 1073741824 10 5; then
		return
	fi
	#同步服务器监控数据到统一的表内
	#drop_monitor_table
	###############################unseq_space合并###############################
	if ! run_compaction_case unseq_space false true false 1073741824 20 30; then
		return
	fi
	###############################cross_space合并###############################
	if ! run_compaction_case cross_space false false true 2147483648 20 30; then
		return
	fi
	#备份本次测试
	backup_test_data ${ts_type}
}

##准备开始测试
echo "ontesting" > ${INIT_PATH}/test_type_file
query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${test_type} = 'retest' ORDER BY commit_date_time desc limit 1 "
result_string=$(run_mysql "${query_sql}")
commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
##查询是否有复测任务
if [ "${commit_id}" = "" ]; then
	query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${test_type} is NULL ORDER BY commit_date_time desc limit 1 "
	result_string=$(run_mysql "${query_sql}")
	commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
	author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
	commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
fi
if [ "${commit_id}" = "" ]; then
	sleep 60s
else
	update_sql="update ${TASK_TABLENAME} set ${test_type} = 'ontesting' where commit_id = '${commit_id}'"
	result_string=$(run_mysql "${update_sql}")
	echo "当前版本${commit_id}未执行过测试，即将编译后启动"
	if [ "${author}" != "Timecho" ]; then
		TABLENAME=${TABLENAME}
	else
		TABLENAME=${TABLENAME_T}
	fi
	init_items
	test_date_time=`date +%Y%m%d%H%M%S`
	echo "开始测试211协议下的common时间序列！"
	test_operation 211 common
	echo "开始测试211协议下的aligned时间序列！"
	test_operation 211 aligned
	###############################测试完成###############################
	echo "本轮测试${test_date_time}已结束."
	update_sql="update ${TASK_TABLENAME} set ${test_type} = 'done' where commit_id = '${commit_id}'"
	result_string=$(run_mysql "${update_sql}")
	update_sql02="update ${TASK_TABLENAME} set ${test_type} = 'skip' where ${test_type} is NULL and commit_date_time < '${commit_date_time}'"
	if [ "${author}" != "Timecho" ]; then
		result_string=$(run_mysql "${update_sql02}")
	fi
fi
echo "${test_type}" > ${INIT_PATH}/test_type_file
