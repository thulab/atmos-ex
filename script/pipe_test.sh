#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
	exec bash "$0" "$@"
fi
if shopt -oq posix; then
	exec bash "${BASH_SOURCE[0]}" "$@"
fi

set -o pipefail
#登录用户名
ACCOUNT=root
IoTDB_PW=TimechoDB@2021
test_type=pipe_test
#初始环境存放路径
INIT_PATH=/data/atmos/zk_test
ATMOS_PATH=${INIT_PATH}/atmos-ex
BM_PATH=${INIT_PATH}/iot-benchmark
BUCKUP_PATH=/nasdata/repository/pipe_test
REPOS_PATH=/nasdata/repository/master
#测试数据运行路径
TEST_INIT_PATH=${INIT_PATH}/first-rest-test
TEST_IOTDB_PATH=${TEST_INIT_PATH}/apache-iotdb
TEST_BM_PATH=${TEST_INIT_PATH}/iot-benchmark
# 1. org.apache.iotdb.consensus.simple.SimpleConsensus
# 2. org.apache.iotdb.consensus.ratis.RatisConsensus
# 3. org.apache.iotdb.consensus.iot.IoTConsensus
# 4. org.apache.iotdb.consensus.iot.IoTConsensusV2
protocol_class=(0 org.apache.iotdb.consensus.simple.SimpleConsensus org.apache.iotdb.consensus.ratis.RatisConsensus org.apache.iotdb.consensus.iot.IoTConsensus org.apache.iotdb.consensus.iot.IoTConsensusV2)
IP_list=(0 11.101.17.144 11.101.17.146)
PIPE_list=(0 11.101.17.146 11.101.17.144)
config_node_config_nodes=(0 11.101.17.144:10710 11.101.17.146:10710)
data_node_config_nodes=(0 11.101.17.144:10710 11.101.17.146:10710)
############mysql信息##########################
MYSQLHOSTNAME="111.200.37.158" #数据库信息
PORT="13306"
USERNAME="iotdbatm"
PASSWORD="${ATMOS_DB_PASSWORD:-}"
DBNAME="QA_ATM"  #数据库名称
TABLENAME="ex_pipe_test" #数据库中表的名称
TABLENAME_T="ex_pipe_test_T" #企业版结果表名
TASK_TABLENAME="ex_commit_history" #数据库中任务表的名称
############prometheus##########################
metric_server="111.200.37.158:19090"
readonly MONITOR_POLL_INTERVAL_SECONDS=10
readonly SSH_CONNECT_TIMEOUT_SECONDS=10
readonly SSH_RETRIES=3
readonly IOTDB_READY_RETRIES=51
readonly IOTDB_READY_INTERVAL_SECONDS=3
readonly SYNC_STABLE_SECONDS=600
readonly TEST_TIMEOUT_SECONDS=3600
readonly DEFAULT_DISK_ID="sdb"
readonly -a SSH_OPTIONS=(
	-o BatchMode=yes
	-o ConnectTimeout="${SSH_CONNECT_TIMEOUT_SECONDS}"
	-o ServerAliveInterval=15
	-o ServerAliveCountMax=3
)
task_claimed=false
task_completed=false
############公用函数##########################
if [ "${PASSWORD}" = "" ]; then
echo "需要关注密码设置！"
fi
#echo "Started at: " date -d today +"%Y-%m-%d %H:%M:%S"
echo "检查iot-benchmark版本"
BM_REPOS_PATH=/nasdata/repository/iot-benchmark
log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
	log "ERROR: $*"
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

ensure_runtime_dependencies() {
	local cmd
	for cmd in awk cp curl date find grep jq mkdir mysql rm scp sed sleep ssh sudo; do
		require_command "${cmd}"
	done
}

check_password() {
	[ -n "${PASSWORD}" ] || die "ATMOS_DB_PASSWORD is not set, cannot connect to MySQL."
}

mysql_exec() {
	local sql="$1"
	MYSQL_PWD="${PASSWORD}" mysql -h"${MYSQLHOSTNAME}" -P"${PORT}" -u"${USERNAME}" "${DBNAME}" -e "${sql}"
}

mysql_query() {
	local sql="$1"
	MYSQL_PWD="${PASSWORD}" mysql -N -B -h"${MYSQLHOSTNAME}" -P"${PORT}" -u"${USERNAME}" "${DBNAME}" -e "${sql}"
}

update_task_status() {
	local status="$1"
	mysql_exec "update ${TASK_TABLENAME} set ${test_type} = $(sql_quote "${status}") where commit_id = $(sql_quote "${commit_id}")"
}

remote_exec() {
	local ip="$1"
	shift
	local attempt
	for ((attempt = 1; attempt <= SSH_RETRIES; attempt++)); do
		if ssh "${SSH_OPTIONS[@]}" "${ACCOUNT}@${ip}" "$@"; then
			return 0
		fi
		log "remote command failed: node=${ip}, attempt=${attempt}/${SSH_RETRIES}"
		sleep 2
	done
	return 1
}

copy_to_remote() {
	local source="$1" ip="$2" target="$3"
	scp "${SSH_OPTIONS[@]}" -r -- "${source}" "${ACCOUNT}@${ip}:${target}"
}

copy_from_remote() {
	local ip="$1" source="$2" target="$3"
	scp "${SSH_OPTIONS[@]}" -r -- "${ACCOUNT}@${ip}:${source}" "${target}"
}

path_is_safe() {
	local path="$1"
	case "${path}" in
		"${TEST_INIT_PATH}"|"${TEST_INIT_PATH}"/*|"${BUCKUP_PATH}"/*|"${BM_PATH}"|"${BM_PATH}"/*)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

safe_rm() {
	local path="$1"
	[ -e "${path}" ] || return 0
	path_is_safe "${path}" || die "refuse to remove unsafe path: ${path}"
	rm -rf -- "${path}"
}

sudo_safe_rm() {
	local path="$1"
	[ -e "${path}" ] || return 0
	path_is_safe "${path}" || die "refuse to remove unsafe path: ${path}"
	sudo rm -rf -- "${path}"
}

restore_test_type_file() {
	printf '%s\n' "${test_type}" > "${INIT_PATH}/test_type_file"
}

stop_remote_iotdb_nodes() {
	local ip
	for ip in "${IP_list[@]:1}"; do
		remote_exec "${ip}" \
			"${TEST_IOTDB_PATH}/sbin/stop-datanode.sh >/dev/null 2>&1; ${TEST_IOTDB_PATH}/sbin/stop-confignode.sh >/dev/null 2>&1" \
			>/dev/null 2>&1 || true
	done
}

stop_remote_benchmarks() {
	local ip
	for ip in "${IP_list[@]:1}"; do
		remote_exec "${ip}" "jps | awk '\$2 == \"App\" {print \$1}' | xargs -r kill -9" >/dev/null 2>&1 || true
	done
}

cleanup() {
	local exit_code="$1"
	trap - EXIT
	restore_test_type_file
	if [ "${task_claimed}" = true ] && [ "${task_completed}" != true ]; then
		log "test interrupted or failed, mark commit ${commit_id} as error"
		stop_remote_benchmarks
		stop_remote_iotdb_nodes
		update_task_status "error" || log "failed to update task status for ${commit_id}"
	fi
	return "${exit_code}"
}

sql_quote() {
	local value="${1:-}"
	value="${value//\\/\\\\}"
	value="$(printf '%s' "${value}" | sed "s/'/''/g")"
	printf "'%s'" "${value}"
}

set_property() {
	local file="$1" key="$2" value="$3"
	local escaped_key
	escaped_key=$(printf '%s' "${key}" | sed 's/[][\\.^$*+?{}|()]/\\&/g')
	sed -i "/^[#[:space:]]*${escaped_key}=/d" "${file}"
	printf '%s=%s\n' "${key}" "${value}" >> "${file}"
}

reset_operation_metrics() {
	start_time=""
	end_time=""
	cost_time=0
	wait_time=0
	failPointA=0
	okOperationA=0 okPointA=0 failOperationA=0
	throughputA=0
	LatencyA=0
	failPointB=0
	okOperationB=0 okPointB=0 failOperationB=0
	throughputB=0
	LatencyB=0
	MIN=0 P10=0 P25=0 MEDIAN=0 P75=0 P90=0 P95=0 P99=0 P999=0 MAX=0
	numOfSe0LevelA=0 numOfUnse0LevelA=0 dataFileSizeA=0
	maxNumofOpenFilesA=0 maxNumofThreadA=0 walFileSizeA=0 errorLogSizeA=0
	numOfSe0LevelB=0 numOfUnse0LevelB=0 dataFileSizeB=0
	maxNumofOpenFilesB=0 maxNumofThreadB=0 walFileSizeB=0 errorLogSizeB=0
	maxCPULoadA=0 avgCPULoadA=0 maxDiskIOOpsReadA=0 maxDiskIOOpsWriteA=0 maxDiskIOSizeReadA=0 maxDiskIOSizeWriteA=0
	maxCPULoadB=0 avgCPULoadB=0 maxDiskIOOpsReadB=0 maxDiskIOOpsWriteB=0 maxDiskIOSizeReadB=0 maxDiskIOSizeWriteB=0
	minPointNum=1000000
}

git_commit_abbrev() {
	local properties="$1/git.properties"
	[ -f "${properties}" ] || return 0
	awk -F= '$1 == "git.commit.id.abbrev" { print $2; exit }' "${properties}"
}

sync_benchmark_path() {
	local new_commit old_commit
	new_commit="$(git_commit_abbrev "${BM_REPOS_PATH}")"
	old_commit="$(git_commit_abbrev "${BM_PATH}")"
	[ -n "${new_commit}" ] || die "benchmark repository is invalid: ${BM_REPOS_PATH}"
	if [ "${old_commit}" != "${new_commit}" ]; then
		log "sync benchmark ${old_commit:-missing} -> ${new_commit}"
		safe_rm "${BM_PATH}"
		cp -rf -- "${BM_REPOS_PATH}" "${BM_PATH}"
	fi
}
init_items() {
############定义监控采集项初始值##########################
test_date_time=0
ts_type=0
start_time=0
end_time=0
cost_time=0
wait_time=0
failPointA=0
throughputA=0
LatencyA=0
numOfSe0LevelA=0
numOfUnse0LevelA=0
dataFileSizeA=0
maxNumofOpenFilesA=0
maxNumofThreadA=0
walFileSizeA=0
errorLogSizeA=0
failPointB=0
throughputB=0
LatencyB=0
numOfSe0LevelB=0
numOfUnse0LevelB=0
dataFileSizeB=0
maxNumofOpenFilesB=0
maxNumofThreadB=0
walFileSizeB=0
errorLogSizeB=0
maxCPULoadA=0
avgCPULoadA=0
maxDiskIOOpsReadA=0
maxDiskIOOpsWriteA=0
maxDiskIOSizeReadA=0
maxDiskIOSizeWriteA=0
maxCPULoadB=0
avgCPULoadB=0
maxDiskIOOpsReadB=0
maxDiskIOOpsWriteB=0
maxDiskIOSizeReadB=0
maxDiskIOSizeWriteB=0
minPointNum=1000000
############定义监控采集项初始值##########################
pipflag=0
}
set_env() { # 拷贝编译好的iotdb到测试路径
	if [ ! -d "${TEST_INIT_PATH}" ]; then
		mkdir -p "${TEST_IOTDB_PATH}"
	else
		safe_rm "${TEST_INIT_PATH}"
		mkdir -p "${TEST_IOTDB_PATH}"
	fi
	cp -rf "${REPOS_PATH}/${commit_id}/apache-iotdb/." "${TEST_IOTDB_PATH}/"
	mkdir -p "${TEST_IOTDB_PATH}/activation"
	cp -rf "${BM_PATH}" "${TEST_INIT_PATH}/"
}
modify_iotdb_config() { # iotdb调整内存，关闭合并
	#修改IoTDB的配置
	local properties="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"20G\"/g" "${TEST_IOTDB_PATH}/conf/datanode-env.sh"
	sed -i "s/^#ON_HEAP_MEMORY=\"2G\".*$/ON_HEAP_MEMORY=\"6G\"/g" "${TEST_IOTDB_PATH}/conf/confignode-env.sh"
	#清空配置文件
	# echo "只保留要修改的参数" > ${TEST_IOTDB_PATH}/conf/iotdb-system.properties
	set_property "${properties}" query_timeout_threshold 6000000
	#关闭影响写入性能的其他功能
	set_property "${properties}" enable_seq_space_compaction false
	set_property "${properties}" enable_unseq_space_compaction false
	set_property "${properties}" enable_cross_space_compaction false
	#修改集群名称
	set_property "${properties}" cluster_name "${test_type}"
	#开启自动创建
	set_property "${properties}" enable_auto_create_schema true
	set_property "${properties}" default_storage_group_level 2
	#添加启动监控功能
	set_property "${properties}" cn_enable_metric true
	set_property "${properties}" cn_enable_performance_stat true
	set_property "${properties}" cn_metric_reporter_list PROMETHEUS
	set_property "${properties}" cn_metric_level ALL
	set_property "${properties}" cn_metric_prometheus_reporter_port 9081
	#添加启动监控功能
	set_property "${properties}" dn_enable_metric true
	set_property "${properties}" dn_enable_performance_stat true
	set_property "${properties}" dn_metric_reporter_list PROMETHEUS
	set_property "${properties}" dn_metric_level ALL
	set_property "${properties}" dn_metric_prometheus_reporter_port 9091
}
set_protocol_class() { 
	local config_node="$1"
	local schema_region="$2"
	local data_region="$3"
	local properties="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	#设置协议
	set_property "${properties}" config_node_consensus_protocol_class "${protocol_class[${config_node}]}"
	set_property "${properties}" schema_region_consensus_protocol_class "${protocol_class[${schema_region}]}"
	set_property "${properties}" data_region_consensus_protocol_class "${protocol_class[${data_region}]}"
}

pipe_is_ready() {
	local output="$1"
	grep -Eq '(^|[|[:space:]])test([|[:space:]]|$)' <<<"${output}" &&
		grep -q 'RUNNING' <<<"${output}" &&
		! grep -Eq 'ERROR|STOPPED' <<<"${output}"
}

setup_env() {
	echo "开始重置环境！"
	for (( j = 1; j < ${#IP_list[*]}; j++ ))
	do
		TEST_IP=${IP_list[$j]}
		remote_exec "${TEST_IP}" "sudo reboot" || log "reboot command disconnected as expected: node=${TEST_IP}"
	done
	sleep 120
	for (( i = 1; i < ${#IP_list[*]}; i++ ))
	do
		echo "开始部署${IP_list[$i]}！"
		TEST_IP=${IP_list[$i]}
		echo "setting env to ${TEST_IP} ..."
		#删除原有路径下所有
		remote_exec "${TEST_IP}" "case '${TEST_INIT_PATH}' in /data/atmos/zk_test/*) rm -rf -- '${TEST_INIT_PATH}' ;; *) exit 2 ;; esac" || return 1
		remote_exec "${TEST_IP}" "mkdir -p -- '${TEST_INIT_PATH}'" || return 1
		#修改IoTDB的配置		
		set_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" dn_rpc_address "${TEST_IP}"
		set_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" dn_internal_address "${TEST_IP}"
		set_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" dn_seed_config_node "${data_node_config_nodes[$i]}"
		set_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" cn_internal_address "${TEST_IP}"
		set_property "${TEST_IOTDB_PATH}/conf/iotdb-system.properties" cn_seed_config_node "${config_node_config_nodes[$i]}"
		#准备配置文件和license
		mv_config_file ${ts_type} ${TEST_IP}
		#sed -i "s/^HOST=.*$/HOST=${TEST_IP}/g" ${TEST_BM_PATH}/conf/config.properties
		safe_rm "${TEST_INIT_PATH}/apache-iotdb/activation"
		mkdir -p "${TEST_INIT_PATH}/apache-iotdb/activation"
		cp -rf "${ATMOS_PATH}/conf/${test_type}/${TEST_IP}" "${TEST_INIT_PATH}/apache-iotdb/activation/license"
		cp -rf "${ATMOS_PATH}/conf/${test_type}/env_${TEST_IP}" "${TEST_INIT_PATH}/apache-iotdb/.env"
		#复制三项到客户机
		copy_to_remote "${TEST_INIT_PATH}/." "${TEST_IP}" "${TEST_INIT_PATH}/" || return 1
		#scp -r ${TEST_INIT_PATH}/* ${ACCOUNT}@${TEST_IP}:${TEST_INIT_PATH}/  > /dev/null 2>&1 &
	done	
	sleep 3
	for (( i = 1; i < ${#IP_list[*]}; i++ ))
	do
		TEST_IP=${IP_list[$i]}
		flag=0
		#启动ConfigNode节点
		echo "starting IoTDB ConfigNode on ${TEST_IP} ..."
		remote_exec "${TEST_IP}" "${TEST_IOTDB_PATH}/sbin/start-confignode.sh > /dev/null 2>&1 &" || return 1
		#主节点需要先启动，所以等待10秒是为了保证主节点启动完毕
		sleep 5
		#启动DataNode节点
		echo "starting IoTDB DataNode on ${TEST_IP} ..."
		remote_exec "${TEST_IP}" "${TEST_IOTDB_PATH}/sbin/start-datanode.sh -H ${TEST_IOTDB_PATH}/dn_dump.hprof > /dev/null 2>&1 &" || return 1
		#等待60s，让服务器完成前期准备
		sleep 10
		for (( t_wait = 1; t_wait <= IOTDB_READY_RETRIES; t_wait++ ))
		do
		  str1=$(remote_exec "${TEST_IP}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -h ${TEST_IP} -p 6667 -e \"show cluster\" | grep 'Total line number = 2'" 2>/dev/null || true)
		  if [ "$str1" = "Total line number = 2" ]; then
			echo "All Nodes is ready"
			flag=1
			remote_exec "${TEST_IP}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -h ${TEST_IP} -p 6667 -e \"ALTER USER root SET PASSWORD '${IoTDB_PW}';\"" >/dev/null || return 1
			break
		  else
			echo "All Nodes is not ready.Please wait ..."
			sleep "${IOTDB_READY_INTERVAL_SECONDS}"
			continue
		  fi
		done
		if [ "${flag}" -ne 1 ]; then
		  echo "All Nodes is not ready!"
		  return 1
		fi
	done
	sleep 3
	if [ "${ts_type}" = "tablemode" ]; then
		for (( i = 1; i < ${#IP_list[*]}; i++ ))
		do
			TEST_IP=${IP_list[$i]}
			remote_exec "${TEST_IP}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -sql_dialect table -h ${TEST_IP} -p 6667 -e \"create pipe test with source ('source.realtime.mode'='stream','source.realtime.enable'='true','source.forwarding-pipe-requests'='false','source.batch.enable'='true','source.history.enable'='true') with sink ('sink'='iotdb-thrift-sink','username'='root','password'='${IoTDB_PW}', 'sink.node-urls'='${PIPE_list[$i]}:6667');\"" || return 1
			sleep 3
			remote_exec "${TEST_IP}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -sql_dialect table -h ${TEST_IP} -p 6667 -e \"start pipe test;\"" || return 1
			str1=$(remote_exec "${TEST_IP}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -sql_dialect table -h ${TEST_IP} -p 6667 -e \"show pipes;\"" 2>/dev/null || true)
			if pipe_is_ready "${str1}"; then
				echo "PIPE is ready"
				((pipflag++))
			else
				log "pipe is not ready: node=${TEST_IP}, dialect=table"
			fi
		done
	else
		for (( i = 1; i < ${#IP_list[*]}; i++ ))
		do
			TEST_IP=${IP_list[$i]}
			remote_exec "${TEST_IP}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -h ${TEST_IP} -p 6667 -e \"create pipe test with source ('source.pattern'='root', 'source.realtime.mode'='stream','source.realtime.enable'='true','source.forwarding-pipe-requests'='false','source.batch.enable'='true','source.history.enable'='true') with sink ('sink'='iotdb-thrift-sink', 'username'='root','password'='${IoTDB_PW}', 'sink.node-urls'='${PIPE_list[$i]}:6667');\"" || return 1
			sleep 3
			remote_exec "${TEST_IP}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -h ${TEST_IP} -p 6667 -e \"start pipe test;\"" || return 1
			str1=$(remote_exec "${TEST_IP}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -h ${TEST_IP} -p 6667 -e \"show pipes;\"" 2>/dev/null || true)
			if pipe_is_ready "${str1}"; then
				echo "PIPE is ready"
				((pipflag++))
			else
				log "pipe is not ready: node=${TEST_IP}, dialect=tree"
			fi
		done
	fi
	echo $pipflag
}
monitor_test_status() { # 监控测试运行状态，获取最大打开文件数量和最大线程数
	local last_update_time
	last_update_time=$(date '+%Y-%m-%d %H:%M:%S')
	for (( device = 0; device < 50; device++ ))
	do
		numOfPointsA[${device}]=0
		numOfPointsB[${device}]=0
	done
	while true; do
		now_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
		t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${start_time}")))
		flagBM=0
		for (( m = 1; m <= 2; m++ ))
		do
			if [ "${t_time}" -ge "${TEST_TIMEOUT_SECONDS}" ]; then
				echo "测试失败"  #倒序输入形成负数结果
				end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
				flagBM=-1
				cost_time=-1
				break
			fi
			str1=$(remote_exec "${IP_list[${m}]}" "jps | grep -w App | grep -v grep | wc -l" 2>/dev/null || true)
			if [ "$str1" = "1" ]; then
				echo "BM写入未结束:${IP_list[${m}]}"  > /dev/null 2>&1 &
			else
				echo "BM写入已结束:${IP_list[${m}]}"
				((flagBM++))
			fi
		done
		if [ $flagBM -ge 2 ]; then
			if [ "${ts_type}" = "tablemode" ]; then
				remote_exec "${IP_list[1]}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -sql_dialect table -h ${IP_list[1]} -p 6667 -e \"flush\"" >/dev/null || true
				remote_exec "${IP_list[2]}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -sql_dialect table -h ${IP_list[2]} -p 6667 -e \"flush\"" >/dev/null || true
			else
				remote_exec "${IP_list[1]}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -h ${IP_list[1]} -p 6667 -e \"flush\"" >/dev/null || true
				remote_exec "${IP_list[2]}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -h ${IP_list[2]} -p 6667 -e \"flush\"" >/dev/null || true
			fi
			#BM写入结束前不进行判定
			#确认是否测试已结束
			flagA=0
			flagB=0
			for (( device = 0; device < 50; device++ ))
			do
				if [ "${ts_type}" = "tablemode" ]; then
					str1=$(remote_exec "${IP_list[1]}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -sql_dialect table -h ${IP_list[1]} -p 6667 -e \"select count(s_0) from test_g_0.table_0 where device_id = 'd_${device}'\" | sed -n '4p' | sed s/\|//g | sed 's/[[:space:]]//g'" 2>/dev/null || echo 0)
					if [[ "${numOfPointsA[${device}]}" == "$str1" ]]; then
						((flagA++))
					else
						numOfPointsA[${device}]=$str1
						last_update_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
					fi
					str2=$(remote_exec "${IP_list[2]}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -sql_dialect table -h ${IP_list[2]} -p 6667 -e \"select count(s_0) from test_g_0.table_0 where device_id = 'd_${device}'\" | sed -n '4p' | sed s/\|//g | sed 's/[[:space:]]//g'" 2>/dev/null || echo 0)
					if [[ "${numOfPointsB[${device}]}" == "$str2" ]]; then
						((flagB++))
					else
						numOfPointsB[${device}]=$str2
						last_update_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
					fi
				else
					str1=$(remote_exec "${IP_list[1]}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -h ${IP_list[1]} -p 6667 -e \"select count(s_0) from root.test.g_0.d_${device}\" | sed -n '4p' | sed s/\|//g | sed 's/[[:space:]]//g'" 2>/dev/null || echo 0)
					if [[ "${numOfPointsA[${device}]}" == "$str1" ]]; then
						((flagA++))
					else
						numOfPointsA[${device}]=$str1
						last_update_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
					fi
					str2=$(remote_exec "${IP_list[2]}" "${TEST_IOTDB_PATH}/sbin/start-cli.sh -u root -pw ${IoTDB_PW} -h ${IP_list[2]} -p 6667 -e \"select count(s_0) from root.test.g_0.d_${device}\" | sed -n '4p' | sed s/\|//g | sed 's/[[:space:]]//g'" 2>/dev/null || echo 0)
					if [[ "${numOfPointsB[${device}]}" == "$str2" ]]; then
						((flagB++))
					else
						numOfPointsB[${device}]=$str2
						last_update_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
					fi
				fi
				#echo "flagA=${flagA}"
				#echo "flagB=${flagB}"
				#echo "numOfPointsA=${numOfPointsA}"
				#echo "numOfPointsB=${numOfPointsB}"
				#echo "last_update_time=${last_update_time}"
			done
			t_time=$(($(date +%s -d "${now_time}") - $(date +%s -d "${last_update_time}")))
			if [ "${t_time}" -ge "${SYNC_STABLE_SECONDS}" ]; then
				echo "10分钟无数据更新同步，结束等待"  #倒序输入形成负数结果
				end_time=$(date -d today +"%Y-%m-%d %H:%M:%S")
				cost_time=$(($(date +%s -d "${last_update_time}") - $(date +%s -d "${start_time}")))
				minPointNum=1000000
				for (( device = 0; device < 50; device++ ))
				do
					if [ $minPointNum -ge ${numOfPointsA[${device}]} ]; then
						minPointNum=${numOfPointsA[${device}]}
					fi
					if [ $minPointNum -ge ${numOfPointsB[${device}]} ]; then
						minPointNum=${numOfPointsB[${device}]}
					fi
				done
				break
			fi
		elif [ "$flagBM" = "-1" ]; then
			break
		fi
		sleep "${MONITOR_POLL_INTERVAL_SECONDS}"
	done
}
bytes_to_gib() {
	awk -v bytes="${1:-0}" 'BEGIN { printf "%.2f\n", bytes / 1073741824 }'
}

find_result_csv() {
	local directory="$1"
	find "${directory}" -maxdepth 1 -type f -name '*result.csv' -print -quit 2>/dev/null
}

parse_benchmark_result() {
	local csv_file="$1" suffix="$2"
	local summary latency
	local ok_operation ok_point fail_operation fail_point throughput_value latency_value
	local min p10 p25 median p75 p90 p95 p99 p999 max

	summary=$(awk -F, '$1 ~ /^INGESTION/ {print $2,$3,$4,$5,$6; exit}' "${csv_file}")
	latency=$(awk -F, '$1 ~ /^INGESTION/ {count++; if (count == 2) {print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12; exit}}' "${csv_file}")
	[ -n "${summary}" ] && [ -n "${latency}" ] || return 1
	read -r ok_operation ok_point fail_operation fail_point throughput_value <<<"${summary}"
	read -r latency_value min p10 p25 median p75 p90 p95 p99 p999 max <<<"${latency}"
	printf -v "okOperation${suffix}" '%s' "${ok_operation:-0}"
	printf -v "okPoint${suffix}" '%s' "${ok_point:-0}"
	printf -v "failOperation${suffix}" '%s' "${fail_operation:-0}"
	printf -v "failPoint${suffix}" '%s' "${fail_point:-0}"
	printf -v "throughput${suffix}" '%s' "${throughput_value:-0}"
	printf -v "Latency${suffix}" '%s' "${latency_value:-0}"
	MIN="${min:-0}" P10="${p10:-0}" P25="${p25:-0}" MEDIAN="${median:-0}"
	P75="${p75:-0}" P90="${p90:-0}" P95="${p95:-0}" P99="${p99:-0}" P999="${p999:-0}" MAX="${max:-0}"
}

get_single_index() {
    # 获取 prometheus 单个指标的值
	local query="$1"
	local end="$2"
	local url="http://${metric_server}/api/v1/query"
	local index_value
	index_value=$(curl -GfsS "${url}" \
		--data-urlencode "query=${query}" \
		--data-urlencode "time=${end}" |
		jq -r '.data.result[0].value[1] // 0') || index_value=0
	printf '%s\n' "${index_value}"
}
collect_monitor_data_legacy() { # 收集iotdb数据大小，顺、乱序文件数量
	dataFileSizeA=0
	numOfSe0LevelA=0
	numOfUnse0LevelA=0
	dataFileSizeB=0
	numOfSe0LevelB=0
	numOfUnse0LevelB=0
	maxNumofOpenFilesA=0
	maxNumofThreadA=0
	maxNumofOpenFilesB=0
	maxNumofThreadB=0
	walFileSizeA=0
	walFileSizeB=0
	maxCPULoadA=0
	avgCPULoadA=0
	maxDiskIOOpsReadA=0
	maxDiskIOOpsWriteA=0
	maxDiskIOSizeReadA=0
	maxDiskIOSizeWriteA=0
	maxCPULoadB=0
	avgCPULoadB=0
	maxDiskIOOpsReadB=0
	maxDiskIOOpsWriteB=0
	maxDiskIOSizeReadB=0
	maxDiskIOSizeWriteB=0
	for (( j = 1; j < ${#IP_list[*]}; j++ ))
	do
		TEST_IP=${IP_list[$j]}	
		if [ $j -eq 1 ]; then
			#调用监控获取数值
			dataFileSizeA=$(get_single_index "sum(file_global_size{instance=~\"${TEST_IP}:9091\"})" $m_end_time)
			dataFileSizeA=$(bytes_to_gib "${dataFileSizeA}")
			numOfSe0LevelA=$(get_single_index "sum(file_global_count{instance=~\"${TEST_IP}:9091\",name=\"seq\"})" $m_end_time)
			numOfUnse0LevelA=$(get_single_index "sum(file_global_count{instance=~\"${TEST_IP}:9091\",name=\"unseq\"})" $m_end_time)
			maxNumofThreadA_C=$(get_single_index "max_over_time(process_threads_count{instance=~\"${TEST_IP}:9081\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxNumofThreadA_D=$(get_single_index "max_over_time(process_threads_count{instance=~\"${TEST_IP}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			let maxNumofThreadA=${maxNumofThreadA_C}+${maxNumofThreadA_D}
			maxNumofOpenFilesA=$(get_single_index "max_over_time(file_count{instance=~\"${TEST_IP}:9091\",name=\"open_file_handlers\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			walFileSizeA=$(get_single_index "max_over_time(file_size{instance=~\"${TEST_IP}:9091\",name=~\"wal\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			walFileSizeA=$(bytes_to_gib "${walFileSizeA}")
			maxCPULoadA=$(get_single_index "max_over_time(sys_cpu_load{instance=~\"${TEST_IP}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			avgCPULoadA=$(get_single_index "avg_over_time(sys_cpu_load{instance=~\"${TEST_IP}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxDiskIOOpsReadA=$(get_single_index "rate(disk_io_ops{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"read\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxDiskIOOpsWriteA=$(get_single_index "rate(disk_io_ops{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"write\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxDiskIOSizeReadA=$(get_single_index "rate(disk_io_size{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"read\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxDiskIOSizeWriteA=$(get_single_index "rate(disk_io_size{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"write\"}[$((m_end_time-m_start_time))s])" $m_end_time)
		else
			#调用监控获取数值
			dataFileSizeB=$(get_single_index "sum(file_global_size{instance=~\"${TEST_IP}:9091\"})" $m_end_time)
			dataFileSizeB=$(bytes_to_gib "${dataFileSizeB}")
			numOfSe0LevelB=$(get_single_index "sum(file_global_count{instance=~\"${TEST_IP}:9091\",name=\"seq\"})" $m_end_time)
			numOfUnse0LevelB=$(get_single_index "sum(file_global_count{instance=~\"${TEST_IP}:9091\",name=\"unseq\"})" $m_end_time)
			maxNumofThreadB_C=$(get_single_index "max_over_time(process_threads_count{instance=~\"${TEST_IP}:9081\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxNumofThreadB_D=$(get_single_index "max_over_time(process_threads_count{instance=~\"${TEST_IP}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			let maxNumofThreadB=${maxNumofThreadB_C}+${maxNumofThreadB_D}
			maxNumofOpenFilesB=$(get_single_index "max_over_time(file_count{instance=~\"${TEST_IP}:9091\",name=\"open_file_handlers\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			walFileSizeB=$(get_single_index "max_over_time(file_size{instance=~\"${TEST_IP}:9091\",name=~\"wal\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			walFileSizeB=$(bytes_to_gib "${walFileSizeB}")
			maxCPULoadB=$(get_single_index "max_over_time(sys_cpu_load{instance=~\"${TEST_IP}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			avgCPULoadB=$(get_single_index "avg_over_time(sys_cpu_load{instance=~\"${TEST_IP}:9091\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxDiskIOOpsReadB=$(get_single_index "rate(disk_io_ops{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"read\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxDiskIOOpsWriteB=$(get_single_index "rate(disk_io_ops{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"write\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxDiskIOSizeReadB=$(get_single_index "rate(disk_io_size{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"read\"}[$((m_end_time-m_start_time))s])" $m_end_time)
			maxDiskIOSizeWriteB=$(get_single_index "rate(disk_io_size{instance=~\"${TEST_IP}:9091\",disk_id=~\"sdb\",type=~\"write\"}[$((m_end_time-m_start_time))s])" $m_end_time)
		fi
	done
}
collect_node_metrics() {
	local suffix="$1" ip="$2"
	local range_seconds=$((m_end_time - m_start_time))
	local data_bytes wal_bytes cn_threads dn_threads value query
	[ "${range_seconds}" -gt 0 ] || range_seconds=1

	data_bytes=$(get_single_index "sum(file_global_size{instance=~\"${ip}:9091\"})" "${m_end_time}")
	printf -v "dataFileSize${suffix}" '%s' "$(bytes_to_gib "${data_bytes}")"
	value=$(get_single_index "sum(file_global_count{instance=~\"${ip}:9091\",name=\"seq\"})" "${m_end_time}")
	printf -v "numOfSe0Level${suffix}" '%s' "${value}"
	value=$(get_single_index "sum(file_global_count{instance=~\"${ip}:9091\",name=\"unseq\"})" "${m_end_time}")
	printf -v "numOfUnse0Level${suffix}" '%s' "${value}"
	cn_threads=$(get_single_index "max_over_time(process_threads_count{instance=~\"${ip}:9081\"}[${range_seconds}s])" "${m_end_time}")
	dn_threads=$(get_single_index "max_over_time(process_threads_count{instance=~\"${ip}:9091\"}[${range_seconds}s])" "${m_end_time}")
	printf -v "maxNumofThread${suffix}" '%.0f' "$(awk -v cn="${cn_threads}" -v dn="${dn_threads}" 'BEGIN {print cn + dn}')"
	value=$(get_single_index "max_over_time(file_count{instance=~\"${ip}:9091\",name=\"open_file_handlers\"}[${range_seconds}s])" "${m_end_time}")
	printf -v "maxNumofOpenFiles${suffix}" '%s' "${value}"
	wal_bytes=$(get_single_index "max_over_time(file_size{instance=~\"${ip}:9091\",name=~\"wal\"}[${range_seconds}s])" "${m_end_time}")
	printf -v "walFileSize${suffix}" '%s' "$(bytes_to_gib "${wal_bytes}")"
	for value in maxCPULoad avgCPULoad maxDiskIOOpsRead maxDiskIOOpsWrite maxDiskIOSizeRead maxDiskIOSizeWrite; do
		case "${value}" in
			maxCPULoad) query="max_over_time(sys_cpu_load{instance=~\"${ip}:9091\"}[${range_seconds}s])" ;;
			avgCPULoad) query="avg_over_time(sys_cpu_load{instance=~\"${ip}:9091\"}[${range_seconds}s])" ;;
			maxDiskIOOpsRead) query="rate(disk_io_ops{instance=~\"${ip}:9091\",disk_id=~\"${DEFAULT_DISK_ID}\",type=~\"read\"}[${range_seconds}s])" ;;
			maxDiskIOOpsWrite) query="rate(disk_io_ops{instance=~\"${ip}:9091\",disk_id=~\"${DEFAULT_DISK_ID}\",type=~\"write\"}[${range_seconds}s])" ;;
			maxDiskIOSizeRead) query="rate(disk_io_size{instance=~\"${ip}:9091\",disk_id=~\"${DEFAULT_DISK_ID}\",type=~\"read\"}[${range_seconds}s])" ;;
			maxDiskIOSizeWrite) query="rate(disk_io_size{instance=~\"${ip}:9091\",disk_id=~\"${DEFAULT_DISK_ID}\",type=~\"write\"}[${range_seconds}s])" ;;
		esac
		printf -v "${value}${suffix}" '%s' "$(get_single_index "${query}" "${m_end_time}")"
	done
}

collect_monitor_data() {
	collect_node_metrics A "${IP_list[1]}"
	collect_node_metrics B "${IP_list[2]}"
}

backup_test_data() { # 备份测试数据
	local backup_dir="${BUCKUP_PATH}/$1/${commit_date_time}_${commit_id}_${protocol_class}"
	sudo_safe_rm "${backup_dir}"
	sudo mkdir -p "${backup_dir}"
	for (( j = 1; j < ${#IP_list[*]}; j++ ))
	do
		TEST_IP=${IP_list[$j]}
		sudo mkdir -p "${backup_dir}/${TEST_IP}"
		remote_exec "${TEST_IP}" "rm -rf -- '${TEST_IOTDB_PATH}/data'" >/dev/null 2>&1 || true
		copy_from_remote "${TEST_IP}" "${TEST_IOTDB_PATH}/" "${backup_dir}/${TEST_IP}/" || log "backup copy failed: node=${TEST_IP}"
	done
	sudo cp -rf "${TEST_BM_PATH}/TestResult" "${backup_dir}/" || true
}
mv_config_file() { # 移动配置文件
	rm -f -- "${TEST_BM_PATH}/conf/config.properties"
	cp -f -- "${ATMOS_PATH}/conf/${test_type}/$1/$2" "${TEST_BM_PATH}/conf/config.properties"
}
test_operation() {
	local protocol_id="$1"
	protocol_class="${protocol_id}"
	ts_type="$2"
	reset_operation_metrics
	pipflag=0
	echo "开始测试${ts_type}时间序列！"
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
    elif [ "${protocol_class}" = "224" ]; then
        set_protocol_class 2 2 4
	else
		echo "协议设置错误！"
		return 1
	fi
	#启动iotdb
	if ! setup_env; then
		log "failed to start IoTDB cluster for protocol=${protocol_class}, ts_type=${ts_type}"
		return 1
	fi
	sleep 60
	#启动写入程序
	for (( j = 1; j < ${#IP_list[*]}; j++ ))
	do
		TEST_IP=${IP_list[$j]}
		echo "开始写入！"
		remote_exec "${TEST_IP}" "cd '${TEST_BM_PATH}' && '${TEST_BM_PATH}/benchmark.sh' > /dev/null 2>&1 &" || return 1
	done
	start_time=$(date '+%Y-%m-%d %H:%M:%S')
	m_start_time=$(date +%s)
	#等待1分钟
	sleep 10
	#判断PIPE设置情况
	if [ $pipflag -ge 2 ]; then
		monitor_test_status
	else
		#PIPE启动失败
		cost_time=-5
	fi
	#收集启动后基础监控数据
	m_end_time=$(date +%s)
	collect_monitor_data
	#测试结果收集写入数据库
	for (( j = 1; j < ${#IP_list[*]}; j++ ))
	do
		local result_dir="${TEST_BM_PATH}/TestResult/csvOutput"
		local csv_output_file suffix
		safe_rm "${result_dir}"
		mkdir -p "${result_dir}"
		if ! copy_from_remote "${IP_list[${j}]}" "${TEST_BM_PATH}/data/csvOutput/*result.csv" "${result_dir}/"; then
			log "failed to copy benchmark result: node=${IP_list[${j}]}"
			continue
		fi
		#收集启动后基础监控数据
		csv_output_file=$(find_result_csv "${result_dir}")
		[ -n "${csv_output_file}" ] || { log "benchmark result is missing: node=${IP_list[${j}]}"; continue; }
		if [ "${j}" -eq 1 ]; then suffix=A; else suffix=B; fi
		parse_benchmark_result "${csv_output_file}" "${suffix}" || log "invalid benchmark result: ${csv_output_file}"
	done	
	#cost_time=$(($(date +%s -d "${end_time}") - $(date +%s -d "${start_time}")))
	insert_sql="insert into ${TABLENAME} (commit_date_time,test_date_time,commit_id,author,ts_type,start_time,end_time,cost_time,wait_time,failPointA,throughputA,LatencyA,numOfSe0LevelA,numOfUnse0LevelA,dataFileSizeA,maxNumofOpenFilesA,maxNumofThreadA,walFileSizeA,avgCPULoadA,maxCPULoadA,maxDiskIOSizeReadA,maxDiskIOSizeWriteA,maxDiskIOOpsReadA,maxDiskIOOpsWriteA,errorLogSizeA,failPointB,throughputB,LatencyB,numOfSe0LevelB,numOfUnse0LevelB,dataFileSizeB,maxNumofOpenFilesB,maxNumofThreadB,walFileSizeB,avgCPULoadB,maxCPULoadB,maxDiskIOSizeReadB,maxDiskIOSizeWriteB,maxDiskIOOpsReadB,maxDiskIOOpsWriteB,errorLogSizeB,minPointNum,remark) values(${commit_date_time},${test_date_time},$(sql_quote "${commit_id}"),$(sql_quote "${author}"),$(sql_quote "${ts_type}"),$(sql_quote "${start_time}"),$(sql_quote "${end_time}"),${cost_time},${wait_time},${failPointA},${throughputA},${LatencyA},${numOfSe0LevelA},${numOfUnse0LevelA},${dataFileSizeA},${maxNumofOpenFilesA},${maxNumofThreadA},${walFileSizeA},${avgCPULoadA},${maxCPULoadA},${maxDiskIOSizeReadA},${maxDiskIOSizeWriteA},${maxDiskIOOpsReadA},${maxDiskIOOpsWriteA},${errorLogSizeA},${failPointB},${throughputB},${LatencyB},${numOfSe0LevelB},${numOfUnse0LevelB},${dataFileSizeB},${maxNumofOpenFilesB},${maxNumofThreadB},${walFileSizeB},${avgCPULoadB},${maxCPULoadB},${maxDiskIOSizeReadB},${maxDiskIOSizeWriteB},${maxDiskIOOpsReadB},${maxDiskIOOpsWriteB},${errorLogSizeB},${minPointNum},${protocol_class})"

	mysql_exec "${insert_sql}"
	for (( i = 1; i < ${#IP_list[*]}; i++ ))
	do
		TEST_IP=${IP_list[$i]}
		remote_exec "${TEST_IP}" "${TEST_IOTDB_PATH}/sbin/stop-datanode.sh >/dev/null 2>&1; ${TEST_IOTDB_PATH}/sbin/stop-confignode.sh >/dev/null 2>&1" || log "failed to stop IoTDB: node=${TEST_IP}"
	done
	#备份本次测试
	backup_test_data ${ts_type}
}
##准备开始测试
fetch_next_commit() {
	local status_filter="$1"
	local predicate row
	if [ "${status_filter}" = "retest" ]; then
		predicate="${test_type} = 'retest'"
	else
		predicate="${test_type} is NULL"
	fi
	row=$(mysql_query "SELECT commit_id, author, DATE_FORMAT(commit_date_time, '%Y%m%d%H%i%s') FROM ${TASK_TABLENAME} WHERE ${predicate} ORDER BY commit_date_time desc LIMIT 1") || return 1
	[ -n "${row}" ] || return 1
	IFS=$'\t' read -r commit_id author commit_date_time <<<"${row}"
	[ -n "${commit_id}" ]
}

main() {
	ensure_runtime_dependencies
	check_password
	sync_benchmark_path
	mkdir -p "${INIT_PATH}"
	trap 'cleanup $?' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	echo "ontesting" > "${INIT_PATH}/test_type_file"
commit_id="" author="" commit_date_time=""
fetch_next_commit retest || fetch_next_commit pending || true
if [ "${commit_id}" = "" ]; then
	sleep 60s
else
	update_task_status "ontesting" || return 1
	task_claimed=true
	echo "当前版本${commit_id}未执行过测试，即将编译后启动"
	if [ "${author}" != "Timecho" ]; then
		TABLENAME=${TABLENAME}
	else
		TABLENAME=${TABLENAME_T}
	fi
	init_items
	test_date_time=$(date +%Y%m%d%H%M%S)
	echo "开始测试223协议下的tablemode时间序列！"
	test_operation 223 tablemode || return 1
	echo "开始测试223协议下的common时间序列！"
	test_operation 223 common || return 1
	echo "开始测试223协议下的aligned时间序列！"
	test_operation 223 aligned || return 1
	echo "开始测试224协议下的aligned时间序列！"
	test_operation 224 aligned || return 1
	###############################测试完成###############################
	echo "本轮测试${test_date_time}已结束."
	update_task_status "done" || return 1
	task_completed=true
	update_sql02="update ${TASK_TABLENAME} set ${test_type} = 'skip' where ${test_type} is NULL and DATE_FORMAT(commit_date_time, '%Y%m%d%H%i%s') < $(sql_quote "${commit_date_time}")"
	if [ "${author}" != "Timecho" ]; then
		result_string=$(mysql_exec "${update_sql02}")
	fi
fi
}

main "$@"
