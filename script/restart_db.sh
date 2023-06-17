#!/bin/sh
#登录用户名
ACCOUNT=atmos
test_type=restart_db
#初始环境存放路径
INIT_PATH=/data/atmos/zk_test
ATMOS_PATH=${INIT_PATH}/atmos-ex
BM_PATH=${INIT_PATH}/iot-benchmark
DATA_PATH=/data/atmos/DataSet
BUCKUP_PATH=/nasdata/repository/restart_db
REPOS_PATH=/nasdata/repository/master
#测试数据运行路径
TEST_INIT_PATH=/data/atmos
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb
# 1. org.apache.iotdb.consensus.simple.SimpleConsensus
# 2. org.apache.iotdb.consensus.ratis.RatisConsensus
# 3. org.apache.iotdb.consensus.iot.IoTConsensus
protocol_class=(0 org.apache.iotdb.consensus.simple.SimpleConsensus org.apache.iotdb.consensus.ratis.RatisConsensus org.apache.iotdb.consensus.iot.IoTConsensus)
protocol_list=(111 223 222 211)
data_type=(sequence unsequence)
ts_list=(common aligned template tempaligned)

############mysql信息##########################
MYSQLHOSTNAME="111.202.73.147" #数据库信息
PORT="13306"
USERNAME="iotdbatm"
PASSWORD="iotdb2019"
DBNAME="QA_ATM"  #数据库名称
TABLENAME="ex_restart_db" #数据库中表的名称
TASK_TABLENAME="ex_commit_history" #数据库中任务表的名称
############公用函数##########################
#echo "Started at: " date -d today +"%Y-%m-%d %H:%M:%S"
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
local_ip=`ifconfig -a|grep inet|grep -v 127.0.0.1|grep -v inet6|awk '{print $2}'|tr -d "addr:"`
sendEmail() {
sendEmail=$(${TOOLS_PATH}/sendEmail.sh $1 >/dev/null 2>&1 &)
}
check_benchmark_pid() { # 检查benchmark-moitor的pid，有就停止
	monitor_pid=$(jps | grep App | awk '{print $1}')
	if [ "${monitor_pid}" = "" ]; then
		echo "未检测到监控程序！"
	else
		kill -9 ${monitor_pid}
		echo "BM程序已停止！"
	fi
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
}
modify_iotdb_config() { # iotdb调整内存，关闭合并
	#修改IoTDB的配置
	sed -i "s/^#MAX_HEAP_SIZE=\"2G\".*$/MAX_HEAP_SIZE=\"20G\"/g" ${TEST_IOTDB_PATH}/conf/datanode-env.sh
	#关闭影响写入性能的其他功能
	#sed -i "s/^# enable_seq_space_compaction=true.*$/enable_seq_space_compaction=false/g" ${TEST_IOTDB_PATH}/conf/iotdb-common.properties
	#sed -i "s/^# enable_unseq_space_compaction=true.*$/enable_unseq_space_compaction=false/g" ${TEST_IOTDB_PATH}/conf/iotdb-common.properties
	#sed -i "s/^# enable_cross_space_compaction=true.*$/enable_cross_space_compaction=false/g" ${TEST_IOTDB_PATH}/conf/iotdb-common.properties
	#添加启动监控功能
	sed -i "s/^# cn_enable_metric=.*$/cn_enable_metric=true/g" ${TEST_IOTDB_PATH}/conf/iotdb-confignode.properties
	sed -i "s/^# cn_enable_performance_stat=.*$/cn_enable_performance_stat=true/g" ${TEST_IOTDB_PATH}/conf/iotdb-confignode.properties
	sed -i "s/^# cn_metric_reporter_list=.*$/cn_metric_reporter_list=PROMETHEUS/g" ${TEST_IOTDB_PATH}/conf/iotdb-confignode.properties
	sed -i "s/^# cn_metric_level=.*$/cn_metric_level=ALL/g" ${TEST_IOTDB_PATH}/conf/iotdb-confignode.properties
	sed -i "s/^# cn_metric_prometheus_reporter_port=.*$/cn_metric_prometheus_reporter_port=9081/g" ${TEST_IOTDB_PATH}/conf/iotdb-confignode.properties
	#添加启动监控功能
	sed -i "s/^# dn_enable_metric=.*$/dn_enable_metric=true/g" ${TEST_IOTDB_PATH}/conf/iotdb-datanode.properties
	sed -i "s/^# dn_enable_performance_stat=.*$/dn_enable_performance_stat=true/g" ${TEST_IOTDB_PATH}/conf/iotdb-datanode.properties
	sed -i "s/^# dn_metric_reporter_list=.*$/dn_metric_reporter_list=PROMETHEUS/g" ${TEST_IOTDB_PATH}/conf/iotdb-datanode.properties
	sed -i "s/^# dn_metric_level=.*$/dn_metric_level=ALL/g" ${TEST_IOTDB_PATH}/conf/iotdb-datanode.properties
	sed -i "s/^# dn_metric_prometheus_reporter_port=.*$/dn_metric_prometheus_reporter_port=9091/g" ${TEST_IOTDB_PATH}/conf/iotdb-datanode.properties
}
set_protocol_class() { 
	config_node=$1
	schema_region=$2
	data_region=$3
	#设置协议
	sed -i "s/^# config_node_consensus_protocol_class=.*$/config_node_consensus_protocol_class=${protocol_class[${config_node}]}/g" ${TEST_IOTDB_PATH}/conf/iotdb-common.properties
	sed -i "s/^# schema_region_consensus_protocol_class=.*$/schema_region_consensus_protocol_class=${protocol_class[${schema_region}]}/g" ${TEST_IOTDB_PATH}/conf/iotdb-common.properties
	sed -i "s/^# data_region_consensus_protocol_class=.*$/data_region_consensus_protocol_class=${protocol_class[${data_region}]}/g" ${TEST_IOTDB_PATH}/conf/iotdb-common.properties
}
start_iotdb() { # 启动iotdb
	cd ${TEST_IOTDB_PATH}
	conf_start=$(./sbin/start-confignode.sh >/dev/null 2>&1 &)
	sleep 10
	data_start=$(./sbin/start-datanode.sh >/dev/null 2>&1 &)
	cd ~/
}
stop_iotdb() { # 停止iotdb
	cd ${TEST_IOTDB_PATH}
	data_stop=$(./sbin/stop-datanode.sh >/dev/null 2>&1 &)
	sleep 10
	conf_stop=$(./sbin/stop-confignode.sh >/dev/null 2>&1 &)
	cd ~/
}
start_benchmark() { # 启动benchmark
	cd ${BM_PATH}
	if [ -d "${BM_PATH}/logs" ]; then
		rm -rf ${BM_PATH}/logs
	fi
	if [ ! -d "${BM_PATH}/data" ]; then
		bm_start=$(${BM_PATH}/benchmark.sh >/dev/null 2>&1 &)
	else
		rm -rf ${BM_PATH}/data
		bm_start=$(${BM_PATH}/benchmark.sh >/dev/null 2>&1 &)
	fi
	cd ~/
}
monitor_test_status() { # 监控测试运行状态，获取最大打开文件数量和最大线程数
	start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
	maxNumofOpenFiles=0
	for (( t_wait = 0; t_wait <= 100; ))
	do
		#监控打开文件数量
		pid=$(jps | grep DataNode | awk '{print $1}')
		if [ "${pid}" = "" ]; then
			temp_file_num_d=0
			temp_thread_num_d=0
		else
			temp_file_num_d=$(jps | grep DataNode | awk '{print $1}' | xargs lsof -p | wc -l)
			temp_thread_num_d=$(pstree -p $(ps -e | grep DataNode | awk '{print $1}') | wc -l)
		fi
		pid=$(jps | grep ConfigNode | awk '{print $1}')
		if [ "${pid}" = "" ]; then
			temp_file_num_c=0
			temp_thread_num_c=0
		else
			temp_file_num_c=$(jps | grep ConfigNode | awk '{print $1}' | xargs lsof -p | wc -l)
			temp_thread_num_c=$(pstree -p $(ps -e | grep ConfigNode | awk '{print $1}') | wc -l)
		fi
		pid=$(jps | grep IoTDB | awk '{print $1}')
		if [ "${pid}" = "" ]; then
			temp_file_num_i=0
			temp_thread_num_i=0
		else
			temp_file_num_i=$(jps | grep IoTDB | awk '{print $1}' | xargs lsof -p | wc -l)
			temp_thread_num_i=$(pstree -p $(ps -e | grep IoTDB | awk '{print $1}') | wc -l)
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
		ts_status=$(cat ${TEST_IOTDB_PATH}/logs/log_datanode_all.log | grep 'Congratulation, IoTDB DataNode is set up successfully. Now, enjoy yourself!'| wc -l)
		if [ ${ts_status} -le 0 ]; then
			now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
			if [ $t_time -ge 7200 ]; then
				echo "测试失败"  #倒序输入形成负数结果
				end_time=-1
				cost_time=-100
				break
			fi
			continue
		else
			echo "${data_type}已完成"
			cd ${TEST_IOTDB_PATH}/logs/
			start_time=$(find ./* -name log_datanode_all.log | xargs grep "IoTDB-DataNode environment variables" | awk '{print $1 FS $2}')
			end_time=$(find ./* -name log_datanode_all.log | xargs grep "Congratulation, IoTDB DataNode is set up successfully. Now, enjoy yourself" | awk '{print $1 FS $2}')
			cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
			break
		fi
	done
}
collect_data_before() { # 收集iotdb数据大小，顺、乱序文件数量
	COLLECT_PATH=$1
	dataFileSize_before=$(du -h -d0 ${COLLECT_PATH}/data/datanode/data | awk {'print $1'} | awk '{sub(/.$/,"")}1')
	UNIT=$(du -h -d0 ${COLLECT_PATH}/data/datanode/data | awk {'print $1'} | awk -F '' '$0=$NF')
	if [ "$UNIT" = "M" ]; then
		dataFileSize_before=`awk 'BEGIN{printf "%.2f\n",'$dataFileSize_before'/'1024'}'`
	elif [ "$UNIT" = "K" ]; then
		dataFileSize_before=`awk 'BEGIN{printf "%.2f\n",'$dataFileSize_before'/'1048576'}'`
	else
		dataFileSize_before=${dataFileSize_before}
	fi
	numOfSe0Level_before=$(find ${COLLECT_PATH}/data/datanode/data/sequence -name "*.tsfile" | wc -l)
	if [ ! -d "${COLLECT_PATH}/data/datanode/data/unsequence" ]; then
		numOfUnse0Level_before=0
	else
		numOfUnse0Level_before=$(find ${COLLECT_PATH}/data/datanode/data/unsequence -name "*.tsfile" | wc -l)
	fi
	WALSize_before=$(du -h -d0 ${COLLECT_PATH}/data/datanode/wal | awk {'print $1'} | awk '{sub(/.$/,"")}1')
	UNIT=$(du -h -d0 ${COLLECT_PATH}/data/datanode/wal | awk {'print $1'} | awk -F '' '$0=$NF')
	if [ "$UNIT" = "M" ]; then
		WALSize_before=`awk 'BEGIN{printf "%.2f\n",'$WALSize_before'/'1024'}'`
	elif [ "$UNIT" = "K" ]; then
		WALSize_before=`awk 'BEGIN{printf "%.2f\n",'$WALSize_before'/'1048576'}'`
	else
		WALSize_before=${WALSize_before}
	fi
}
collect_data_after() { # 收集iotdb数据大小，顺、乱序文件数量
	#收集启动后基础监控数据
	COLLECT_PATH=$1
	dataFileSize_after=$(du -h -d0 ${COLLECT_PATH}/data/datanode/data | awk {'print $1'} | awk '{sub(/.$/,"")}1')
	UNIT=$(du -h -d0 ${COLLECT_PATH}/data/datanode/data | awk {'print $1'} | awk -F '' '$0=$NF')
	if [ "$UNIT" = "M" ]; then
		dataFileSize_after=`awk 'BEGIN{printf "%.2f\n",'$dataFileSize_after'/'1024'}'`
	elif [ "$UNIT" = "K" ]; then
		dataFileSize_after=`awk 'BEGIN{printf "%.2f\n",'$dataFileSize_after'/'1048576'}'`
	else
		dataFileSize_after=${dataFileSize_after}
	fi
	numOfSe0Level_after=$(find ${COLLECT_PATH}/data/datanode/data/sequence -name "*.tsfile" | wc -l)
	if [ ! -d "${COLLECT_PATH}/data/datanode/data/unsequence" ]; then
		numOfUnse0Level_after=0
	else
		numOfUnse0Level_after=$(find ${COLLECT_PATH}/data/datanode/data/unsequence -name "*.tsfile" | wc -l)
	fi
	WALSize_after=$(du -h -d0 ${COLLECT_PATH}/data/datanode/wal | awk {'print $1'} | awk '{sub(/.$/,"")}1')
	UNIT=$(du -h -d0 ${COLLECT_PATH}/data/datanode/wal | awk {'print $1'} | awk -F '' '$0=$NF')
	if [ "$UNIT" = "M" ]; then
		WALSize_after=`awk 'BEGIN{printf "%.2f\n",'$WALSize_after'/'1024'}'`
	elif [ "$UNIT" = "K" ]; then
		WALSize_after=`awk 'BEGIN{printf "%.2f\n",'$WALSize_after'/'1048576'}'`
	else
		WALSize_after=${WALSize_after}
	fi
	D_ErrorLogSize=$(du -sh ${COLLECT_PATH}/logs/log_datanode_error.log | awk {'print $1'})
	C_ErrorLogSize=$(du -sh ${COLLECT_PATH}/logs/log_confignode_error.log | awk {'print $1'})
	if [ "${D_ErrorLogSize}" = "0" ] && [ "${C_ErrorLogSize}" = "0" ]; then
		ErrorLogSize=0
	else
		ErrorLogSize=1
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
	mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
	echo ${insert_sql}
}
backup_test_data() { # 备份测试数据
	sudo rm -rf ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
	sudo mkdir -p ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
    sudo rm -rf ${TEST_IOTDB_PATH}/data
	sudo mv ${TEST_IOTDB_PATH} ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
	sudo cp -rf ${BM_PATH}/data/csvOutput ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
}
clear_expired_file() { # 清理超过七天的文件
	find $1 -mtime +7 -type d -name "*" -exec rm -rf {} \;
}
test_operation() {
	protocol_class=$1
	ts_type=$2
	data_type=$3
	echo "开始测试${ts_type}时间序列！${data_type}"
	#清理环境，确保无就程序影响
	check_iotdb_pid
	#复制当前程序到执行位置
	set_env
	modify_iotdb_config
	#if [ "${protocol_class}" = "111" ]; then
	#	set_protocol_class 1 1 1
	#elif [ "${protocol_class}" = "222" ]; then
	#	set_protocol_class 2 2 2
	#elif [ "${protocol_class}" = "223" ]; then
	#	set_protocol_class 2 2 3
	#elif [ "${protocol_class}" = "211" ]; then
	#	set_protocol_class 2 1 1
	#else
	#	echo "协议设置错误！"
	#	return
	#fi
	#############################导入#############################
	#收集启动前基础监控数据
	cp -rf ${DATA_PATH}/data ${TEST_IOTDB_PATH}/
	collect_data_before ${TEST_IOTDB_PATH}/
	#启动iotdb
	start_iotdb
	sleep 10	
	monitor_test_status
	sleep 10
	stop_iotdb
	sleep 10
	check_iotdb_pid
	#收集启动后基础监控数据，并写入数据库
	collect_data_after ${TEST_IOTDB_PATH}
	insert_database restart_db
	#备份本次测试
}

##准备开始测试
echo "ontesting" > ${INIT_PATH}/test_type_file
query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${test_type} is NULL ORDER BY commit_date_time desc limit 1 "
result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${query_sql}")
commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
if [ "${commit_id}" = "" ]; then
	sleep 60s
else
	update_sql="update ${TASK_TABLENAME} set ${test_type} = 'ontesting' where commit_id = '${commit_id}'"
	result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}")
	echo "当前版本${commit_id}未执行过测试，即将编译后启动"
	init_items
	test_date_time=`date +%Y%m%d%H%M%S`
	p_index=$(($RANDOM % ${#protocol_list[*]}))
	t_index=$(($RANDOM % ${#ts_list[*]}))		
	test_operation 211 common sequence
	###############################测试完成###############################
	echo "本轮测试${test_date_time}已结束."
	update_sql="update ${TASK_TABLENAME} set ${test_type} = 'done' where commit_id = '${commit_id}'"
	result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}")
fi
echo "${test_type}" > ${INIT_PATH}/test_type_file