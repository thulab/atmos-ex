#!/usr/bin/env bash
#登录用户名
test_type=restart_db
#初始环境存放路径
INIT_PATH=/data/atmos/zk_test
ATMOS_PATH=${INIT_PATH}/atmos-ex
DATA_PATH=/data/atmos/DataSet
BUCKUP_PATH=/nasdata/repository/restart_db
REPOS_PATH=/nasdata/repository/master
#测试数据运行路径
TEST_INIT_PATH=/data/atmos
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb

############mysql信息##########################
MYSQLHOSTNAME="111.200.37.158" #数据库信息
PORT="13306"
USERNAME="iotdbatm"
PASSWORD=${ATMOS_DB_PASSWORD}
DBNAME="QA_ATM"  #数据库名称
TABLENAME="ex_restart_db" #数据库中表的名称
TABLENAME_T="ex_restart_db_T" #企业版结果表名
TASK_TABLENAME="ex_commit_history" #数据库中任务表的名称
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
	if [ ! -d "${target_dir}" ]; then
		echo 0
	else
		find "${target_dir}" -name "*.tsfile" | wc -l
	fi
}
grep_count() {
	local log_file=$1
	local pattern=$2
	if [ ! -f "${log_file}" ]; then
		echo 0
	else
		grep -E -c "${pattern}" "${log_file}" 2>/dev/null
	fi
}
init_items() {
############定义监控采集项初始值##########################
test_date_time=0
ts_type=0
data_type=0
cost_time=0
numOfSe0Level_before=0
numOfSe0Level_after=0
numOfUnse0Level_before=0
numOfUnse0Level_after=0
start_time=0
end_time=0
dataFileSize_before=0
dataFileSize_after=0
WALSize_before=0
WALSize_after=0
maxNumofOpenFiles=0
maxNumofThread=0
errorLogSize=0
############定义监控采集项初始值##########################
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
}
modify_iotdb_config() { # iotdb调整内存，关闭合并
	local conf_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	local property
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"20G\"/g" "${TEST_IOTDB_PATH}/conf/datanode-env.sh"
	for property in \
		"cluster_name=${test_type}" \
		"cn_enable_metric=true" \
		"cn_enable_performance_stat=true" \
		"cn_metric_reporter_list=PROMETHEUS" \
		"cn_metric_level=ALL" \
		"cn_metric_prometheus_reporter_port=9081" \
		"dn_enable_metric=true" \
		"dn_enable_performance_stat=true" \
		"dn_metric_reporter_list=PROMETHEUS" \
		"dn_metric_level=ALL" \
		"dn_metric_prometheus_reporter_port=9091"
	do
		echo "${property}" >> "${conf_file}"
	done
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
		#监控执行情况  
		ts_status=$(grep_count "${TEST_IOTDB_PATH}/logs/log_datanode_all.log" 'IoTDB DataNode is set up successfully. Now, enjoy yourself!')
		if [ ${ts_status} -le 0 ]; then
			now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
			if [ $t_time -ge 7200 ]; then
				echo "测试失败"  #倒序输入形成负数结果
				end_time=-1
				cost_time=-100
				break
			fi
			sleep 10
			continue
		else
			echo "${data_type}已完成"
			cd ${TEST_IOTDB_PATH}/logs/
			#start_time=$(find ./* -name log_datanode_all.log | xargs grep "IoTDB-DataNode environment variables" | awk '{print $1 FS $2}')
			start_time=$(find ./* -name log_datanode_all.log | xargs sed -n '1p' | awk '{print $1 FS $2}')
			end_time=$(find ./* -name log_datanode_all.log | xargs grep "IoTDB DataNode is set up successfully. Now, enjoy yourself" | awk '{print $1 FS $2}')
			#新增判断是否可以cli登录查询
			iotdb_state=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw root -e "show cluster" | grep 'Total line number = 2')
			if [ "${iotdb_state}" = "Total line number = 2" ]; then
				cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
			else
				cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
				cost_time=-50
				echo "启动后无法登陆和查询"
			fi
			break
		fi
	done
}
collect_data_before() { # 收集iotdb数据大小，顺、乱序文件数量
	COLLECT_PATH=$1
	dataFileSize_before=$(dir_size_gb "${COLLECT_PATH}/data/datanode/data")
	numOfSe0Level_before=$(count_tsfiles "${COLLECT_PATH}/data/datanode/data/sequence")
	numOfUnse0Level_before=$(count_tsfiles "${COLLECT_PATH}/data/datanode/data/unsequence")
	WALSize_before=$(dir_size_gb "${COLLECT_PATH}/data/datanode/wal")
}
collect_data_after() { # 收集iotdb数据大小，顺、乱序文件数量
	#收集启动后基础监控数据
	COLLECT_PATH=$1
	dataFileSize_after=$(dir_size_gb "${COLLECT_PATH}/data/datanode/data")
	numOfSe0Level_after=$(count_tsfiles "${COLLECT_PATH}/data/datanode/data/sequence")
	numOfUnse0Level_after=$(count_tsfiles "${COLLECT_PATH}/data/datanode/data/unsequence")
	WALSize_after=$(dir_size_gb "${COLLECT_PATH}/data/datanode/wal")
	if [ -s "${COLLECT_PATH}/logs/log_datanode_error.log" ] || [ -s "${COLLECT_PATH}/logs/log_confignode_error.log" ]; then
		errorLogSize=1
	else
		errorLogSize=0
	fi
}
insert_database() { # 收集iotdb数据大小，顺、乱序文件数量
	#收集启动后基础监控数据
	remark_value=$1
	insert_sql="insert into ${TABLENAME}\
	(commit_date_time,test_date_time,commit_id,author,ts_type,data_type,cost_time,numOfSe0Level_before,numOfSe0Level_after,\
	numOfUnse0Level_before,numOfUnse0Level_after,start_time,end_time,dataFileSize_before,dataFileSize_after,WALSize_before,WALSize_after,maxNumofOpenFiles,maxNumofThread,errorLogSize,remark) \
	values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}','${data_type}',${cost_time},${numOfSe0Level_before},${numOfSe0Level_after},\
	${numOfUnse0Level_before},${numOfUnse0Level_after},'${start_time}','${end_time}','${dataFileSize_before}','${dataFileSize_after}','${WALSize_before}','${WALSize_after}',${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},'${remark_value}')"
	echo ${ts_type}时间序列 ${data_type} 操作耗时为：${cost_time} 秒
	run_mysql "${insert_sql}"
	echo ${insert_sql}
}
backup_test_data() { # 备份测试数据
	sudo rm -rf ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_id}
	sudo mkdir -p ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_id}
    sudo rm -rf ${TEST_IOTDB_PATH}/data
	sudo mv ${TEST_IOTDB_PATH} ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_id}
}
run_restart_case() {
	local remark_value=$1
	local archive_dir=$2
	collect_data_before "${TEST_IOTDB_PATH}/"
	start_iotdb
	sleep 10
	monitor_test_status
	sleep 10
	stop_iotdb
	sleep 10
	check_iotdb_pid
	collect_data_after "${TEST_IOTDB_PATH}"
	insert_database "${remark_value}"
	if [ "${archive_dir}" != "" ] && [ -d "${TEST_IOTDB_PATH}/logs" ]; then
		mv "${TEST_IOTDB_PATH}/logs" "${TEST_IOTDB_PATH}/${archive_dir}"
	fi
}
test_operation() {
	protocol_id=$1
	ts_type=$2
	data_type=$3
	echo "开始测试${ts_type}时间序列！${data_type}"
	#清理环境，确保无就程序影响
	check_iotdb_pid
	#复制当前程序到执行位置
	set_env
	modify_iotdb_config
	#############################导入#############################
	cp -rf ${DATA_PATH}/data ${TEST_IOTDB_PATH}/
	run_restart_case restart_db R1
	#增加异地关机优化检测
	run_restart_case restart_db_2 ""
	#备份本次测试
	backup_test_data common	
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
	test_operation 211 common sequence
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
