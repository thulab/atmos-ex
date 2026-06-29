#!/usr/bin/env bash
#登录用户名
TEST_IP="11.101.17.141"
ACCOUNT=atmos
IoTDB_PW=TimechoDB@2021
test_type=last_cache_query
#初始环境存放路径
INIT_PATH=/data/atmos/zk_test
ATMOS_PATH=${INIT_PATH}/atmos-ex
BM_PATH=${INIT_PATH}/query-benchmark
Background_PATH=${INIT_PATH}/iot-benchmark
BUCKUP_PATH=/nasdata/repository/last_cache_query
REPOS_PATH=/nasdata/repository/master
#测试数据运行路径
TEST_INIT_PATH=/data/atmos
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb
# 1. org.apache.iotdb.consensus.simple.SimpleConsensus
# 2. org.apache.iotdb.consensus.ratis.RatisConsensus
# 3. org.apache.iotdb.consensus.iot.IoTConsensus
protocol_class=(0 org.apache.iotdb.consensus.simple.SimpleConsensus org.apache.iotdb.consensus.ratis.RatisConsensus org.apache.iotdb.consensus.iot.IoTConsensus)
protocol_list=(223)
ts_list=(common aligned tablemode)
ts_list_bk=(common aligned template tempaligned)
############mysql信息##########################
MYSQLHOSTNAME="111.200.37.158" #数据库信息
PORT="13306"
USERNAME="iotdbatm"
PASSWORD=${ATMOS_DB_PASSWORD}
DBNAME="QA_ATM"  #数据库名称
TABLENAME="ex_last_cache_query" #数据库中表的名称
TABLENAME_T="ex_last_cache_query_T" #企业版结果表
TASK_TABLENAME="ex_commit_history" #数据库中任务表的名称
############prometheus##########################
metric_server="111.200.37.158:19090"
############公用函数##########################
check_password() {
	if [ -z "${PASSWORD}" ]; then
		echo "需要关注密码设置！"
	fi
}

run_mysql() {
	mysql -h"${MYSQLHOSTNAME}" -P"${PORT}" -u"${USERNAME}" -p"${PASSWORD}" "${DBNAME}" -e "$1"
}

git_commit_abbrev() {
	awk -F= '/git.commit.id.abbrev/ {print $2; exit}' "$1" 2>/dev/null
}

format_gb() {
	awk -v value="$1" 'BEGIN{printf "%.2f\n", value / 1048576 / 1024}'
}

run_iotdb_cli() {
	"${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw "${IoTDB_PW}" -h 127.0.0.1 -p 6667 "$@"
}

parse_benchmark_result() {
	local result_label=$1
	local csv_file
	csv_file=$(find "${BM_PATH}/data/csvOutput" -name "*result.csv" -print -quit 2>/dev/null)
	if [ -z "${csv_file}" ]; then
		return 1
	fi

	read okOperation okPoint failOperation failPoint throughput <<<"$(awk -F, -v label="${result_label}" '$1 ~ "^" label {print $2,$3,$4,$5,$6; exit}' "${csv_file}")"
	read Latency MIN P10 P25 MEDIAN P75 P90 P95 P99 P999 MAX <<<"$(awk -F, -v label="${result_label}" '$1 ~ "^" label {count++; if (count == 2) {print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12; exit}}' "${csv_file}")"
}

sync_benchmark_path() {
	local target_path=$1
	local target_version
	local source_version

	source_version=$(git_commit_abbrev "${BM_REPOS_PATH}/git.properties")
	target_version=$(git_commit_abbrev "${target_path}/git.properties")
	if [ -n "${source_version}" ] && [ "${target_version}" != "${source_version}" ]; then
		rm -rf "${target_path}"
		cp -rf "${BM_REPOS_PATH}" "${target_path}"
	fi
}

check_benchmark_version() {
	echo "检查iot-benchmark版本"
	BM_REPOS_PATH=/nasdata/repository/iot-benchmark
	sync_benchmark_path "${BM_PATH}"
	sync_benchmark_path "${Background_PATH}"
}

check_password
check_benchmark_version
init_items() {
############定义监控采集项初始值##########################
test_date_time=0
ts_type=0
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
local_ip=$(ifconfig -a 2>/dev/null | grep inet | grep -v 127.0.0.1 | grep -v inet6 | awk '{print $2}' | tr -d "addr:")
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
	if [ ! -d "${TEST_IOTDB_PATH}" ]; then
		mkdir -p "${TEST_IOTDB_PATH}"
	else
		rm -rf "${TEST_IOTDB_PATH}"
		mkdir -p "${TEST_IOTDB_PATH}"
	fi
	cp -rf "${REPOS_PATH}/${commit_id}/apache-iotdb/"* "${TEST_IOTDB_PATH}/"
	mkdir -p "${TEST_IOTDB_PATH}/activation"
	cp -rf "${ATMOS_PATH}/conf/${test_type}/license" "${TEST_IOTDB_PATH}/activation/"
}
modify_iotdb_config() { # iotdb调整内存，关闭合并
	#修改IoTDB的配置
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"20G\"/g" "${TEST_IOTDB_PATH}/conf/datanode-env.sh"
	#清空配置文件
	#echo "只保留要修改的参数" > ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	echo "enable_last_cache=true" >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	#关闭影响写入性能的其他功能
	echo "enable_seq_space_compaction=false" >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	echo "enable_unseq_space_compaction=false" >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	echo "enable_cross_space_compaction=false" >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	#修改集群名称
	echo "cluster_name=${test_type}" >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	#添加启动监控功能
	echo "cn_enable_metric=true" >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	echo "cn_enable_performance_stat=true" >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	echo "cn_metric_reporter_list=PROMETHEUS" >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	echo "cn_metric_level=ALL" >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	echo "cn_metric_prometheus_reporter_port=9081" >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	#添加启动监控功能
	echo "dn_enable_metric=true" >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	echo "dn_enable_performance_stat=true" >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	echo "dn_metric_reporter_list=PROMETHEUS" >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	echo "dn_metric_level=ALL" >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	echo "dn_metric_prometheus_reporter_port=9091" >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
}
set_protocol_class() { 
	local config_node=$1
	local schema_region=$2
	local data_region=$3
	#设置协议
	echo "config_node_consensus_protocol_class=${protocol_class[${config_node}]}" >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	echo "schema_region_consensus_protocol_class=${protocol_class[${schema_region}]}" >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	echo "data_region_consensus_protocol_class=${protocol_class[${data_region}]}" >> "${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
}
start_iotdb() { # 启动iotdb
	cd "${TEST_IOTDB_PATH}" || return 1
	./sbin/start-confignode.sh >/dev/null 2>&1 &
	sleep 10
	./sbin/start-datanode.sh -H "${TEST_IOTDB_PATH}/dn_dump.hprof" >/dev/null 2>&1 &
	cd ~/
}
stop_iotdb() { # 停止iotdb
	cd "${TEST_IOTDB_PATH}" || return 1
	./sbin/stop-datanode.sh >/dev/null 2>&1 &
	sleep 10
	./sbin/stop-confignode.sh >/dev/null 2>&1 &
	cd ~/
}
start_benchmark() { # 启动benchmark
	cd "${BM_PATH}" || return 1
	rm -rf "${BM_PATH}/logs" "${BM_PATH}/data"
	"${BM_PATH}/benchmark.sh" >/dev/null 2>&1 &
	cd ~/
}
start_bk_benchmark() { # 启动benchmark
	cd "${Background_PATH}" || return 1
	rm -rf "${Background_PATH}/logs" "${Background_PATH}/data"
	"${Background_PATH}/benchmark.sh" >/dev/null 2>&1 &
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
				mkdir -p "${BM_PATH}/data/csvOutput"
				cd "${BM_PATH}/data/csvOutput" || break
				touch Stuck_result.csv
				array1="INGESTION ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1"
				for ((i=0;i<100;i++))
				do
					echo "${array1}" >> Stuck_result.csv
				done
				cd ~
				break
			fi
			sleep 10
			continue
		else
			end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			echo "${ts_type}写入已完成！"
			break
		fi
	done
}
function get_single_index() {
    # 获取 prometheus 单个指标的值
    local query=$1
    local end=$2
    local url="http://${metric_server}/api/v1/query"
    local index_value
    index_value=$(curl -G -s "${url}" --data-urlencode "query=${query}" --data-urlencode "time=${end}" | jq '.data.result[0].value[1]' | tr -d '"')
	if [[ "$index_value" == "null" || -z "$index_value" ]]; then 
		index_value=0
	fi
	echo "${index_value}"
}
collect_monitor_data() { # 收集iotdb数据大小，顺、乱序文件数量
	local ip=$1
	local range_seconds=$((m_end_time - m_start_time))
	local data_file_bytes wal_file_bytes
	local maxNumofThread_C maxNumofThread_D

	[ "${range_seconds}" -le 0 ] && range_seconds=1
	data_file_bytes=$(get_single_index "sum(file_global_size{instance=~\"${ip}:9091\"})" "${m_end_time}")
	dataFileSize=$(format_gb "${data_file_bytes}")
	numOfSe0Level=$(get_single_index "sum(file_global_count{instance=~\"${ip}:9091\",name=\"seq\"})" "${m_end_time}")
	numOfUnse0Level=$(get_single_index "sum(file_global_count{instance=~\"${ip}:9091\",name=\"unseq\"})" "${m_end_time}")
	maxNumofThread_C=$(get_single_index "max_over_time(process_threads_count{instance=~\"${ip}:9081\"}[${range_seconds}s])" "${m_end_time}")
	maxNumofThread_D=$(get_single_index "max_over_time(process_threads_count{instance=~\"${ip}:9091\"}[${range_seconds}s])" "${m_end_time}")
	maxNumofThread=$(awk -v cn="${maxNumofThread_C}" -v dn="${maxNumofThread_D}" 'BEGIN{printf "%.0f\n", cn + dn}')
	maxNumofOpenFiles=$(get_single_index "max_over_time(file_count{instance=~\"${ip}:9091\",name=\"open_file_handlers\"}[${range_seconds}s])" "${m_end_time}")
	wal_file_bytes=$(get_single_index "max_over_time(file_size{instance=~\"${ip}:9091\",name=~\"wal\"}[${range_seconds}s])" "${m_end_time}")
	walFileSize=$(format_gb "${wal_file_bytes}")
	maxCPULoad=$(get_single_index "max_over_time(sys_cpu_load{instance=~\"${ip}:9091\"}[${range_seconds}s])" "${m_end_time}")
	avgCPULoad=$(get_single_index "avg_over_time(sys_cpu_load{instance=~\"${ip}:9091\"}[${range_seconds}s])" "${m_end_time}")
	maxDiskIOOpsRead=$(get_single_index "rate(disk_io_ops{instance=~\"${ip}:9091\",disk_id=~\"sdb\",type=~\"read\"}[${range_seconds}s])" "${m_end_time}")
	maxDiskIOOpsWrite=$(get_single_index "rate(disk_io_ops{instance=~\"${ip}:9091\",disk_id=~\"sdb\",type=~\"write\"}[${range_seconds}s])" "${m_end_time}")
	maxDiskIOSizeRead=$(get_single_index "rate(disk_io_size{instance=~\"${ip}:9091\",disk_id=~\"sdb\",type=~\"read\"}[${range_seconds}s])" "${m_end_time}")
	maxDiskIOSizeWrite=$(get_single_index "rate(disk_io_size{instance=~\"${ip}:9091\",disk_id=~\"sdb\",type=~\"write\"}[${range_seconds}s])" "${m_end_time}")
}
backup_test_data() { # 备份测试数据
	local ts_type=$1
	local protocol_id=$2
	local backup_dir="${BUCKUP_PATH}/${ts_type}/${commit_date_time}_${commit_id}_${protocol_id}"
	sudo rm -rf "${backup_dir}"
	sudo mkdir -p "${backup_dir}"
	sudo rm -rf "${TEST_IOTDB_PATH}/data"
	sudo mv "${TEST_IOTDB_PATH}" "${backup_dir}"
	sudo cp -rf "${BM_PATH}/data/csvOutput" "${backup_dir}"
	sudo cp -rf "${BM_PATH}/logs" "${backup_dir}"
}
mv_config_file() { # 移动配置文件
	local config_name=$1
	rm -rf "${BM_PATH}/conf/config.properties"
	cp -rf "${ATMOS_PATH}/conf/${test_type}/${config_name}" "${BM_PATH}/conf/config.properties"
}
clear_expired_file() { # 清理超过七天的文件
	find "$1" -mtime +7 -type d -name "*" -exec rm -rf {} \;
}
test_operation() {
	local protocol_class_input=$1
	ts_type=$2
	echo "开始测试${ts_type}时间序列！"
	#清理环境，确保无就程序影响
	check_benchmark_pid
	check_iotdb_pid
	#复制当前程序到执行位置
	set_env
	#修改IoTDB的配置
	modify_iotdb_config
	if [ "${protocol_class_input}" = "111" ]; then
		set_protocol_class 1 1 1
	elif [ "${protocol_class_input}" = "222" ]; then
		set_protocol_class 2 2 2
	elif [ "${protocol_class_input}" = "223" ]; then
		set_protocol_class 2 2 3
	elif [ "${protocol_class_input}" = "211" ]; then
		set_protocol_class 2 1 1
	else
		echo "协议设置错误！"
		return
	fi
	#启动iotdb和monitor监控
	start_iotdb
	data1=$(date +%Y_%m_%d_%H%M%S | cut -c 1-10)
	sleep 10
	
	####判断IoTDB是否正常启动
	for (( t_wait = 0; t_wait <= 10; t_wait++ ))
	do
	  iotdb_state=$("${TEST_IOTDB_PATH}/sbin/start-cli.sh" -e "show cluster" | grep 'Total line number = 2')
	  if [ "${iotdb_state}" = "Total line number = 2" ]; then
		break
	  else
		sleep 5
		continue
	  fi
	done
	if [ "${iotdb_state}" = "Total line number = 2" ]; then
		echo "IoTDB正常启动，准备开始测试"
		"${TEST_IOTDB_PATH}/sbin/start-cli.sh" -e "ALTER USER root SET PASSWORD '${IoTDB_PW}'" >/dev/null
	else
		echo "IoTDB未能正常启动，写入负值测试结果！"
		cost_time=-3
		throughput=-3
		insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,ts_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,walFileSize,avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},${walFileSize},${avgCPULoad},${maxCPULoad},${maxDiskIOSizeRead},${maxDiskIOSizeWrite},${maxDiskIOOpsRead},${maxDiskIOOpsWrite},${protocol_class_input})"
		run_mysql "${insert_sql}"
		update_sql="update ${TASK_TABLENAME} set ${test_type} = 'RError' where commit_id = '${commit_id}'"
		run_mysql "${update_sql}"
		return
	fi

	#启动写入程序
	rm -rf "${Background_PATH}/conf/config.properties"
	cp -rf "${ATMOS_PATH}/conf/${test_type}/${ts_type}" "${Background_PATH}/conf/config.properties"
	start_bk_benchmark
	#等待1分钟
	sleep 60
	#启动查询程序
	rm -rf "${BM_PATH}/conf/config.properties"
	cp -rf "${ATMOS_PATH}/conf/${test_type}/Q8" "${BM_PATH}/conf/config.properties"
	if [ "${ts_type}" = "tablemode" ]; then 
		#echo "IoTDB_DIALECT_MODE=table" >> ${BM_PATH}/conf/config.properties
		sed -i "s/^IoTDB_DIALECT_MODE=.*$/IoTDB_DIALECT_MODE=table/g" "${BM_PATH}/conf/config.properties"
	fi
	start_benchmark
	start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
	m_start_time=$(date +%s)

	#等待1分钟
	sleep 60

	monitor_test_status
	m_end_time=$(date +%s)

	#停止IoTDB程序和监控程序
	run_iotdb_cli -e "flush" >/dev/null

	#收集启动后基础监控数据
	collect_monitor_data "${TEST_IP}"
	#测试结果收集写入数据库
	parse_benchmark_result "LATEST_POINT"
	
	cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
	insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,ts_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,walFileSize,avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},${walFileSize},${avgCPULoad},${maxCPULoad},${maxDiskIOSizeRead},${maxDiskIOSizeWrite},${maxDiskIOOpsRead},${maxDiskIOOpsWrite},${protocol_class_input})"
	run_mysql "${insert_sql}"
	
	#停止IoTDB程序和监控程序
	stop_iotdb
	sleep 30
	check_benchmark_pid
	check_iotdb_pid

	#备份本次测试
	backup_test_data "${ts_type}" "${protocol_class_input}"
}
##准备开始测试
echo "ontesting" > "${INIT_PATH}/test_type_file"
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
	run_mysql "${update_sql}"
	echo "当前版本${commit_id}未执行过测试，即将编译后启动"
	if [ "${author}" != "Timecho" ]; then
		TABLENAME=${TABLENAME}
	else
		TABLENAME=${TABLENAME_T}
	fi
	init_items
	test_date_time=$(date +%Y%m%d%H%M%S)
	p_index=$(($RANDOM % ${#protocol_list[*]}))
	t_index=$(($RANDOM % ${#ts_list[*]}))	
	for (( j = 0; j < ${#protocol_list[*]}; j++ ))
	do
		for (( i = 0; i < ${#ts_list[*]}; i++ ))
		do
			echo "开始测试${protocol_list[$j]}协议下的${ts_list[$i]}时间序列！"
			test_operation "${protocol_list[$j]}" "${ts_list[$i]}"
		done
	done	
	###############################测试完成###############################
	echo "本轮测试${test_date_time}已结束."
	update_sql="update ${TASK_TABLENAME} set ${test_type} = 'done' where commit_id = '${commit_id}'"
	run_mysql "${update_sql}"
	update_sql02="update ${TASK_TABLENAME} set ${test_type} = 'skip' where ${test_type} is NULL and commit_date_time < '${commit_date_time}'"
	if [ "${author}" != "Timecho" ]; then
		run_mysql "${update_sql02}"
	fi
fi
echo "${test_type}" > "${INIT_PATH}/test_type_file"
