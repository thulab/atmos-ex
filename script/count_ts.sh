#!/bin/sh
#登录用户名
ACCOUNT=atmos
test_type=count_ts
#初始环境存放路径
INIT_PATH=/data/atmos/zk_test
ATMOS_PATH=${INIT_PATH}/atmos-ex
BM_PATH=${INIT_PATH}/iot-benchmark
BUCKUP_PATH=/nasdata/repository/count_ts
REPOS_PATH=/nasdata/repository/master
#测试数据运行路径
TEST_INIT_PATH=/data/atmos
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb
# 1. org.apache.iotdb.consensus.simple.SimpleConsensus
# 2. org.apache.iotdb.consensus.ratis.RatisConsensus
# 3. org.apache.iotdb.consensus.iot.IoTConsensus
protocol_class=(0 org.apache.iotdb.consensus.simple.SimpleConsensus org.apache.iotdb.consensus.ratis.RatisConsensus org.apache.iotdb.consensus.iot.IoTConsensus)
protocol_list=(111 223 222 211)
ts_list=(common aligned template tempaligned)
############mysql信息##########################
MYSQLHOSTNAME="111.202.73.147" #数据库信息
PORT="13306"
USERNAME="iotdbatm"
PASSWORD="iotdb2019"
DBNAME="QA_ATM"  #数据库名称
TABLENAME="ex_count_ts" #数据库中表的名称
TASK_TABLENAME="ex_commit_history" #数据库中任务表的名称
############公用函数##########################
#echo "Started at: " date -d today +"%Y-%m-%d %H:%M:%S"
init_items() {
############定义监控采集项初始值##########################
test_date_time=0
start_time=0
end_time=0
cost_time=0
createCost_all=0
createCost_common=0
createCost_aligned=0
createCost_template=0
createCost_tempaligned=0
countCost_all=0
countCost_common=0
countCost_aligned=0
countCost_template=0
countCost_tempaligned=0
showCost_all=0
showCost_common=0
showCost_aligned=0
showCost_template=0
showCost_tempaligned=0
numOfSe0Level=0
numOfUnse0Level=0
dataFileSize=0
maxNumofOpenFiles=0
maxNumofThread=0
errorLogSize=0
############定义监控采集项初始值##########################
}
local_ip=`ifconfig -a|grep inet|grep -v 127.0.0.1|grep -v inet6|awk '{print $2}'|tr -d "addr:"`
sendEmail() {
sendEmail=$(${TOOLS_PATH}/sendEmail.sh $1 >/dev/null 2>&1 &)
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
	sed -i "s/^#MAX_HEAP_SIZE=\"2G\".*$/MAX_HEAP_SIZE=\"6G\"/g" ${TEST_IOTDB_PATH}/conf/confignode-env.sh
	#设置元数据管理方式
	sed -i "s/^# schema_engine_mode=.*$/schema_engine_mode=PBTree/g" ${TEST_IOTDB_PATH}/conf/iotdb-common.properties
	#关闭影响写入性能的其他功能
	sed -i "s/^# enable_seq_space_compaction=true.*$/enable_seq_space_compaction=false/g" ${TEST_IOTDB_PATH}/conf/iotdb-common.properties
	sed -i "s/^# enable_unseq_space_compaction=true.*$/enable_unseq_space_compaction=false/g" ${TEST_IOTDB_PATH}/conf/iotdb-common.properties
	sed -i "s/^# enable_cross_space_compaction=true.*$/enable_cross_space_compaction=false/g" ${TEST_IOTDB_PATH}/conf/iotdb-common.properties
	#修改集群名称
	sed -i "s/^cluster_name=.*$/cluster_name=${test_type}/g" ${TEST_IOTDB_PATH}/conf/iotdb-common.properties
	sed -i "s/^cluster_name=.*$/cluster_name=${test_type}/g" ${TEST_IOTDB_PATH}/conf/iotdb-common.properties
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
	maxNumofOpenFiles=0
	maxNumofThread=0
	while true; do
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

		csvOutput=${BM_PATH}/data/csvOutput
		if [ ! -d "$csvOutput" ]; then
			now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
			if [ $t_time -ge 7200 ]; then
				echo "测试失败"
				mkdir -p ${BM_PATH}/data/csvOutput
				cd ${BM_PATH}/data/csvOutput
				touch Stuck_result.csv
				array1="INGESTION ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1"
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
			echo "写入已完成！"
			break
		fi
	done
}
collect_monitor_data() { # 收集iotdb数据大小，顺、乱序文件数量
	dataFileSize=$(du -h -d0 ${TEST_IOTDB_PATH}/data | awk {'print $1'} | awk '{sub(/.$/,"")}1')
	UNIT=$(du -h -d0 ${TEST_IOTDB_PATH}/data | awk {'print $1'} | awk -F '' '$0=$NF')
	if [ "$UNIT" = "M" ]; then
		dataFileSize=`awk 'BEGIN{printf "%.2f\n",'$dataFileSize'/'1024'}'`
	elif [ "$UNIT" = "K" ]; then
		dataFileSize=`awk 'BEGIN{printf "%.2f\n",'$dataFileSize'/'1048576'}'`
	elif [ "$UNIT" = "T" ]; then
        dataFileSize=`awk 'BEGIN{printf "%.2f\n",'$dataFileSize'*'1024'}'`
	else
		dataFileSize=${dataFileSize}
	fi
	numOfSe0Level=$(find ${TEST_IOTDB_PATH}/data/datanode/data/sequence -name "*.tsfile" | wc -l)
	if [ ! -d "${TEST_IOTDB_PATH}/data/datanode/data/unsequence" ]; then
		numOfUnse0Level=0
	else
		numOfUnse0Level=$(find ${TEST_IOTDB_PATH}/data/datanode/data/unsequence -name "*.tsfile" | wc -l)
	fi
	D_errorLogSize=$(du -sh ${TEST_IOTDB_PATH}/logs/log_datanode_error.log | awk {'print $1'})
	C_errorLogSize=$(du -sh ${TEST_IOTDB_PATH}/logs/log_confignode_error.log | awk {'print $1'})
	if [ "${D_errorLogSize}" = "0" ] && [ "${C_errorLogSize}" = "0" ]; then
		errorLogSize=0
	else
		errorLogSize=1
	fi
}
backup_test_data() { # 备份测试数据
	sudo mkdir -p ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
    sudo rm -rf ${TEST_IOTDB_PATH}/data
	sudo mv ${TEST_IOTDB_PATH} ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
	sudo cp -rf ${BM_PATH}/data/csvOutput ${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
}
mv_config_file() { # 移动配置文件
	rm -rf ${BM_PATH}/conf/config.properties
	cp -rf ${ATMOS_PATH}/conf/${test_type}/$1 ${BM_PATH}/conf/config.properties
}
clear_expired_file() { # 清理超过七天的文件
	find $1 -mtime +7 -type d -name "*" -exec rm -rf {} \;
}
test_operation() {
	protocol_class=$1
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
	#启动iotdb和monitor监控
	start_iotdb
	start_time=`date -d today +"%Y-%m-%d %H:%M:%S"`
	sleep 10
	####判断IoTDB是否正常启动
	for (( t_wait = 0; t_wait <= 100; t_wait++ ))
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
		insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,start_time,end_time,cost_time,createCost_all,createCost_common,createCost_aligned,createCost_template,createCost_tempaligned,countCost_all,countCost_common,countCost_aligned,countCost_template,countCost_tempaligned,showCost_all,showCost_common,showCost_aligned,showCost_template,showCost_tempaligned,numOfSe0Level,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,remark)	values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${start_time}','${end_time}',${cost_time},${createCost_all},${createCost_common},${createCost_aligned},${createCost_template},${createCost_tempaligned},${countCost_all},${countCost_common},${countCost_aligned},${countCost_template},${countCost_tempaligned},${showCost_all},${showCost_common},${showCost_aligned},${showCost_template},${showCost_tempaligned},${numOfSe0Level},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},${protocol_class})"
		mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
		update_sql="update ${TASK_TABLENAME} set ${test_type} = 'RError' where commit_id = '${commit_id}'"
		result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}")
		return
	fi
	#收集启动后默认状态线程数量
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
	maxNumofOpenFiles_init=${temp_file_num}
	let temp_thread_num=${temp_thread_num_d}+${temp_thread_num_c}+${temp_thread_num_i}
	maxNumofThread_init=${temp_thread_num}
	#启动写入程序
	schemaCost=(0 0 0 0)
	for (( j = 0; j < ${#ts_list[*]}; j++ ))
	do
		mv_config_file ${ts_list[${j}]}
		echo "开始创建${ts_list[${j}]}时间序列！"
		start_benchmark
		#等待1分钟
		sleep 60
		monitor_test_status
		#测试结果收集写入数据库
		csvOutputfile=${BM_PATH}/data/csvOutput/*result.csv
		read schemaCost[${j}] <<<$(cat ${csvOutputfile} | grep ^Schema | sed -n '1,1p' | awk -F, '{print $2}')
	done
	createCost_common=${schemaCost[0]}
	createCost_aligned=${schemaCost[1]}
	createCost_template=${schemaCost[2]}
	createCost_tempaligned=${schemaCost[3]}
	#刷一下准备开始采集
	pid=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -h 127.0.0.1 -p 6667 -u root -pw root -e "flush")
	#统计总体时间序列耗时
	rm -rf ${TEST_IOTDB_PATH}/out.log
	echo "开始测试统计全部时间序列耗时！"
	pid=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -h 127.0.0.1 -p 6667 -u root -pw root -timeout 6000 -e "count timeseries root.**" >> ${TEST_IOTDB_PATH}/out.log)
	read countCost_all <<<$(cat ${TEST_IOTDB_PATH}/out.log | grep ^It | sed -n '1,1p' | awk 'gsub("s","")' | awk '{print $3}')
	#统计common时间序列耗时
	rm -rf ${TEST_IOTDB_PATH}/out.log
	echo "开始测试统计普通时间序列耗时！"
	pid=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -h 127.0.0.1 -p 6667 -u root -pw root -timeout 6000 -e "count timeseries root.test_common_0.**" >> ${TEST_IOTDB_PATH}/out.log)
	read countCost_common <<<$(cat ${TEST_IOTDB_PATH}/out.log | grep ^It | sed -n '1,1p' | awk 'gsub("s","")' | awk '{print $3}')
	#统计aligned时间序列耗时
	rm -rf ${TEST_IOTDB_PATH}/out.log
	echo "开始测试统计对齐时间序列耗时！"
	pid=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -h 127.0.0.1 -p 6667 -u root -pw root -timeout 6000 -e "count timeseries root.test_aligned_0.**" >> ${TEST_IOTDB_PATH}/out.log)
	read countCost_aligned <<<$(cat ${TEST_IOTDB_PATH}/out.log | grep ^It | sed -n '1,1p' | awk 'gsub("s","")' | awk '{print $3}')
	#统计template时间序列耗时
	rm -rf ${TEST_IOTDB_PATH}/out.log
	echo "开始测试统计模板时间序列耗时！"
	pid=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -h 127.0.0.1 -p 6667 -u root -pw root -timeout 6000 -e "count timeseries root.test_temp_0.**" >> ${TEST_IOTDB_PATH}/out.log)
	read countCost_template <<<$(cat ${TEST_IOTDB_PATH}/out.log | grep ^It | sed -n '1,1p' | awk 'gsub("s","")' | awk '{print $3}')
	#统计tempaligned时间序列耗时
	rm -rf ${TEST_IOTDB_PATH}/out.log
	echo "开始测试统计对齐模板时间序列耗时！"
	pid=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -h 127.0.0.1 -p 6667 -u root -pw root -timeout 6000 -e "count timeseries root.test_tempaligned_0.**" >> ${TEST_IOTDB_PATH}/out.log)
	read countCost_tempaligned <<<$(cat ${TEST_IOTDB_PATH}/out.log | grep ^It | sed -n '1,1p' | awk 'gsub("s","")' | awk '{print $3}')
	
	#统计查询总体时间序列耗时
	rm -rf ${TEST_IOTDB_PATH}/out.log
	echo "开始测试查询全部时间序列耗时！"
	pid=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -h 127.0.0.1 -p 6667 -u root -pw root -timeout 6000 -e "show timeseries root.**" >> ${TEST_IOTDB_PATH}/out.log)
	read showCost_all <<<$(cat ${TEST_IOTDB_PATH}/out.log | grep ^It | sed -n '1,1p' | awk 'gsub("s","")' | awk '{print $3}')
	#统计查询common时间序列耗时
	rm -rf ${TEST_IOTDB_PATH}/out.log
	echo "开始测试查询普通时间序列耗时！"
	pid=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -h 127.0.0.1 -p 6667 -u root -pw root -timeout 6000 -e "show timeseries root.test_common_0.**" >> ${TEST_IOTDB_PATH}/out.log)
	read showCost_common <<<$(cat ${TEST_IOTDB_PATH}/out.log | grep ^It | sed -n '1,1p' | awk 'gsub("s","")' | awk '{print $3}')
	#统计查询aligned时间序列耗时
	rm -rf ${TEST_IOTDB_PATH}/out.log
	echo "开始测试查询对齐时间序列耗时！"
	pid=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -h 127.0.0.1 -p 6667 -u root -pw root -timeout 6000 -e "show timeseries root.test_aligned_0.**" >> ${TEST_IOTDB_PATH}/out.log)
	read showCost_aligned <<<$(cat ${TEST_IOTDB_PATH}/out.log | grep ^It | sed -n '1,1p' | awk 'gsub("s","")' | awk '{print $3}')
	#统计查询template时间序列耗时
	rm -rf ${TEST_IOTDB_PATH}/out.log
	echo "开始测试查询模板时间序列耗时！"
	pid=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -h 127.0.0.1 -p 6667 -u root -pw root -timeout 6000 -e "show timeseries root.test_temp_0.**" >> ${TEST_IOTDB_PATH}/out.log)
	read showCost_template <<<$(cat ${TEST_IOTDB_PATH}/out.log | grep ^It | sed -n '1,1p' | awk 'gsub("s","")' | awk '{print $3}')
	#统计查询tempaligned时间序列耗时
	rm -rf ${TEST_IOTDB_PATH}/out.log
	echo "开始测试查询对齐模板时间序列耗时！"
	pid=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -h 127.0.0.1 -p 6667 -u root -pw root -timeout 6000 -e "show timeseries root.test_tempaligned_0.**" >> ${TEST_IOTDB_PATH}/out.log)
	read showCost_tempaligned <<<$(cat ${TEST_IOTDB_PATH}/out.log | grep ^It | sed -n '1,1p' | awk 'gsub("s","")' | awk '{print $3}')
	
	#停止IoTDB程序和监控程序
	stop_iotdb
	sleep 30
	check_benchmark_pid
	check_iotdb_pid
	end_time=`date -d today +"%Y-%m-%d %H:%M:%S"`
	cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
	insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,start_time,end_time,cost_time,createCost_all,createCost_common,createCost_aligned,createCost_template,createCost_tempaligned,countCost_all,countCost_common,countCost_aligned,countCost_template,countCost_tempaligned,showCost_all,showCost_common,showCost_aligned,showCost_template,showCost_tempaligned,numOfSe0Level,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,remark)	values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${start_time}','${end_time}',${cost_time},${createCost_all},${createCost_common},${createCost_aligned},${createCost_template},${createCost_tempaligned},${countCost_all},${countCost_common},${countCost_aligned},${countCost_template},${countCost_tempaligned},${showCost_all},${showCost_common},${showCost_aligned},${showCost_template},${showCost_tempaligned},${numOfSe0Level},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},${protocol_class})"
	mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${insert_sql}"
	echo "${insert_sql}"
	#备份本次测试
	#backup_test_data ${ts_type}
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
	#echo "开始测试${protocol_list[$p_index]}协议下的${ts_list[$t_index]}时间序列！"
	#test_operation ${protocol_list[$p_index]} ${ts_list[$t_index]}
	###############################SESSION_BY_TABLET###############################
	echo "开始测试时间序列的创建和查询耗时！"
	test_operation 223
	###############################测试完成###############################
	echo "本轮测试${test_date_time}已结束."
	update_sql="update ${TASK_TABLENAME} set ${test_type} = 'done' where commit_id = '${commit_id}'"
	result_string=$(mysql -h${MYSQLHOSTNAME} -P${PORT} -u${USERNAME} -p${PASSWORD} ${DBNAME} -e "${update_sql}")
fi
echo "${test_type}" > ${INIT_PATH}/test_type_file