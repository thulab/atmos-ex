#!/usr/bin/env bash
#登录用户名
ACCOUNT=root
IoTDB_PW=TimechoDB@2021
test_type=os_jdk
#初始环境存放路径
INIT_PATH=/data/atmos/zk_test
ATMOS_PATH=${INIT_PATH}/atmos-ex
BM_PATH=${INIT_PATH}/iot-benchmark
JDK_PATH=${INIT_PATH}/jdk
BUCKUP_PATH=/nasdata/repository/os_jdk
REPOS_PATH=/nasdata/repository/master
#测试数据运行路径
TEST_INIT_PATH=/data/atmos/first-rest-test
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb
TEST_BM_PATH=${TEST_INIT_PATH}/iot-benchmark
# 1. org.apache.iotdb.consensus.simple.SimpleConsensus
# 2. org.apache.iotdb.consensus.ratis.RatisConsensus
# 3. org.apache.iotdb.consensus.iot.IoTConsensus
# 4. org.apache.iotdb.consensus.iot.IoTConsensusV2
protocol_class=(0 org.apache.iotdb.consensus.simple.SimpleConsensus org.apache.iotdb.consensus.ratis.RatisConsensus org.apache.iotdb.consensus.iot.IoTConsensus org.apache.iotdb.consensus.iot.IoTConsensusV2)
protocol_list=(223)
os_list=(ubuntu22 ubuntu24 centos7 centos8)
jdk_list=(OpenJDK17 OpenJDK21 TencentKona17 TencentKona21 DragonWell17 DragonWell21)
ts_list=(aligned tablemode)
IP_list=(0 172.20.70.37 172.20.70.28 172.20.70.39 172.20.70.41)
Control=172.20.70.38
############mysql信息##########################
MYSQLHOSTNAME="111.200.37.158" #数据库信息
PORT="13306"
USERNAME="iotdbatm"
PASSWORD=${ATMOS_DB_PASSWORD}
DBNAME="QA_ATM"  #数据库名称
TABLENAME="ex_os_jdk_T" #数据库中表的名称
TASK_TABLENAME="commit_history" #数据库中任务表的名称
############prometheus##########################
metric_server="111.200.37.158:19090"
############公用函数##########################
if [ "${PASSWORD}" = "" ]; then
	echo "需要关注密码设置！"
	exit 1
fi
#echo "Started at: " date -d today +"%Y-%m-%d %H:%M:%S"
echo "检查iot-benchmark版本"
BM_REPOS_PATH=/nasdata/repository/iot-benchmark
BM_NEW=$(grep git.commit.id.abbrev "${BM_REPOS_PATH}/git.properties" | awk -F= '{print $2}')
if [ ! -f "${BM_PATH}/git.properties" ]; then
	rm -rf "${BM_PATH}"
	cp -rf "${BM_REPOS_PATH}" "${BM_PATH}"
else
	BM_OLD=$(grep git.commit.id.abbrev "${BM_PATH}/git.properties" | awk -F= '{print $2}')
	if [ "${BM_OLD}" != "${BM_NEW}" ]; then
		rm -rf "${BM_PATH}"
		cp -rf "${BM_REPOS_PATH}" "${BM_PATH}"
	fi
fi
function init_items() {
    # 定义监控采集项初始值
    os_type=0; jdk_type=0; ts_type=0; okPoint=0; okOperation=0; failPoint=0; failOperation=0
    throughput=0; Latency=0; MIN=0; P10=0; P25=0; MEDIAN=0; P75=0; P90=0; P95=0; P99=0; P999=0; MAX=0
    numOfSe0Level=0; start_time=0; end_time=0; cost_time=0; numOfUnse0Level=0; dataFileSize=0
    maxNumofOpenFiles=0; maxNumofThread=0; errorLogSize=0; walFileSize=0; maxCPULoad=0; avgCPULoad=0
    maxDiskIOOpsRead=0; maxDiskIOOpsWrite=0; maxDiskIOSizeRead=0; maxDiskIOSizeWrite=0
}
local_ip=`ifconfig -a|grep inet|grep -v 127.0.0.1|grep -v inet6|awk '{print $2}'|tr -d "addr:"`
sendEmail() {
	"${TOOLS_PATH}/sendEmail.sh" "$1" >/dev/null 2>&1 &
}
check_benchmark_pid() { # 检查benchmark的pid，有就停止
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
	if [ ! -d "${TEST_INIT_PATH}" ]; then
		mkdir -p ${TEST_INIT_PATH}
		mkdir -p ${TEST_IOTDB_PATH}
	else
		rm -rf ${TEST_INIT_PATH}
		mkdir -p ${TEST_IOTDB_PATH}
	fi
	cp -rf ${REPOS_PATH}/${commit_id}/apache-iotdb/* ${TEST_IOTDB_PATH}/
	mkdir -p ${TEST_IOTDB_PATH}/activation
	cp -rf ${BM_PATH} ${TEST_INIT_PATH}/
}
modify_iotdb_config() { # iotdb调整内存，关闭合并
	JAVA_HOME_TEST=/data/atmos/jdk/$1
	#修改JDK的配置
	sed -i "s|^# export JAVA_HOME=.*$|export JAVA_HOME=${JAVA_HOME_TEST}|g" "${TEST_IOTDB_PATH}/conf/confignode-env.sh"
	sed -i "s|^# export JAVA_HOME=.*$|export JAVA_HOME=${JAVA_HOME_TEST}|g" "${TEST_IOTDB_PATH}/conf/datanode-env.sh"
	sed -i "s|^# export JAVA_HOME=.*$|export JAVA_HOME=${JAVA_HOME_TEST}|g" "${TEST_IOTDB_PATH}/sbin/start-cli.sh"
	#修改IoTDB的配置
	sed -i "s|^#ON_HEAP_MEMORY=\"2G\".*$|ON_HEAP_MEMORY=\"20G\"|g" "${TEST_IOTDB_PATH}/conf/datanode-env.sh"
	sed -i "s|^#ON_HEAP_MEMORY=\"2G\".*$|ON_HEAP_MEMORY=\"6G\"|g" "${TEST_IOTDB_PATH}/conf/confignode-env.sh"
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
set_protocol_class() { 
	config_node=$1
	schema_region=$2
	data_region=$3
	#设置协议
	echo "config_node_consensus_protocol_class=${protocol_class[${config_node}]}" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "schema_region_consensus_protocol_class=${protocol_class[${schema_region}]}" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "data_region_consensus_protocol_class=${protocol_class[${data_region}]}" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
}
setup_env() {
	echo "开始重置环境！"
	for (( j = 1; j < ${#IP_list[*]}; j++ ))
	do
		TEST_IP=${IP_list[$j]}
		ssh ${ACCOUNT}@${TEST_IP} "sudo reboot"
	done
	sleep 120
	for (( i = 1; i < ${#IP_list[*]}; i++ ))
	do
		echo "开始部署${IP_list[$i]}！"
		TEST_IP=${IP_list[$i]}
		echo "setting env to ${TEST_IP} ..."
		#删除原有路径下所有
		ssh ${ACCOUNT}@${TEST_IP} "rm -rf ${TEST_INIT_PATH}"
		ssh ${ACCOUNT}@${TEST_IP} "mkdir -p ${TEST_INIT_PATH}"
		#准备配置文件和license
		mv_config_file ${ts_type}
		rm -rf ${TEST_INIT_PATH}/apache-iotdb/activation
		mkdir -p ${TEST_INIT_PATH}/apache-iotdb/activation
		cp -rf ${ATMOS_PATH}/conf/${test_type}/license/${TEST_IP} ${TEST_INIT_PATH}/apache-iotdb/activation/license
		cp -rf ${ATMOS_PATH}/conf/${test_type}/env/${TEST_IP} ${TEST_INIT_PATH}/apache-iotdb/.env
		#复制三项到客户机
		scp -r ${TEST_INIT_PATH}/* ${ACCOUNT}@${TEST_IP}:${TEST_INIT_PATH}/
	done	
	sleep 3
	for (( i = 1; i < ${#IP_list[*]}; i++ ))
	do
		TEST_IP=${IP_list[$i]}
		#启动ConfigNode节点
		echo "starting IoTDB ConfigNode on ${TEST_IP} ..."
		pid3=$(ssh ${ACCOUNT}@${TEST_IP} "${TEST_IOTDB_PATH}/sbin/start-confignode.sh  > /dev/null 2>&1 &")
		sleep 5
		#启动DataNode节点
		echo "starting IoTDB DataNode on ${TEST_IP} ..."
		pid3=$(ssh ${ACCOUNT}@${TEST_IP} "${TEST_IOTDB_PATH}/sbin/start-datanode.sh -H ${TEST_IOTDB_PATH}/dn_dump.hprof   > /dev/null 2>&1 &")
		#等待10s，让服务器完成前期准备
		sleep 10
		flag=0
		for (( t_wait = 0; t_wait <= 50; t_wait++ ))
		do
		  str1=$(ssh ${ACCOUNT}@${TEST_IP} "${TEST_IOTDB_PATH}/sbin/start-cli.sh  -e \"show cluster\" | grep 'Total line number = 2'")
		  if [ "$str1" = "Total line number = 2" ]; then
			echo "All Nodes is ready"
			flag=1
			change_pwd=$(ssh ${ACCOUNT}@${TEST_IP} "${TEST_IOTDB_PATH}/sbin/start-cli.sh  -e \"ALTER USER root SET PASSWORD '${IoTDB_PW}';\"")
			break
		  else
			echo "All Nodes is not ready.Please wait ..."
			sleep 3
			continue
		  fi
		done
			if [ "$flag" = "0" ]; then
			  echo "All Nodes is not ready!"
			  exit 1
			fi
	done
}
monitor_test_status() { # 监控测试运行状态
	local active_nodes=$(( ${#IP_list[*]} - 1 ))
	while true; do
		now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
		t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
		flagBM=0
		for (( m = 1; m < ${#IP_list[*]}; m++ ))
		do
			if [ $t_time -ge 3600 ]; then
				echo "测试失败"  #倒序输入形成负数结果
				end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
				flagBM=-1
				cost_time=-1
				return 1
			fi
			str1=$(ssh ${ACCOUNT}@${IP_list[${m}]} "jps | grep -w App | grep -v grep | wc -l" 2>/dev/null)
			if [ "$str1" = "1" ]; then
				:
			else
				echo "BM写入已结束:${IP_list[${m}]}"
				flagBM=$((flagBM + 1))
			fi
		done
		if [ "$flagBM" -ge "$active_nodes" ]; then
			if [ "${ts_type}" = "tablemode" ]; then
				for (( ip = 1; ip < ${#IP_list[*]}; ip++ ))
				do
					fstr1=$(ssh ${ACCOUNT}@${IP_list[${ip}]} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -sql_dialect table  -e \"flush\"")
				done			
			else
				for (( ip = 1; ip < ${#IP_list[*]}; ip++ ))
				do
					fstr1=$(ssh ${ACCOUNT}@${IP_list[${ip}]} "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -e \"flush\"")
				done
			fi
			end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			cost_time=$(( $(date +%s) - m_start_time ))
			return 0
		elif [ "$flagBM" = "-1" ]; then
			break
		fi
		sleep 5
	done
}
function get_single_index() {
    # 获取 prometheus 单个指标的值
    local end=$2
    local url="http://${metric_server}/api/v1/query"
    index_value=$(curl -G -s "$url" --data-urlencode "query=$1" --data-urlencode "time=$end" | jq -r '.data.result[0].value[1] // empty')
	if [ "$index_value" = "null" ] || [ -z "$index_value" ]; then 
		index_value=0
	fi
	echo "${index_value}"
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
backup_test_data() { # 备份测试数据
	sudo rm -rf "${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class_input}"
	sudo mkdir -p "${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class_input}/"
	for (( j = 1; j < ${#IP_list[*]}; j++ ))
	do
		TEST_IP=${IP_list[$j]}
		sudo mkdir -p "${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class_input}/${TEST_IP}/"
		str1=$(ssh ${ACCOUNT}@${TEST_IP} "rm -rf ${TEST_IOTDB_PATH}/data" 2>/dev/null)
		scp -r ${ACCOUNT}@${TEST_IP}:${TEST_IOTDB_PATH}/ "${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class_input}/${TEST_IP}/"
	done
	sudo cp -rf "${TEST_BM_PATH}/TestResult/" "${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class_input}/"
}
mv_config_file() { # 移动配置文件
	rm -rf ${TEST_BM_PATH}/conf/config.properties
	cp -rf ${ATMOS_PATH}/conf/${test_type}/benchmark/$1 ${TEST_BM_PATH}/conf/config.properties
}
clear_expired_file() { # 清理超过七天的文件
	find $1 -mtime +7 -type d -name "*" -exec rm -rf {} \;
}
test_operation() {
	protocol_class_input=$1
	ts_type=$2
	jdk_type=$3
	echo "开始测试${ts_type}时间序列！"
	#复制当前程序到执行位置
	set_env
	#修改IoTDB的配置
	modify_iotdb_config "${jdk_type}"
	if [ "${protocol_class_input}" = "111" ]; then
		set_protocol_class 1 1 1
	elif [ "${protocol_class_input}" = "222" ]; then
		set_protocol_class 2 2 2
	elif [ "${protocol_class_input}" = "223" ]; then
		set_protocol_class 2 2 3
    elif [ "${protocol_class_input}" = "211" ]; then
        set_protocol_class 2 1 1
    elif [ "${protocol_class_input}" = "224" ]; then
        set_protocol_class 2 2 4
	else
		echo "协议设置错误！"
		return
	fi
	#启动iotdb
	setup_env
	sleep 60
	#启动写入程序
	for (( j = 1; j < ${#IP_list[*]}; j++ ))
	do
		TEST_IP=${IP_list[$j]}
		echo "开始写入！"
		pid3=$(ssh ${ACCOUNT}@${TEST_IP} "cd ${TEST_BM_PATH};${TEST_BM_PATH}/benchmark.sh > /dev/null 2>&1 &")
	done
	start_time=`date -d today +"%Y-%m-%d %H:%M:%S"`
	m_start_time=$(date +%s)
	#等待1分钟
	sleep 10
	#监控测试状态，直到所有BM结束
	monitor_test_status
	if [ "${cost_time}" = "-1" ]; then
		for (( i = 1; i < ${#IP_list[*]}; i++ ))
		do
			TEST_IP=${IP_list[$i]}
			ssh ${ACCOUNT}@${TEST_IP} "${TEST_IOTDB_PATH}/sbin/stop-standalone.sh" >/dev/null 2>&1
		done
		return 1
	fi
	#收集启动后基础监控数据
	m_end_time=$(date +%s)
	#测试结果收集写入数据库
	for (( j = 1; j < ${#IP_list[*]}; j++ ))
	do
		os_name=${os_list[$((j - 1))]}
		collect_monitor_data ${IP_list[${j}]}
		rm -rf ${TEST_BM_PATH}/TestResult/csvOutput/*
		mkdir -p ${TEST_BM_PATH}/TestResult/csvOutput/
		scp -r ${ACCOUNT}@${IP_list[${j}]}:${TEST_BM_PATH}/data/csvOutput/*result.csv ${TEST_BM_PATH}/TestResult/csvOutput/
		#收集启动后基础监控数据
		csvOutputfile=${TEST_BM_PATH}/TestResult/csvOutput/*result.csv
		if [ ! -f $csvOutputfile ]; then
			okOperation=0
			okPoint=0
			failOperation=0
			failPoint=0
			throughput=0
		else
			read okOperation okPoint failOperation failPoint throughput <<<$(cat ${csvOutputfile} | grep ^INGESTION | sed -n '1,1p' | awk -F, '{print $2,$3,$4,$5,$6}')
			read Latency MIN P10 P25 MEDIAN P75 P90 P95 P99 P999 MAX <<<$(cat ${csvOutputfile} | grep ^INGESTION | sed -n '2,2p' | awk -F, '{print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12}')
		fi
		insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,os_type,jdk_type,ts_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,walFileSize,avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${os_name}','${jdk_type}','${ts_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},${walFileSize},${avgCPULoad},${maxCPULoad},${maxDiskIOSizeRead},${maxDiskIOSizeWrite},${maxDiskIOOpsRead},${maxDiskIOOpsWrite},${protocol_class_input})"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
	done
	for (( i = 1; i < ${#IP_list[*]}; i++ ))
	do
		TEST_IP=${IP_list[$i]}
		str1=$(ssh ${ACCOUNT}@${TEST_IP} "${TEST_IOTDB_PATH}/sbin/stop-standalone.sh")
	done
	#备份本次测试
	backup_test_data "${ts_type}"
}
##准备开始测试
mkdir -p "${INIT_PATH}"
echo "ontesting" > "${INIT_PATH}/test_type_file"
query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${test_type} = 'retest' ORDER BY commit_date_time desc limit 1 "
result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${query_sql}")
commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
##查询是否有复测任务
if [ "${commit_id}" = "" ]; then
	query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${test_type} is NULL ORDER BY commit_date_time desc limit 1 "
	result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${query_sql}")
	commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
	author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
	commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
fi
if [ "${commit_id}" = "" ]; then
	sleep 60s
else
	update_sql="update ${TASK_TABLENAME} set ${test_type} = 'ontesting' where commit_id = '${commit_id}'"
	result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}")
    echo "当前版本${commit_id}未执行过测试，即将编译后启动"
    test_date_time=$(date +%Y%m%d%H%M%S)
    for protocol in ${protocol_list[@]}; do
        for jdk in ${jdk_list[@]}; do
			for ts in ${ts_list[@]}; do
				init_items
				echo "开始测试${protocol}协议下的${ts}时间序列在${jdk}环境下写入吞吐！"
				test_operation $protocol $ts $jdk
			done
        done
    done
	###############################测试完成###############################
	echo "本轮测试${test_date_time}已结束."
	update_sql="update ${TASK_TABLENAME} set ${test_type} = 'done' where commit_id = '${commit_id}'"
	result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}")
	update_sql02="update ${TASK_TABLENAME} set ${test_type} = 'skip' where ${test_type} is NULL and commit_date_time < '${commit_date_time}'"
	result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql02}")
fi
mkdir -p "${INIT_PATH}"
echo "${test_type}" > "${INIT_PATH}/test_type_file"
