#!/bin/sh
#登录用户名
TEST_IP="11.101.17.223"
ACCOUNT=atmos
test_type=unse_query
#初始环境存放路径
INIT_PATH=/data/atmos/zk_test
ATMOS_PATH=${INIT_PATH}/atmos-ex
BM_PATH=${INIT_PATH}/iot-benchmark
DATA_PATH=/data/atmos/DataSet
BUCKUP_PATH=/nasdata/repository/unse_query
REPOS_PATH=/nasdata/repository/master
#测试数据运行路径
TEST_INIT_PATH=/data/atmos
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb
# 1. org.apache.iotdb.consensus.simple.SimpleConsensus
# 2. org.apache.iotdb.consensus.ratis.RatisConsensus
# 3. org.apache.iotdb.consensus.iot.IoTConsensus
protocol_class=(0 org.apache.iotdb.consensus.simple.SimpleConsensus org.apache.iotdb.consensus.ratis.RatisConsensus org.apache.iotdb.consensus.iot.IoTConsensus)
protocol_list=(111 223 222 211)
ts_list=(tablemode common aligned tempaligned)
############mysql信息##########################
MYSQLHOSTNAME="111.200.37.158" #数据库信息
PORT="13306"
USERNAME="iotdbatm"
PASSWORD=${ATMOS_DB_PASSWORD}
DBNAME="QA_ATM"  #数据库名称
TABLENAME="ex_unse_query" #数据库中表的名称
TASK_TABLENAME="ex_commit_history" #数据库中任务表的名称
############prometheus##########################
metric_server="111.200.37.158:19090"
#query_data_type=(common)
query_data_type=(tablemode common aligned tempaligned)
query_list=(Q1 Q2-1 Q2-2 Q2-3 Q3-1 Q3-2 Q3-3 Q4a-1 Q4a-2 Q4a-3 Q4b-1 Q4b-2 Q4b-3 Q5 Q6-1 Q6-2 Q6-3 Q7-1 Q7-2 Q7-3 Q8 Q9-1 Q9-2 Q9-3 Q10)
query_type_csv=(PRECISE_POINT, TIME_RANGE, TIME_RANGE, TIME_RANGE, VALUE_RANGE, VALUE_RANGE, VALUE_RANGE, AGG_RANGE, AGG_RANGE, AGG_RANGE, AGG_RANGE, AGG_RANGE, AGG_RANGE, AGG_VALUE, AGG_RANGE_VALUE, AGG_RANGE_VALUE, AGG_RANGE_VALUE, GROUP_BY, GROUP_BY, GROUP_BY, LATEST_POINT, RANGE_QUERY_DESC, RANGE_QUERY_DESC, RANGE_QUERY_DESC, VALUE_RANGE_QUERY_DESC)
############公用函数##########################
if [ "${PASSWORD}" = "" ]; then
echo "需要关注密码设置！"
fi
#echo "Started at: " date -d today +"%Y-%m-%d %H:%M:%S"
echo "检查iot-benchmark版本"
BM_REPOS_PATH=/nasdata/repository/iot-benchmark
BM_NEW=$(cat ${BM_REPOS_PATH}/git.properties | grep git.commit.id.abbrev | awk -F= '{print $2}')
BM_OLD=$(cat ${BM_PATH}/git.properties | grep git.commit.id.abbrev | awk -F= '{print $2}')
if [ "${BM_OLD}" != "cat: git.properties: No such file or directory" ] && [ "${BM_OLD}" != "${BM_NEW}" ]; then
	rm -rf ${BM_PATH}
	cp -rf ${BM_REPOS_PATH} ${BM_PATH}
fi
init_items() {
############定义监控采集项初始值##########################
test_date_time=0
ts_type=0
data_type=0
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
	mkdir -p ${TEST_IOTDB_PATH}/activation
	cp -rf ${ATMOS_PATH}/conf/${test_type}/license ${TEST_IOTDB_PATH}/activation/
}
modify_iotdb_config() { # iotdb调整内存，关闭合并
	#修改IoTDB的配置
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"20G\"/g" ${TEST_IOTDB_PATH}/conf/datanode-env.sh
	#清空配置文件
	# echo "只保留要修改的参数" > ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "series_slot_num=10000" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
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
	#启动IoTDB之前清理系统缓存
	echo 3 > /proc/sys/vm/drop_caches
	cd ${TEST_IOTDB_PATH}
	conf_start=$(./sbin/start-confignode.sh >/dev/null 2>&1 &)
	sleep 10
	data_start=$(./sbin/start-datanode.sh -H ${TEST_IOTDB_PATH}/dn_dump.hprof >/dev/null 2>&1 &)
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
				array1="PRECISE_POINT ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1"
				for ((i=0;i<100;i++))
				do
					echo $array1 >> Stuck_result.csv
				done
				cd ~
				break
			fi
			continue
		else
			end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			echo "${query_type}查询已完成！"
			break
		fi
	done
}
function get_single_index() {
    # 获取 prometheus 单个指标的值
    local end=$2
    local url="http://${metric_server}/api/v1/query"
    local data_param="--data-urlencode query=$1 --data-urlencode 'time=${end}'"
    index_value=$(curl -G -s $url ${data_param} | jq '.data.result[0].value[1]'| tr -d '"')
	if [[ "$index_value" == "null" || -z "$index_value" ]]; then 
		index_value=0
	fi
	echo ${index_value}
}
collect_monitor_data() { # 收集iotdb数据大小，顺、乱序文件数量
	#TEST_IP=$1
	dataFileSize=0
	walFileSize=0
	numOfSe0Level=0
	numOfUnse0Level=0
	maxNumofOpenFiles=0
	maxNumofThread_C=0
	maxNumofThread_D=0
	maxNumofThread=0
	#调用监控获取数值
	dataFileSize=$(get_single_index "sum(file_global_size{instance=~\"${TEST_IP}:9091\"})" $m_end_time)
	dataFileSize=`awk 'BEGIN{printf "%.2f\n",'$dataFileSize'/'1048576'}'`
	dataFileSize=`awk 'BEGIN{printf "%.2f\n",'$dataFileSize'/'1024'}'`
	numOfSe0Level=$(get_single_index "sum(file_global_count{instance=~\"${TEST_IP}:9091\",name=\"seq\"})" $m_end_time)
	numOfUnse0Level=$(get_single_index "sum(file_global_count{instance=~\"${TEST_IP}:9091\",name=\"unseq\"})" $m_end_time)
	maxNumofThread_C=$(get_single_index "max_over_time(process_threads_count{instance=~\"${TEST_IP}:9081\"}[$((m_end_time-m_start_time))s])" $m_end_time)
	maxNumofThread_D=$(get_single_index "max_over_time(process_threads_count{instance=~\"${TEST_IP}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
	let maxNumofThread=${maxNumofThread_C}+${maxNumofThread_D}
	maxNumofOpenFiles=$(get_single_index "max_over_time(file_count{instance=~\"${TEST_IP}:9091\",name=\"open_file_handlers\"}[$((m_end_time-m_start_time))s])" $m_end_time)
	walFileSize=$(get_single_index "max_over_time(file_size{instance=~\"${TEST_IP}:9091\",name=~\"wal\"}[$((m_end_time-m_start_time))s])" $m_end_time)
	walFileSize=`awk 'BEGIN{printf "%.2f\n",'$walFileSize'/'1048576'}'`
	walFileSize=`awk 'BEGIN{printf "%.2f\n",'$walFileSize'/'1024'}'`
}
backup_test_data() { # 备份测试数据
	sudo rm -rf ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}
	sudo mkdir -p ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}
	sudo rm -rf ${TEST_IOTDB_PATH}/data
	sudo mv ${TEST_IOTDB_PATH} ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}
	sudo cp -rf ${BM_PATH}/data/csvOutput ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}
}
mv_config_file() { # 移动配置文件
	rm -rf ${BM_PATH}/conf/config.properties
	cp -rf ${ATMOS_PATH}/conf/${test_type}/$1/$2 ${BM_PATH}/conf/config.properties
}
test_operation() {
	protocol_class=$1
	data_type=sequence
	#查询测试	
	for (( j = 0; j < ${#query_data_type[*]}; j++ ))
	do
		ts_type=${query_data_type[${j}]}
		echo "开始${ts_type}时间序列相关查询！"
		#清理环境，确保无就程序影响
		check_benchmark_pid
		check_iotdb_pid
		#复制当前程序到执行位置
		set_env
		#修改IoTDB的配置
		modify_iotdb_config
		if [ "${protocol_class}" = "111" ]; then
			set_protocol_class 1 1 1
		elif [ "${protocol_class}" = "222" ]; then
			set_protocol_class 2 2 2
		elif [ "${protocol_class}" = "223" ]; then
			set_protocol_class 2 2 3
		elif [ "${protocol_class}" = "211" ]; then
			set_protocol_class 2 1 1
		else
			echo "协议设置错误！"
			return
		fi
		mv ${DATA_PATH}/${protocol_class}/${ts_type}/data ${TEST_IOTDB_PATH}/
		#cp -rf ${DATA_PATH}/${protocol_class}/${ts_type}/data ${TEST_IOTDB_PATH}/
		sleep 10
		for (( i = 0; i < ${#query_list[*]}; i++ ))
		do
			query_type=${query_list[${i}]}
			echo "开始${query_type}查询！"
			check_iotdb_pid
			sleep 1
			start_iotdb
			#start_monitor
			sleep 10
			####判断IoTDB是否正常启动
			for (( t_wait = 0; t_wait <= 20; t_wait++ ))
			do
			  iotdb_state=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -e "show cluster" | grep 'Total line number = 2')
			  if [ "${iotdb_state}" = "Total line number = 2" ]; then
				break
			  else
				sleep 30
				continue
			  fi
			done			
			if [ "${iotdb_state}" = "Total line number = 2" ]; then
				echo "IoTDB正常启动，准备开始测试"
			else
				echo "IoTDB未能正常启动，写入负值测试结果！"
				cost_time=-3
				throughput=-3
				insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,ts_type,data_type,query_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}','${data_type}','${query_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},'${protocol_class}')"
				mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
				update_sql="update ${TASK_TABLENAME} set ${test_type} = 'RError' where commit_id = '${commit_id}'"
				result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}")
				continue
			fi
			
			#启动写入程序
			mv_config_file ${ts_type} ${query_list[${i}]}
			# IoTDB-2.0 表模型支持 需要修改测试数据模型
			if [ "${ts_type}" = "tablemode" ]; then 
				echo "IoTDB_DIALECT_MODE=table" >> ${BM_PATH}/conf/config.properties
				# IoTDB-2.0 表模型支持 Q1 Q2 Q3 Q9 Q10
				# query_list=(Q1 Q2-1 Q2-2 Q2-3 Q3-1 Q3-2 Q3-3 Q4a-1 Q4a-2 Q4a-3 Q4b-1 Q4b-2 Q4b-3 Q5 Q6-1 Q6-2 Q6-3 Q7-1 Q7-2 Q7-3 Q8 Q9-1 Q9-2 Q9-3 Q10)
				# table_query_list=(Q1 Q2-1 Q2-2 Q2-3 Q3-1 Q3-2 Q3-3 Q9-1 Q9-2 Q9-3 Q10)
				# if [[ " ${table_query_list[@]} " =~ " ${query_list[${i}]} " ]]; then
				# 	echo "目前支持 ${query_list[${i}]} 查询"
				# else
				# 	echo "目前不支持 ${query_list[${i}]} 查询，将要跳过。"
				# 	continue
				# fi
			fi
			sleep 3

			start_benchmark
			start_time=`date -d today +"%Y-%m-%d %H:%M:%S"`
			m_start_time=$(date +%s)
			#等待1分钟
			sleep 2
			
			monitor_test_status
			m_end_time=$(date +%s)			
			#收集启动后基础监控数据
			collect_monitor_data
			#测试结果收集写入数据库
			csvOutputfile=${BM_PATH}/data/csvOutput/*result.csv
			read okOperation okPoint failOperation failPoint throughput <<<$(cat ${csvOutputfile} | grep ^${query_type_csv[${i}]} | sed -n '1,1p' | awk -F, '{print $2,$3,$4,$5,$6}')
			read Latency MIN P10 P25 MEDIAN P75 P90 P95 P99 P999 MAX <<<$(cat ${csvOutputfile} | grep ^${query_type_csv[${i}]} | sed -n '2,2p' | awk -F, '{print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12}')

			cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
			insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,ts_type,data_type,query_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}','${data_type}','${query_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},'${protocol_class}')"
			mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
			echo ${commit_id}版本${ts_type}时间序列${data_type}查询${okPoint}数据点的${query_type}耗时为：${Latency}ms
			#备份本次测试
			cp -rf ${BM_PATH}/data/csvOutput ${TEST_IOTDB_PATH}/logs/ 
			mv ${TEST_IOTDB_PATH}/logs ${TEST_IOTDB_PATH}/logs_${query_list[${i}]}
			#停止IoTDB程序和监控程序
			stop_iotdb
			sleep 30
			check_benchmark_pid
			check_iotdb_pid
			sleep 5
		done
		echo "${ts_type}时间序列查询测试已结束."
		mv ${TEST_IOTDB_PATH}/data ${DATA_PATH}/${protocol_class}/${ts_type}/ 
		#rm -rf ${TEST_IOTDB_PATH}/data
		#备份本次测试
		backup_test_data ${ts_type}
	done
}

##准备开始测试
echo "ontesting" > ${INIT_PATH}/test_type_file
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
	echo "当前版本${commit_id}未执行过测试，即将启动"
	init_items
	test_date_time=`date +%Y%m%d%H%M%S`
	echo "开始测试！"
	test_operation 211
	###############################测试完成###############################
	echo "本轮测试${test_date_time}已结束."
	update_sql="update ${TASK_TABLENAME} set ${test_type} = 'done' where commit_id = '${commit_id}'"
	result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}")
	update_sql02="update ${TASK_TABLENAME} set ${test_type} = 'skip' where ${test_type} is NULL and commit_date_time < '${commit_date_time}'"
	result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql02}")
fi
echo "${test_type}" > ${INIT_PATH}/test_type_file