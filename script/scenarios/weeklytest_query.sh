#!/usr/bin/env bash
set -o pipefail

if [ -z "${BASH_VERSION:-}" ]; then
	exec bash "$0" "$@"
fi
if shopt -oq posix; then
	exec bash "${BASH_SOURCE[0]}" "$@"
fi
#登录用户名
TEST_IP="11.101.17.113"
ACCOUNT=atmos
IOTDB_PASSWORD="${IOTDB_PASSWORD:-TimechoDB@2021}"
TEST_TYPE="${TEST_TYPE:-weeklytest_query}"
BENCHMARK_DEFAULT_RESULT_LABEL="PRECISE_POINT"
#初始环境存放路径
INIT_PATH="${INIT_PATH:-/data/atmos/zk_test}"
ATMOS_PATH=${INIT_PATH}/atmos-ex
BM_PATH=${INIT_PATH}/iot-benchmark
DATA_PATH=/data/atmos/original
BACKUP_PATH="${BACKUP_PATH:-/nasdata/repository/weeklytest_query}"
REPOS_PATH="${REPOS_PATH:-/nasdata/repository/master}"
TEST_INIT_PATH="${TEST_INIT_PATH:-/data/atmos}"
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb
# 1. org.apache.iotdb.consensus.simple.SimpleConsensus
# 2. org.apache.iotdb.consensus.ratis.RatisConsensus
# 3. org.apache.iotdb.consensus.iot.IoTConsensus
protocol_class=(0 org.apache.iotdb.consensus.simple.SimpleConsensus org.apache.iotdb.consensus.ratis.RatisConsensus org.apache.iotdb.consensus.iot.IoTConsensus)
protocol_list=(111 223 222 211)
ts_list=(common aligned template tempaligned)
############mysql信息##########################
MYSQL_HOST="${MYSQL_HOST:-111.200.37.158}"
MYSQL_PORT="${MYSQL_PORT:-13306}"
MYSQL_USERNAME="${MYSQL_USERNAME:-iotdbatm}"
MYSQL_PASSWORD="${ATMOS_DB_PASSWORD:-}"
DBNAME="${DBNAME:-QA_ATM}"
TABLENAME="ex_weeklytest_query" #数据库中表的名称
TABLENAME_T="ex_weeklytest_query_T" #企业版结果表名
TASK_TABLENAME="ex_commit_history" #数据库中任务表的名称
############prometheus##########################
METRIC_SERVER="${METRIC_SERVER:-111.200.37.158:19090}"
MONITOR_TIMEOUT_SECONDS=${MONITOR_TIMEOUT_SECONDS:-7200}
MONITOR_POLL_INTERVAL_SECONDS=${MONITOR_POLL_INTERVAL_SECONDS:-10}
sensor_type_list=(one more)
insert_list=(seq_w unseq_w seq_rw unseq_rw)
data_mode=(tree table)
query_data_type=(sequence unsequence)
query_list=(Q1 Q2-1 Q2-2 Q2-3 Q3-1 Q3-2 Q3-3 Q4-a1 Q4-a2 Q4-a3 Q4-b1 Q4-b2 Q4-b3 Q5 Q6-1 Q6-2 Q6-3 Q7-1 Q7-2 Q7-3 Q7-4 Q8 Q9-1 Q9-2 Q9-3 Q10)
query_type_list=(PRECISE_POINT, TIME_RANGE, TIME_RANGE, TIME_RANGE, VALUE_RANGE, VALUE_RANGE, VALUE_RANGE, AGG_RANGE, AGG_RANGE, AGG_RANGE, AGG_RANGE, AGG_RANGE, AGG_RANGE, AGG_VALUE, AGG_RANGE_VALUE, AGG_RANGE_VALUE, AGG_RANGE_VALUE, GROUP_BY, GROUP_BY, GROUP_BY, GROUP_BY, LATEST_POINT, RANGE_QUERY_DESC, RANGE_QUERY_DESC, RANGE_QUERY_DESC, VALUE_RANGE_QUERY_DESC,)
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

# 功能：重置当前测试用例使用的指标和运行状态
init_items() {
############定义监控采集项初始值##########################
test_date_time=0
ts_type=0
data_type=0
query_type=0
sensor_type=0
query_num=0
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
# 功能：保留或执行测试异常通知逻辑
sendEmail() {
sendEmail=$(${TOOLS_PATH}/sendEmail.sh $1 >/dev/null 2>&1 &)
}
# 功能：准备当前测试所需的本地安装目录与运行环境
set_env() { # 拷贝编译好的iotdb到测试路径
	if [ ! -d "${TEST_IOTDB_PATH}" ]; then
		mkdir -p ${TEST_IOTDB_PATH}
	else
		rm -rf -- "${TEST_IOTDB_PATH}"
		mkdir -p ${TEST_IOTDB_PATH}
	fi
	cp -rf ${REPOS_PATH}/${commit_id}/apache-iotdb/* ${TEST_IOTDB_PATH}/
	mkdir -p ${TEST_IOTDB_PATH}/activation
	cp -rf ${ATMOS_PATH}/conf/${TEST_TYPE}/license ${TEST_IOTDB_PATH}/activation/
}
# 功能：按当前测试场景修改 IoTDB 配置
modify_iotdb_config() { # iotdb调整内存，关闭合并
	#修改IoTDB的配置
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"20G\"/g" ${TEST_IOTDB_PATH}/conf/datanode-env.sh
	#清空配置文件
	# echo "只保留要修改的参数" > ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "series_slot_num" "10000"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "query_timeout_threshold" "6000000"
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
	config_node=$1
	schema_region=$2
	data_region=$3
	#设置协议
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "config_node_consensus_protocol_class" "${protocol_class[${config_node}]}"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "schema_region_consensus_protocol_class" "${protocol_class[${schema_region}]}"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "data_region_consensus_protocol_class" "${protocol_class[${data_region}]}"
}
# 功能：启动当前场景中的 IoTDB 服务
start_iotdb() { # 启动iotdb
	(cd "${TEST_IOTDB_PATH}" && ./sbin/start-confignode.sh >/dev/null 2>&1 &)
	sleep 10
	(cd "${TEST_IOTDB_PATH}" && ./sbin/start-datanode.sh -H "${TEST_IOTDB_PATH}/dn_dump.hprof" >/dev/null 2>&1 &)
}
# 功能：停止当前场景中的 IoTDB 服务
stop_iotdb() { # 停止iotdb
	(cd "${TEST_IOTDB_PATH}" && ./sbin/stop-datanode.sh >/dev/null 2>&1 &)
	sleep 10
	(cd "${TEST_IOTDB_PATH}" && ./sbin/stop-confignode.sh >/dev/null 2>&1 &)
}
# 功能：清理运行目录并启动 IoT-Benchmark
start_benchmark() { # 启动benchmark
	rm -rf "${BM_PATH}/logs" "${BM_PATH}/data"
	(cd "${BM_PATH}" && ./benchmark.sh >/dev/null 2>&1 &)
}
# 功能：轮询测试进程和结果文件，处理完成或超时状态
monitor_test_status() { # 监控测试运行状态，获取最大打开文件数量和最大线程数
	local result_label="${1:-PRECISE_POINT}"
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
collect_monitor_data() { # 收集iotdb数据大小，顺、乱序文件数量
	#TEST_IP=$1
	local metric_window=0
	local maxNumofThread_C=0
	local maxNumofThread_D=0

	dataFileSize=0
	walFileSize=0
	numOfSe0Level=0
	numOfUnse0Level=0
	maxNumofOpenFiles=0
	maxNumofThread=0
	metric_window=$((m_end_time-m_start_time))
	[ "${metric_window}" -gt 0 ] || metric_window=1
	#调用监控获取数值
	dataFileSize=$(get_single_index "sum(file_global_size{instance=~\"${TEST_IP}:9091\"})" $m_end_time)
	dataFileSize=$(bytes_to_gib "${dataFileSize}")
	numOfSe0Level=$(get_single_index "sum(file_global_count{instance=~\"${TEST_IP}:9091\",name=\"seq\"})" $m_end_time)
	numOfUnse0Level=$(get_single_index "sum(file_global_count{instance=~\"${TEST_IP}:9091\",name=\"unseq\"})" $m_end_time)
	maxNumofThread_C=$(get_single_index "max_over_time(process_threads_count{instance=~\"${TEST_IP}:9081\"}[${metric_window}s])" $m_end_time)
	maxNumofThread_D=$(get_single_index "max_over_time(process_threads_count{instance=~\"${TEST_IP}:9091\"}[${metric_window}s])" $m_end_time)
	maxNumofThread=$(( $(to_int "${maxNumofThread_C}") + $(to_int "${maxNumofThread_D}") ))
	maxNumofOpenFiles=$(get_single_index "max_over_time(file_count{instance=~\"${TEST_IP}:9091\",name=\"open_file_handlers\"}[${metric_window}s])" $m_end_time)
	walFileSize=$(get_single_index "max_over_time(file_size{instance=~\"${TEST_IP}:9091\",name=~\"wal\"}[${metric_window}s])" $m_end_time)
	walFileSize=$(bytes_to_gib "${walFileSize}")
}
# 功能：归档测试日志、配置、数据或结果文件
backup_test_data() { # 备份测试数据
	sudo rm -rf -- "${BACKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}"
	sudo mkdir -p ${BACKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
	sudo rm -rf -- "${TEST_IOTDB_PATH}/data"
	sudo mv ${TEST_IOTDB_PATH} ${BACKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
	sudo cp -rf ${BM_PATH}/data/csvOutput ${BACKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}
}
# 功能：选择并安装当前用例对应的配置文件
mv_config_file() { # 移动配置文件
	rm -rf -- "${BM_PATH}/conf/config.properties"
	cp -rf ${ATMOS_PATH}/conf/${TEST_TYPE}/$1/$2 ${BM_PATH}/conf/config.properties
	if [ $3 = "table" ]; then
		sed -i "s/^IoTDB_DIALECT_MODE=.*$/IoTDB_DIALECT_MODE=table/g" ${BM_PATH}/conf/config.properties
	fi
}
# 功能：执行单个测试组合并收集、解析和保存结果
test_operation() {
	protocol_class=$1
	#查询测试
	for (( j = 0; j < ${#query_data_type[*]}; j++ ))
	do
		for (( d = 0; d < ${#data_mode[*]}; d++ ))
		do
			echo "开始${query_data_type[${j}]}_${data_mode[${d}]}查询！"
			path_new=${query_data_type[${j}]}_${data_mode[${d}]}
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
			#cp -rf ${DATA_PATH}/${path_new}/data ${TEST_IOTDB_PATH}/
			mv ${DATA_PATH}/${path_new}/data ${TEST_IOTDB_PATH}/
			sleep 1
			for (( s = 0; s < ${#sensor_type_list[*]}; s++ ))
			do
				sensor_type=${sensor_type_list[${s}]}
				for (( i = 0; i < ${#query_list[*]}; i++ ))
				do
					echo "开始${query_list[${i}]}查询！"
					check_iotdb_pid
					sleep 1
					start_iotdb
					sleep 10
					####判断IoTDB是否正常启动
					for (( t_wait = 0; t_wait <= 10; t_wait++ ))
					do
					  iotdb_state=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw root -e "show cluster" | grep 'Total line number = 2')
					  if [ "${iotdb_state}" = "Total line number = 2" ]; then
						break
					  else
						sleep 5
						continue
					  fi
					done
					if [ "${iotdb_state}" = "Total line number = 2" ]; then
						echo "IoTDB正常启动，准备开始测试"
						#等待1分钟
						sleep 60
					else
						echo "IoTDB未能正常启动，写入负值测试结果！"
						cost_time=-3
						throughput=-3
						insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,ts_type,data_type,query_type,sensor_type,query_num,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}','${data_type}','${query_type}','${sensor_type}','${query_num}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},'${protocol_class}')"
						mysql_exec "${insert_sql}"
						update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'RError' where commit_id = '${commit_id}'"
						result_string=$(mysql_exec "${update_sql}")
						return
					fi
					
					#启动写入程序
					mv_config_file ${sensor_type_list[${s}]} ${query_list[${i}]} ${data_mode[${d}]}
					for (( m = 1; m <= 2; m++ ))
					do
						ts_type=${data_mode[${d}]}
						data_type=${query_data_type[${j}]}
						query_num=${m}
						query_type=${query_list[${i}]}
						m_start_time=$(date +%s)
						start_time=$(current_datetime)
						start_benchmark

						#等待1分钟
						sleep 3
						
						monitor_test_status "${query_type_list[${i}]}"
						m_end_time=$(date +%s)
						#收集启动后基础监控数据
						collect_monitor_data
						#测试结果收集写入数据库
						csvOutputfile=$(find_result_csv || true)
						if ! parse_benchmark_result "${csvOutputfile}" "${query_type_list[${i}]}"; then
							set_negative_benchmark_metrics -2
						fi

						cost_time=$(($(datetime_to_epoch "${end_time}") - $(datetime_to_epoch "${start_time}")))
						insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,ts_type,data_type,query_type,sensor_type,query_num,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}','${data_type}','${query_type}','${sensor_type}','${query_num}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},'${protocol_class}')"
						echo ${commit_id}版本${ts_type}查询${okPoint}数据点的耗时为：${Latency}ms
						mysql_exec "${insert_sql}"
					done
					#停止IoTDB程序
					stop_iotdb
					sleep 10
					check_iotdb_pid
					#备份本次测试
					cp -rf ${BM_PATH}/data/csvOutput ${TEST_IOTDB_PATH}/logs/ 
					cp -rf ${BM_PATH}/logs ${TEST_IOTDB_PATH}/logs/
					mv ${TEST_IOTDB_PATH}/logs ${TEST_IOTDB_PATH}/logs_${query_list[${i}]}_${sensor_type_list[${s}]}
				done
			done
			mv  ${TEST_IOTDB_PATH}/data ${DATA_PATH}/${path_new}/
			echo "本轮${query_data_type[${j}]}_${data_mode[${d}]}时间序列查询测试已结束."
			#备份本次测试
			backup_test_data ${query_data_type[${j}]}_${data_mode[${d}]}
		done
	done
}

##准备开始测试
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
##查询是否有复测任务
if [ "${commit_id}" = "" ]; then
	query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${TEST_TYPE} is NULL ORDER BY commit_date_time desc limit 1 "
	result_string=$(mysql_exec "${query_sql}")
	commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
	author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
	commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
fi
if [ "${commit_id}" = "" ]; then
	sleep 60s
else
	update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'ontesting' where commit_id = '${commit_id}'"
	result_string=$(mysql_exec "${update_sql}")
	echo "当前版本${commit_id}未执行过测试，即将编译后启动"
	if [ "${author}" != "Timecho" ]; then
		TABLENAME=${TABLENAME}
	else
		TABLENAME=${TABLENAME_T}
	fi
	init_items
	test_date_time=`date +%Y%m%d%H%M%S`
	test_operation 223
	###############################测试完成###############################
	echo "本轮测试${test_date_time}已结束."
	update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'done' where commit_id = '${commit_id}'"
	result_string=$(mysql_exec "${update_sql}")
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
