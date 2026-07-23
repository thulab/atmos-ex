#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
	exec bash "$0" "$@"
fi
if shopt -oq posix; then
	exec bash "${BASH_SOURCE[0]}" "$@"
fi

set -o pipefail

#登录用户名
TEST_IP="11.101.17.156"
readonly TIMECHO_ROUTINE_IP="11.101.17.156"
ACCOUNT=atmos
IOTDB_PASSWORD="${IOTDB_PASSWORD:-TimechoDB@2021}"
TEST_TYPE="${TEST_TYPE:-routine_test}"
#初始环境存放路径
INIT_PATH="${INIT_PATH:-/data/atmos/zk_test}"
ATMOS_PATH=${INIT_PATH}/atmos-ex
BM_PATH=${INIT_PATH}/iot-benchmark
BACKUP_PATH="${BACKUP_PATH:-/nasdata/repository/routine_test}"
REPOS_PATH="${REPOS_PATH:-/nasdata/repository/master}"
TEST_INIT_PATH="${TEST_INIT_PATH:-/data/atmos}"
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb
# 1. org.apache.iotdb.consensus.simple.SimpleConsensus
# 2. org.apache.iotdb.consensus.ratis.RatisConsensus
# 3. org.apache.iotdb.consensus.iot.IoTConsensus
protocol_class=(0 org.apache.iotdb.consensus.simple.SimpleConsensus org.apache.iotdb.consensus.ratis.RatisConsensus org.apache.iotdb.consensus.iot.IoTConsensus)
protocol_list=(111 223 222 211)
ts_list=(SESSION_BY_TABLET SESSION_BY_RECORDS SESSION_BY_RECORD JDBC)
############mysql信息##########################
MYSQL_HOST="${MYSQL_HOST:-111.200.37.158}"
MYSQL_PORT="${MYSQL_PORT:-13306}"
MYSQL_USERNAME="${MYSQL_USERNAME:-iotdbatm}"
MYSQL_PASSWORD="${ATMOS_DB_PASSWORD:-}"
DBNAME="${DBNAME:-QA_ATM}"
TABLENAME="ex_routine_test" #数据库中表的名称
TASK_TABLENAME="ex_commit_history" #数据库中任务表的名称
############prometheus##########################
METRIC_SERVER="${METRIC_SERVER:-111.200.37.158:19090}"
TABLENAME_T="ex_routine_test_T"
result_table="${TABLENAME}"
AUTHOR_FILTER_SQL="author != 'Timecho'"
#insert_list=(seq_w unseq_w)
insert_list=(seq_w unseq_w seq_rw unseq_rw)
query_data_type=(seq unseq)
query_list=(Q1 Q2-1 Q2-2 Q2-3 Q3-1 Q3-2 Q3-3 Q4-a1 Q4-a2 Q4-a3 Q4-b1 Q4-b2 Q4-b3 Q5 Q6-1 Q6-2 Q6-3 Q7-1 Q7-2 Q7-3 Q7-4 Q8 Q9 Q10)
query_type=(PRECISE_POINT, TIME_RANGE, TIME_RANGE, TIME_RANGE, VALUE_RANGE, VALUE_RANGE, VALUE_RANGE, AGG_RANGE, AGG_RANGE, AGG_RANGE, AGG_RANGE, AGG_RANGE, AGG_RANGE, AGG_VALUE, AGG_RANGE_VALUE, AGG_RANGE_VALUE, AGG_RANGE_VALUE, GROUP_BY, GROUP_BY, GROUP_BY, GROUP_BY, LATEST_POINT, RANGE_QUERY_DESC, VALUE_RANGE_QUERY_DESC,)

############公用函数##########################
# 功能：探测当前主机、磁盘或运行环境信息
detect_local_ips() {
	{
		hostname -I 2>/dev/null || true
		ifconfig -a 2>/dev/null | grep inet | grep -v 127.0.0.1 | grep -v inet6 | awk '{print $2}' | tr -d "addr:" || true
	} | tr ' ' '\n' | awk 'NF && !seen[$0]++'
}

# 功能：根据本机地址选择例行测试的数据表和作者过滤条件
init_routine_route() {
	local local_ips=""
	local first_ip=""

	local_ips="$(detect_local_ips)"
	first_ip="$(printf '%s\n' "${local_ips}" | awk 'NF {print; exit}')"

	if printf '%s\n' "${local_ips}" | grep -Fxq "${TIMECHO_ROUTINE_IP}"; then
		AUTHOR_FILTER_SQL="author = 'Timecho'"
		result_table="${TABLENAME_T}"
		TEST_IP="${TIMECHO_ROUTINE_IP}"
	else
		AUTHOR_FILTER_SQL="author != 'Timecho'"
		result_table="${TABLENAME}"
		if [ -n "${first_ip}" ]; then
			TEST_IP="${first_ip}"
		fi
	fi

	log "route: AUTHOR_FILTER_SQL=${AUTHOR_FILTER_SQL}, result_table=${result_table}, TEST_IP=${TEST_IP}"
}

# 功能：将输入值格式化为目标展示或配置格式
format_gb() {
	awk -v value="$1" 'BEGIN{printf "%.2f\n", value / 1048576 / 1024}'
}

# 功能：使用当前场景参数执行 IoTDB CLI 命令
run_iotdb_cli() {
	"${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw "${IOTDB_PASSWORD}" -h 127.0.0.1 -p 6667 "$@"
}

# 功能：解析 Benchmark 输出并更新结果指标
parse_benchmark_result() {
	local result_label=$1
	local csv_file
	csv_file=$(find "${BM_PATH}/data/csvOutput" -name "*result.csv" -print -quit 2>/dev/null)
	if [ -z "${csv_file}" ]; then
		return 1
	fi

	read okOperation okPoint failOperation failPoint throughput <<<"$(awk -F, -v label="${result_label}" 'index($0, label) == 1 {print $2,$3,$4,$5,$6; exit}' "${csv_file}")"
	read Latency MIN P10 P25 MEDIAN P75 P90 P95 P99 P999 MAX <<<"$(awk -F, -v label="${result_label}" 'index($0, label) == 1 {count++; if (count == 2) {print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12; exit}}' "${csv_file}")"
}

# 功能：比较本地与仓库版本并同步 IoT-Benchmark
check_benchmark_version() {
	log "检查iot-benchmark版本"
	BM_REPOS_PATH=/nasdata/repository/iot-benchmark
	BM_NEW=$(git_commit_abbrev "${BM_REPOS_PATH}/git.properties")
	BM_OLD=$(git_commit_abbrev "${BM_PATH}/git.properties")
	if [ -n "${BM_NEW}" ] && [ "${BM_OLD}" != "${BM_NEW}" ]; then
		log "sync benchmark ${BM_OLD:-missing} -> ${BM_NEW}"
		rm -rf -- "${BM_PATH}"
		cp -rf -- "${BM_REPOS_PATH}" "${BM_PATH}"
	fi
}

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
maxCPULoad=0
avgCPULoad=0
maxDiskIOOpsRead=0
maxDiskIOOpsWrite=0
maxDiskIOSizeRead=0
maxDiskIOSizeWrite=0
############定义监控采集项初始值##########################
}
local_ip=$(ifconfig -a 2>/dev/null | grep inet | grep -v 127.0.0.1 | grep -v inet6 | awk '{print $2}' | tr -d "addr:")
# 功能：保留或执行测试异常通知逻辑
sendEmail() {
"${TOOLS_PATH}/sendEmail.sh" "$1" >/dev/null 2>&1 &
}
# 功能：检查当前场景的前置条件、进程状态或结果有效性
check_monitor_pid() { # 检查benchmark-moitor的pid，有就停止
	monitor_pid=$(jps | grep App | awk '{print $1}')
	if [ "${monitor_pid}" = "" ]; then
		log "未检测到监控程序！"
	else
		kill -TERM "${monitor_pid}" 2>/dev/null || true
		sleep 2
		kill -KILL "${monitor_pid}" 2>/dev/null || true
		log "BM程序已停止！"
	fi
}
# 功能：准备当前测试所需的本地安装目录与运行环境
set_env() { # 拷贝编译好的iotdb到测试路径
	if [ ! -d "${TEST_IOTDB_PATH}" ]; then
		mkdir -p "${TEST_IOTDB_PATH}"
	else
		rm -rf "${TEST_IOTDB_PATH}"
		mkdir -p "${TEST_IOTDB_PATH}"
	fi
	cp -rf "${REPOS_PATH}/${commit_id}/apache-iotdb/"* "${TEST_IOTDB_PATH}/"
	mkdir -p "${TEST_IOTDB_PATH}/activation"
	cp -rf "${ATMOS_PATH}/conf/${TEST_TYPE}/license" "${TEST_IOTDB_PATH}/activation/"
	cp -rf "${ATMOS_PATH}/conf/${TEST_TYPE}/env" "${TEST_INIT_PATH}/apache-iotdb/.env"
}
# 功能：按当前测试场景修改 IoTDB 配置
modify_iotdb_config() { # iotdb调整内存，关闭合并
	#修改IoTDB的配置
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"20G\"/g" "${TEST_IOTDB_PATH}/conf/datanode-env.sh"
	#清空配置文件
	# echo "只保留要修改的参数" > ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	#关闭影响写入性能的其他功能
	#echo "enable_seq_space_compaction=false" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	#echo "enable_unseq_space_compaction=false" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	#echo "enable_cross_space_compaction=false" >> ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
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
	local config_node=$1
	local schema_region=$2
	local data_region=$3
	#设置协议
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "config_node_consensus_protocol_class" "${protocol_class[${config_node}]}"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "schema_region_consensus_protocol_class" "${protocol_class[${schema_region}]}"
	set_iotdb_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" "data_region_consensus_protocol_class" "${protocol_class[${data_region}]}"
}
# 功能：启动当前场景中的 IoTDB 服务
start_iotdb() { # 启动iotdb
	cd "${TEST_IOTDB_PATH}" || return 1
	./sbin/start-confignode.sh >/dev/null 2>&1 &
	sleep 10
	./sbin/start-datanode.sh -H "${TEST_IOTDB_PATH}/dn_dump.hprof" >/dev/null 2>&1 &
	cd ~/
}
# 功能：停止当前场景中的 IoTDB 服务
stop_iotdb() { # 停止iotdb
	cd "${TEST_IOTDB_PATH}" || return 1
	./sbin/stop-datanode.sh >/dev/null 2>&1 &
	sleep 10
	./sbin/stop-confignode.sh >/dev/null 2>&1 &
	cd ~/
}
# 功能：清理运行目录并启动 IoT-Benchmark
start_benchmark() { # 启动benchmark
	cd "${BM_PATH}" || return 1
	rm -rf "${BM_PATH}/logs" "${BM_PATH}/data"
	"${BM_PATH}/benchmark.sh" >/dev/null 2>&1 &
	cd ~/
}
# 功能：轮询测试进程和结果文件，处理完成或超时状态
monitor_test_status() { # 监控测试运行状态，获取最大打开文件数量和最大线程数
	while true; do
		csvOutput=${BM_PATH}/data/csvOutput
		if [ ! -d "$csvOutput" ]; then
			now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
			t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
			if [ $t_time -ge 100000 ]; then
				log "测试失败"
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
			log "${ts_type}写入已完成！"
			break
		fi
	done
}
# 功能：采集当前测试窗口内的资源和文件指标
collect_monitor_data() { # 收集iotdb数据大小，顺、乱序文件数量
	local ip="${1:-${TEST_IP}}"
	local range_seconds=$((m_end_time - m_start_time))
	local data_file_bytes wal_file_bytes
	local maxNumofThread_C maxNumofThread_D

	[ "${range_seconds}" -le 0 ] && range_seconds=1
	#调用监控获取数值
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
# 功能：归档测试日志、配置、数据或结果文件
backup_test_data() { # 备份测试数据
	local data_type=$1
	local protocol_id=$2
	local backup_dir="${BACKUP_PATH}/${data_type}/${commit_date_time}_${commit_id}_${protocol_id}"
	sudo rm -rf "${backup_dir}"
	sudo mkdir -p "${backup_dir}"
    sudo rm -rf "${TEST_IOTDB_PATH}/data"
	sudo mv "${TEST_IOTDB_PATH}" "${backup_dir}"
	sudo cp -rf "${BM_PATH}/data/csvOutput" "${backup_dir}"
}
# 功能：选择并安装当前用例对应的配置文件
mv_config_file() { # 移动配置文件
	local config_name=$1
	rm -rf "${BM_PATH}/conf/config.properties"
	cp -rf "${ATMOS_PATH}/conf/${TEST_TYPE}/${config_name}" "${BM_PATH}/conf/config.properties"
}
# 功能：清理超过保留期限的历史测试文件
clear_expired_file() { # 清理超过七天的文件
	find "$1" -mtime +7 -type d -name "*" -exec rm -rf {} \;
}
# 功能：执行单个测试组合并收集、解析和保存结果
test_operation() {
	run_isolated_case test_operation_impl "$@"
}

# 功能：执行单轮例行测试；由 test_operation 隔离运行状态
test_operation_impl() {
	local protocol_class_input=$1
	#写入测试
	ts_type='common'
	for (( i = 0; i < ${#insert_list[*]}; i++ ))
	do
		log "开始${insert_list[${i}]}写入！"
		data_type=${insert_list[${i}]}
		#清理环境，确保无就程序影响
		check_monitor_pid
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
			log "协议设置错误！"
			return
		fi
		#启动iotdb和monitor监控
		start_iotdb
		#start_monitor
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
			log "IoTDB正常启动，准备开始测试"
			"${TEST_IOTDB_PATH}/sbin/start-cli.sh" -e "ALTER USER root SET PASSWORD '${IOTDB_PASSWORD}'" >/dev/null
		else
			log "IoTDB未能正常启动，写入负值测试结果！"
			cost_time=-3
			throughput=-3
			insert_sql="insert into ${result_table} (commit_date_time,test_date_time,commit_id,author,ts_type,data_type,op_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,walFileSize,avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}','${data_type}','INGESTION',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},${walFileSize},${avgCPULoad},${maxCPULoad},${maxDiskIOSizeRead},${maxDiskIOSizeWrite},${maxDiskIOOpsRead},${maxDiskIOOpsWrite},'${protocol_class_input}')"
			mysql_exec "${insert_sql}"
			update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'RError' where commit_id = '${commit_id}'"
			mysql_exec "${update_sql}"
			continue
		fi
		
		#启动写入程序
		mv_config_file "${data_type}"

		start_benchmark
		start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
		m_start_time=$(date +%s)

		#等待1分钟
		sleep 10
		
		monitor_test_status
		m_end_time=$(date +%s)
		
		#停止IoTDB程序和监控程序
		run_iotdb_cli -e "flush" >/dev/null

		#收集启动后基础监控数据
		collect_monitor_data "${TEST_IP}"
		#测试结果收集写入数据库
		parse_benchmark_result "INGESTION"

		cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
		insert_sql="insert into ${result_table} (commit_date_time,test_date_time,commit_id,author,ts_type,data_type,op_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,walFileSize,avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}','${data_type}','INGESTION',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${errorLogSize},${walFileSize},${avgCPULoad},${maxCPULoad},${maxDiskIOSizeRead},${maxDiskIOSizeWrite},${maxDiskIOOpsRead},${maxDiskIOOpsWrite},'${protocol_class_input}')"
		log ${commit_id}版本${ts_type}写入${data_type}数据的${okPoint}点平均耗时${Latency}毫秒。吞吐率为：${throughput} 点/秒
		mysql_exec "${insert_sql}"
		
		#停止IoTDB程序和监控程序
		stop_iotdb
		sleep 30
		check_iotdb_pid
		#查询测试
		for (( j = 0; j < ${#query_list[*]}; j++ ))
		do
			log "开始${query_list[${j}]}查询！"
			op_type=${query_list[${j}]}
			check_iotdb_pid
			sleep 1
			start_iotdb
			sleep 30	
			####判断IoTDB是否正常启动
			for (( t_wait = 0; t_wait <= 10; t_wait++ ))
			do
			  iotdb_state=$("${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw "${IOTDB_PASSWORD}" -e "show cluster" | grep 'Total line number = 2')
			  if [ "${iotdb_state}" = "Total line number = 2" ]; then
				break
			  else
				sleep 30
				continue
			  fi
			done
			if [ "${iotdb_state}" = "Total line number = 2" ]; then
				log "IoTDB正常启动，准备开始测试"
			else
				log "IoTDB未能正常启动，写入负值测试结果！"
				cost_time=-3
				throughput=-3
				insert_sql="insert into ${result_table} (commit_date_time,test_date_time,commit_id,author,ts_type,data_type,op_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,walFileSize,avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}','${data_type}','${op_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${walFileSize},${avgCPULoad},${maxCPULoad},${maxDiskIOSizeRead},${maxDiskIOSizeWrite},${maxDiskIOOpsRead},${maxDiskIOOpsWrite},'${protocol_class_input}')"
				mysql_exec "${insert_sql}"
				continue
			fi
			mv_config_file "${op_type}"
			for (( m = 1; m <= 1; m++ ))
			do
				#op_type=${m}_${query_list[${j}]}
				start_benchmark
				start_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
				m_start_time=$(date +%s)
				#等待1分钟
				sleep 10
				monitor_test_status
				m_end_time=$(date +%s)
				#收集启动后基础监控数据
				collect_monitor_data "${TEST_IP}"
				#测试结果收集写入数据库
				parse_benchmark_result "${query_type[${j}]}"
				cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
				insert_sql="insert into ${result_table} (commit_date_time,test_date_time,commit_id,author,ts_type,data_type,op_type,okPoint,okOperation,failPoint,failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,walFileSize,avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark) values(${commit_date_time},${test_date_time},'${commit_id}','${author}','${ts_type}','${data_type}','${op_type}',${okPoint},${okOperation},${failPoint},${failOperation},${throughput},${Latency},${MIN},${P10},${P25},${MEDIAN},${P75},${P90},${P95},${P99},${P999},${MAX},${numOfSe0Level},'${start_time}','${end_time}',${cost_time},${numOfUnse0Level},${dataFileSize},${maxNumofOpenFiles},${maxNumofThread},${walFileSize},${avgCPULoad},${maxCPULoad},${maxDiskIOSizeRead},${maxDiskIOSizeWrite},${maxDiskIOOpsRead},${maxDiskIOOpsWrite},'${protocol_class_input}')"
				log ${commit_id}版本${ts_type}类型${data_type}数据${op_type}查询${okPoint}数据点的耗时为：${Latency}ms
				mysql_exec "${insert_sql}"
			done
			#停止IoTDB程序和监控程序
			stop_iotdb
			sleep 30
            check_iotdb_pid
		done
		backup_test_data "${data_type}" "${protocol_class_input}"
		log "本轮${query_data_type[${j}]}时间序列查询测试已结束."
	done
}
##准备开始测试
# 功能：校验运行环境并编排当前脚本的完整测试流程
main() {
	ensure_runtime_dependencies
	check_password
	check_benchmark_version
	mkdir -p "${INIT_PATH}"
	trap restore_test_type_file EXIT
	echo "ontesting" > "${INIT_PATH}/test_type_file"
init_routine_route
query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${TEST_TYPE} = 'retest' and ${AUTHOR_FILTER_SQL} ORDER BY commit_date_time desc limit 1 "
result_string=$(mysql_exec "${query_sql}")
commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
##查询是否有复测任务
if [ "${commit_id}" = "" ]; then
	query_sql="SELECT commit_id,',',author,',',commit_date_time,',' FROM ${TASK_TABLENAME} WHERE ${TEST_TYPE} is NULL and ${AUTHOR_FILTER_SQL} ORDER BY commit_date_time desc limit 1 "
	result_string=$(mysql_exec "${query_sql}")
	commit_id=$(echo $result_string| awk -F, '{print $4}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
	author=$(echo $result_string| awk -F, '{print $5}' | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
	commit_date_time=$(echo $result_string | awk -F, '{print $6}' | sed s/-//g | sed s/://g | sed s/[[:space:]]//g | awk '{sub(/^ */, "");sub(/ *$/, "")}1')
fi
if [ "${commit_id}" = "" ]; then
	sleep 60s
else
	update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'ontesting' where commit_id = '${commit_id}'"
	mysql_exec "${update_sql}"
	log "当前版本${commit_id}未执行过测试，即将编译后启动"
	init_items
	test_date_time=$(date +%Y%m%d%H%M%S)
	p_index=$(($RANDOM % ${#protocol_list[*]}))
	t_index=$(($RANDOM % ${#ts_list[*]}))	
	#echo "开始测试${protocol_list[$p_index]}协议下的${ts_list[$t_index]}时间序列！"
	#test_operation ${protocol_list[$p_index]} ${ts_list[$t_index]}
	test_operation 223 
	#test_operation 222 
	#test_operation 111 
	#test_operation 211 
	###############################测试完成###############################
	log "本轮测试${test_date_time}已结束."
	update_sql="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'done' where commit_id = '${commit_id}'"
	mysql_exec "${update_sql}"
	update_sql02="update ${TASK_TABLENAME} set ${TEST_TYPE} = 'skip' where ${TEST_TYPE} is NULL and ${AUTHOR_FILTER_SQL} and commit_date_time < '${commit_date_time}'"
	mysql_exec "${update_sql02}"
fi
}

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/runtime_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/monitor_common.sh"

main "$@"
