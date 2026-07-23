#!/usr/bin/env bash
set -o pipefail
readonly TEST_PLATFORM="windows"

if [ -z "${BASH_VERSION:-}" ]; then
	exec bash "$0" "$@"
fi
if shopt -oq posix; then
	exec bash "${BASH_SOURCE[0]}" "$@"
fi
#登录用户名
ACCOUNT=Administrator
IOTDB_PASSWORD="${IOTDB_PASSWORD:-TimechoDB@2021}"
TEST_TYPE="${TEST_TYPE:-windows_test}"
BENCHMARK_DEFAULT_RESULT_LABEL="INGESTION"
#初始环境存放路径
INIT_PATH="${INIT_PATH:-/data/atmos/zk_test_win}"
ATMOS_PATH=${INIT_PATH}/atmos-ex
BM_PATH=${INIT_PATH}/iot-benchmark
BACKUP_PATH="${BACKUP_PATH:-/nasdata/repository/windows_test}"
REPOS_PATH="${REPOS_PATH:-/nasdata/repository/master}"
TEST_PATH=${INIT_PATH}/first-rest-test
TEST_IOTDB_PATH=${TEST_PATH}/apache-iotdb
TEST_IOTDB_PATH_W="D:\\first-rest-test"
# 1. org.apache.iotdb.consensus.simple.SimpleConsensus
# 2. org.apache.iotdb.consensus.ratis.RatisConsensus
# 3. org.apache.iotdb.consensus.iot.IoTConsensus
protocol_class=(0 org.apache.iotdb.consensus.simple.SimpleConsensus org.apache.iotdb.consensus.ratis.RatisConsensus org.apache.iotdb.consensus.iot.IoTConsensus)
IoTDB_IP=11.101.17.128
Control=11.101.17.111
insert_list=(seq_w unseq_w seq_rw unseq_rw)
query_list=(Q1 Q2-1 Q2-2 Q2-3 Q3-1 Q3-2 Q3-3 Q4-a1 Q4-a2 Q4-a3 Q4-b1 Q4-b2 Q4-b3 Q5 Q6-1 Q6-2 Q6-3 Q7-1 Q7-2 Q7-3 Q7-4 Q8 Q9-1  Q9-2 Q9-3 Q10)
query_type=(PRECISE_POINT, TIME_RANGE, TIME_RANGE, TIME_RANGE, VALUE_RANGE, VALUE_RANGE, VALUE_RANGE, AGG_RANGE, AGG_RANGE, AGG_RANGE, AGG_RANGE, AGG_RANGE, AGG_RANGE, AGG_VALUE, AGG_RANGE_VALUE, AGG_RANGE_VALUE, AGG_RANGE_VALUE, GROUP_BY, GROUP_BY, GROUP_BY, GROUP_BY, LATEST_POINT, RANGE_QUERY_DESC, RANGE_QUERY_DESC, RANGE_QUERY_DESC, VALUE_RANGE_QUERY_DESC,)
############mysql信息##########################
MYSQL_HOST="${MYSQL_HOST:-111.200.37.158}"
MYSQL_PORT="${MYSQL_PORT:-13306}"
MYSQL_USERNAME="${MYSQL_USERNAME:-iotdbatm}"
MYSQL_PASSWORD="${ATMOS_DB_PASSWORD:-}"
DBNAME="${DBNAME:-QA_ATM}"
TABLENAME="ex_windows_test" #数据库中表的名称
TABLENAME_T="ex_windows_test_T" #数据库中表的名称
TASK_TABLENAME="ex_commit_history" #数据库中任务表的名称
############prometheus##########################
METRIC_SERVER="${METRIC_SERVER:-111.200.37.158:19090}"
MONITOR_TIMEOUT_SECONDS=${MONITOR_TIMEOUT_SECONDS:-7200}
MONITOR_POLL_INTERVAL_SECONDS=${MONITOR_POLL_INTERVAL_SECONDS:-10}
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
op_type=0
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
# 功能：准备当前测试所需的本地安装目录与运行环境
set_env() { # 拷贝编译好的iotdb到测试路径
	if [ ! -d "${TEST_PATH}" ]; then
		mkdir -p ${TEST_PATH}
		mkdir -p ${TEST_PATH}/apache-iotdb
	else
		rm -rf -- "${TEST_PATH}"
		mkdir -p ${TEST_PATH}
		mkdir -p ${TEST_PATH}/apache-iotdb
	fi
	cp -rf ${REPOS_PATH}/${commit_id}/apache-iotdb/* ${TEST_IOTDB_PATH}/
	mkdir -p ${TEST_IOTDB_PATH}/activation
	cp -rf ${ATMOS_PATH}/conf/${TEST_TYPE}/license ${TEST_IOTDB_PATH}/activation/
	cp -rf ${ATMOS_PATH}/conf/${TEST_TYPE}/env ${TEST_IOTDB_PATH}/.env
}
# 功能：按当前测试场景修改 IoTDB 配置
modify_iotdb_config() { # iotdb调整内存，关闭合并
	#修改IoTDB的配置
	sed -i "s/^@REM set ON_HEAP_MEMORY=2G.*$/set ON_HEAP_MEMORY=20G/g" ${TEST_IOTDB_PATH}/conf/windows/datanode-env.bat
	#清空配置文件
	# echo "只保留要修改的参数" > ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
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
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "cn_internal_address" "${IoTDB_IP}"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "cn_seed_config_node" "${IoTDB_IP}:10710"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "dn_rpc_address" "${IoTDB_IP}"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "dn_internal_address" "${IoTDB_IP}"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "dn_seed_config_node" "${IoTDB_IP}:10710"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "query_timeout_threshold" "60000000"
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
# 功能：部署并初始化当前测试运行环境
setup_env_windows() {
	TEST_IP=$1
	echo "开始重置环境！"
	remote_windows_reboot "${TEST_IP}"
	sleep 120
	rflag=0
	boot_ready=0
	while true; do
		echo "当前连接：${ACCOUNT}@${TEST_IP}"
		remote_windows_is_available "${TEST_IP}" "D:"
		if [ $? -eq 0 ];then
			boot_ready=1
			echo "${TEST_IP}已启动"
			break
		else
			echo "${TEST_IP}未启动"
			if [ $rflag -ge 5 ]; then
				break
			else
				remote_windows_reboot "${TEST_IP}"
				rflag=$((rflag+1))
			fi
			sleep 180
		fi
	done
	if [ "${boot_ready}" != "1" ]; then
	  echo "${TEST_IP} boot check failed!"
	  exit -1
	fi
	echo "setting env to ${TEST_IP} ..."
	#删除原有路径下所有
	remote_windows_reset_dir "${TEST_IP}" "${TEST_IOTDB_PATH_W}"
	#复制三项到客户机
	remote_windows_copy_contents "${TEST_PATH}" "${TEST_IP}" "${TEST_IOTDB_PATH_W}"
	#启动IoTDB
	echo "starting IoTDB on ${TEST_IP} ..."
	pid3=$(remote_windows_run_task "${TEST_IP}" "run_iotdb")
	sleep 10
	flag=0
	for (( t_wait = 0; t_wait <= 50; t_wait++ ))
	do
	  str1=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -h ${TEST_IP} -p 6667 -e "show cluster" | grep 'Total line number = 2')
	  if [ "$str1" = "Total line number = 2" ]; then
		echo "All Nodes is ready"
		flag=1
		break
	  else
		echo "All Nodes is not ready.Please wait ..."
		sleep 3
		continue
	  fi
	done
	if [ "$flag" = "0" ]; then
	  echo "All Nodes is not ready!"
	  exit -1
	fi
}
# 功能：清理运行目录并启动 IoT-Benchmark
start_benchmark() { # 启动benchmark
	rm -rf "${BM_PATH}/logs" "${BM_PATH}/data"
	(cd "${BM_PATH}" && ./benchmark.sh >/dev/null 2>&1 &)
}
# 功能：轮询测试进程和结果文件，处理完成或超时状态
monitor_test_status() { # 监控测试运行状态，获取最大打开文件数量和最大线程数
	local result_label="${1:-INGESTION}"
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
	dataFileSize=$(get_single_index "sum(file_global_size{instance=~\"${IoTDB_IP}:9091\"})" $m_end_time)
	dataFileSize=$(bytes_to_gib "${dataFileSize}")
	numOfSe0Level=$(get_single_index "sum(file_global_count{instance=~\"${IoTDB_IP}:9091\",name=\"seq\"})" $m_end_time)
	numOfUnse0Level=$(get_single_index "sum(file_global_count{instance=~\"${IoTDB_IP}:9091\",name=\"unseq\"})" $m_end_time)
	maxNumofThread_C=$(get_single_index "max_over_time(process_threads_count{instance=~\"${IoTDB_IP}:9081\"}[${metric_window}s])" $m_end_time)
	maxNumofThread_D=$(get_single_index "max_over_time(process_threads_count{instance=~\"${IoTDB_IP}:9091\"}[${metric_window}s])" $m_end_time)
	maxNumofThread=$(( $(to_int "${maxNumofThread_C}") + $(to_int "${maxNumofThread_D}") ))
	maxNumofOpenFiles=$(get_single_index "max_over_time(file_count{instance=~\"${IoTDB_IP}:9091\",name=\"open_file_handlers\"}[${metric_window}s])" $m_end_time)
	walFileSize=$(get_single_index "max_over_time(file_size{instance=~\"${IoTDB_IP}:9091\",name=~\"wal\"}[${metric_window}s])" $m_end_time)
	walFileSize=$(bytes_to_gib "${walFileSize}")
}
# 功能：选择并安装当前用例对应的配置文件
mv_config_file() { # 移动配置文件
	rm -rf -- "${BM_PATH}/conf/config.properties"
	cp -rf ${ATMOS_PATH}/conf/${TEST_TYPE}/$1 ${BM_PATH}/conf/config.properties
}
# 功能：执行单个测试组合并收集、解析和保存结果
test_operation() {
	TEST_IP=$1
	protocol_class=$2
	echo "开始测试！"
	for (( i = 0; i < ${#insert_list[*]}; i++ ))
	do
		#复制当前程序到执行位置
		data_type=${insert_list[${i}]}
		set_env
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
		#设置环境并启动IoTDB
		check_benchmark_pid
		setup_platform_env "${TEST_IP}"
		change_pwd=$(${TEST_IOTDB_PATH}/sbin/start-cli.sh -h ${TEST_IP} -p 6667 -e "ALTER USER root SET PASSWORD '${IOTDB_PASSWORD}'")
		echo "写入测试开始！"
		start_time=$(current_datetime)
		m_start_time=$(date +%s)
		mv_config_file ${data_type}
		start_benchmark 
		#等待1分钟
		sleep 60
		monitor_test_status "INGESTION"
		m_end_time=$(date +%s)
		collect_monitor_data
		#测试结果收集写入数据库
		csvOutputfile=$(find_result_csv || true)
		if ! parse_benchmark_result "${csvOutputfile}" "INGESTION"; then
			set_negative_benchmark_metrics -2
		fi

		cost_time=$(($(datetime_to_epoch "${end_time}") - $(datetime_to_epoch "${start_time}")))
		insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,ts_type,data_type,op_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,walFileSize,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}','${data_type}','INGESTION',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},${walFileSize},'${protocol_class}')"
		echo ${insert_sql}
		echo ${commit_id}版本${ts_type}写入${data_type}数据的${okPoint}点平均耗时${Latency}毫秒。吞吐率为：${throughput} 点/秒
		mysql_exec "${insert_sql}"
		#查询测试
		mkdir -p ${BACKUP_PATH}/${data_type}/${commit_date_time}_${commit_id}/BM
		cp -rf ${BM_PATH}/logs ${BACKUP_PATH}/${data_type}/${commit_date_time}_${commit_id}/BM/
		if [[ "${data_type}" == "seq_w" || "${data_type}" == "unseq_w" ]]; then 
			for (( j = 0; j < ${#query_list[*]}; j++ ))
			do
				echo "开始${query_list[${j}]}查询！"
				op_type=${query_list[${j}]}
				mv_config_file ${op_type}
				mkdir -p ${BACKUP_PATH}/${data_type}/${commit_date_time}_${commit_id}/BM/${op_type}
				for (( m = 1; m <= 1; m++ ))
				do
					check_benchmark_pid
					sleep 3
					start_benchmark
					m_start_time=$(date +%s)
					start_time=$(current_datetime)
					#等待1分钟
					sleep 3
					monitor_test_status "${query_type[${j}]}"
					m_end_time=$(date +%s)
					#测试结果收集写入数据库
					#csvOutputfile=${BM_PATH}/data/csvOutput/*result.csv
					csvOutputfile=$(find_result_csv || true)
					if [ ! -f "$csvOutputfile" ]; then
						echo "未找到CSV文件"
						sleep 60
					else
						echo "$csvOutputfile"
						sleep 10
					fi
					if ! parse_benchmark_result "${csvOutputfile}" "${query_type[${j}]}"; then
						set_negative_benchmark_metrics -2
					fi
					cost_time=$(($(datetime_to_epoch "${end_time}") - $(datetime_to_epoch "${start_time}")))
					insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,ts_type,data_type,op_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,walFileSize,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}','${data_type}','${op_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${walFileSize},'${protocol_class}')"
					echo ${commit_id}版本${ts_type}类型${data_type}数据${op_type}查询${okPoint}数据点的耗时为：${Latency}ms
					mysql_exec "${insert_sql}"
					cp -rf ${BM_PATH}/logs ${BACKUP_PATH}/${data_type}/${commit_date_time}_${commit_id}/BM/${op_type}/
					cp -rf ${BM_PATH}/data/csvOutput ${BACKUP_PATH}/${data_type}/${commit_date_time}_${commit_id}/BM/${op_type}/
				done
				#停止IoTDB程序和监控程序
				sleep 10
			done
		fi
		scp -r  ${ACCOUNT}@${TEST_IP}:${TEST_IOTDB_PATH_W}/apache-iotdb/logs ${BACKUP_PATH}/${data_type}/${commit_date_time}_${commit_id}/
	done
}
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
	test_operation ${IoTDB_IP} 223 
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
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/remote_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/platform_common.sh"

main "$@"
