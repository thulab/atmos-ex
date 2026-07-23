#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
	exec bash "$0" "$@"
fi
if shopt -oq posix; then
	exec bash "${BASH_SOURCE[0]}" "$@"
fi

set -u
set -o pipefail

readonly TEST_IP="11.101.17.114"
readonly TEST_TYPE="compaction"

readonly INIT_PATH="/data/atmos/zk_test"
readonly ATMOS_PATH="${INIT_PATH}/atmos-ex"
readonly DATA_PATH="/data/atmos/DataSet"
readonly BACKUP_PATH="/nasdata/repository/compaction"
readonly REPOS_PATH="/nasdata/repository/master"

readonly TEST_INIT_PATH="/data/atmos"
readonly TEST_IOTDB_PATH="${TEST_INIT_PATH}/apache-iotdb"

readonly -a protocol_class=(
	""
	"org.apache.iotdb.consensus.simple.SimpleConsensus"
	"org.apache.iotdb.consensus.ratis.RatisConsensus"
	"org.apache.iotdb.consensus.iot.IoTConsensus"
)
readonly -a protocol_list=(211)
readonly -a ts_list=(common aligned)

readonly MYSQL_HOST="111.200.37.158"
readonly MYSQL_PORT="13306"
readonly MYSQL_USERNAME="iotdbatm"
readonly MYSQL_PASSWORD="${ATMOS_DB_PASSWORD:-}"
readonly DBNAME="QA_ATM"
readonly TABLENAME="ex_compaction"
readonly TABLENAME_T="ex_compaction_T"
readonly TASK_TABLENAME="ex_commit_history"

readonly METRIC_SERVER="111.200.37.158:19090"
readonly DEFAULT_DISK_ID="sdb"
readonly MONITOR_TIMEOUT_SECONDS=7200
readonly MONITOR_POLL_INTERVAL_SECONDS=10
readonly STARTUP_GRACE_SECONDS=10
readonly STOP_WAIT_SECONDS=30

result_table="${TABLENAME}"
commit_id=""
author=""
commit_date_time=""
test_date_time=""
protocol_id=""
ts_type=""
comp_type=""
cost_time=0
numOfSe0Level_before=0
numOfSe0Level_after=0
numOfUnse0Level_before=0
numOfUnse0Level_after=0
ts_dataSize=0
ts_numOfPoints=0
compaction_rate=0
comp_start_time=0
comp_end_time=0
dataFileSize_before=0
dataFileSize_after=0
maxNumofOpenFiles=0
maxNumofThread=0
errorLogSize=0
maxCPULoad=0
avgCPULoad=0
maxDiskIOOpsRead=0
maxDiskIOOpsWrite=0
maxDiskIOSizeRead=0
maxDiskIOSizeWrite=0
disk_id_regex="^${DEFAULT_DISK_ID}$"

# 功能：重置当前测试用例使用的指标和运行状态
init_items() {
	cost_time=0
	numOfSe0Level_before=0
	numOfSe0Level_after=0
	numOfUnse0Level_before=0
	numOfUnse0Level_after=0
	ts_dataSize=0
	ts_numOfPoints=0
	compaction_rate=0
	comp_start_time=0
	comp_end_time=0
	dataFileSize_before=0
	dataFileSize_after=0
	maxNumofOpenFiles=0
	maxNumofThread=0
	errorLogSize=0
	maxCPULoad=0
	avgCPULoad=0
	maxDiskIOOpsRead=0
	maxDiskIOOpsWrite=0
	maxDiskIOSizeRead=0
	maxDiskIOSizeWrite=0
}

# 功能：按当前测试场景修改 IoTDB 配置
modify_iotdb_config() {
	local datanode_env="${TEST_IOTDB_PATH}/conf/datanode-env.sh"

	[ -f "${datanode_env}" ] || die "缺少配置文件: ${datanode_env}"
	sed -i 's/^#\?ON_HEAP_MEMORY=.*$/ON_HEAP_MEMORY="20G"/' "${datanode_env}"

	set_iotdb_property "series_slot_num" "10000"
	set_iotdb_property "target_compaction_file_size" "1073741824"
	set_iotdb_property "enable_seq_space_compaction" "false"
	set_iotdb_property "enable_unseq_space_compaction" "false"
	set_iotdb_property "enable_cross_space_compaction" "false"
	set_iotdb_property "cluster_name" "${TEST_TYPE}"
	set_iotdb_property "cn_enable_metric" "true"
	set_iotdb_property "cn_enable_performance_stat" "true"
	set_iotdb_property "cn_metric_reporter_list" "PROMETHEUS"
	set_iotdb_property "cn_metric_level" "ALL"
	set_iotdb_property "cn_metric_prometheus_reporter_port" "9081"
	set_iotdb_property "dn_enable_metric" "true"
	set_iotdb_property "dn_enable_performance_stat" "true"
	set_iotdb_property "dn_metric_reporter_list" "PROMETHEUS"
	set_iotdb_property "dn_metric_level" "ALL"
	set_iotdb_property "dn_metric_prometheus_reporter_port" "9091"
}

# 功能：写入当前测试的日志、状态或失败结果
write_timeout_compaction_log() {
	local log_compaction="${TEST_IOTDB_PATH}/logs/log_datanode_compaction.log"

	mkdir -p "${log_compaction%/*}"
	cat >> "${log_compaction}" <<EOF
$(current_datetime),000 [pool-21-IoTDB-Compaction-1] INFO  o.a.i.d.e.c.c.CrossSpaceCompactionTask:207 - root.test.g_0-1 [Compaction] CrossSpaceCompaction task finishes successfully, time cost is -1 s, compaction speed is 0 MB/s
$(current_datetime),000 [pool-21-IoTDB-Compaction-1] INFO  o.a.i.d.e.c.i.InnerSpaceCompactionTask:239 - root.test.g_0-1 [Compaction] InnerSpaceCompaction task finishes successfully, target file is timeout.tsfile,time cost is -1 s, compaction speed is 0 MB/s
EOF
}

# 功能：轮询测试进程和结果文件，处理完成或超时状态
monitor_test_status() {
	local start_epoch=0
	local now_epoch=0
	local elapsed=0
	local numOfcompactioning=0
	local data_dir="${TEST_IOTDB_PATH}/data/datanode/data"
	local log_compaction="${TEST_IOTDB_PATH}/logs/log_datanode_compaction.log"

	start_epoch="$(date +%s)"
	maxNumofOpenFiles=0
	maxNumofThread=0

	while true; do
		refresh_max_process_metrics
		if [ -d "${data_dir}" ]; then
			numOfcompactioning="$(find "${data_dir}" -name "*compaction.log" 2>/dev/null | wc -l | tr -d '[:space:]')"
		else
			numOfcompactioning=0
		fi

		if [ "${numOfcompactioning}" -le 0 ]; then
			sleep 70
			refresh_max_process_metrics
			if [ -d "${data_dir}" ]; then
				numOfcompactioning="$(find "${data_dir}" -name "*compaction.log" 2>/dev/null | wc -l | tr -d '[:space:]')"
			else
				numOfcompactioning=0
			fi

			if [ "${numOfcompactioning}" -le 0 ]; then
				if [ -f "${log_compaction}" ]; then
					log "${comp_type}合并已完成"
					return 0
				fi

				now_epoch="$(date +%s)"
				elapsed=$((now_epoch - start_epoch))
				if [ "${elapsed}" -ge "${MONITOR_TIMEOUT_SECONDS}" ]; then
					log "${comp_type}合并超时，写入负值结果"
					write_timeout_compaction_log
					return 0
				fi
				continue
			fi
		fi

		now_epoch="$(date +%s)"
		elapsed=$((now_epoch - start_epoch))
		if [ "${elapsed}" -ge "${MONITOR_TIMEOUT_SECONDS}" ]; then
			log "${comp_type}合并超时，写入负值结果"
			write_timeout_compaction_log
			return 0
		fi
		sleep "${MONITOR_POLL_INTERVAL_SECONDS}"
	done
}

# 功能：采集当前测试阶段产生的指标或文件信息
collect_data_before() {
	dataFileSize_before="$(dir_size_gb "${TEST_IOTDB_PATH}/data")"
	numOfSe0Level_before="$(count_tsfiles "${TEST_IOTDB_PATH}/data/datanode/data/sequence" "*-0-*.tsfile")"
	numOfUnse0Level_before="$(count_tsfiles "${TEST_IOTDB_PATH}/data/datanode/data/unsequence" "*-0-*.tsfile")"
}

# 功能：从命令输出、日志或结果文件中提取目标值
extract_compaction_cost_time() {
	local log_file="$1"
	local extracted_cost=""

	extracted_cost="$(grep -F "InnerSpaceCompaction task finishes successfully" "${log_file}" 2>/dev/null \
		| tail -n 1 \
		| sed -n 's/.*time cost is \([-0-9.]*\) s.*/\1/p')"
	if [ -z "${extracted_cost}" ]; then
		extracted_cost="$(grep -F "CrossSpaceCompaction task finishes successfully" "${log_file}" 2>/dev/null \
			| tail -n 1 \
			| sed -n 's/.*time cost is \([-0-9.]*\) s.*/\1/p')"
	fi

	printf '%s\n' "${extracted_cost}"
}

# 功能：采集当前测试阶段产生的指标或文件信息
collect_data_after() {
	local log_compaction="${TEST_IOTDB_PATH}/logs/log_datanode_compaction.log"

	dataFileSize_after="$(dir_size_gb "${TEST_IOTDB_PATH}/data")"
	numOfSe0Level_after="$(count_tsfiles "${TEST_IOTDB_PATH}/data/datanode/data/sequence" "*-0-*.tsfile")"
	numOfUnse0Level_after="$(count_tsfiles "${TEST_IOTDB_PATH}/data/datanode/data/unsequence" "*-0-*.tsfile")"
	compaction_rate=0
	ts_dataSize=0
	ts_numOfPoints=0
	cost_time=""

	if [ -f "${log_compaction}" ]; then
		comp_start_time="$(awk 'NR == 1 {print $1, $2; exit}' "${log_compaction}" | cut -c 1-19)"
		comp_end_time="$(awk 'END {print $1, $2}' "${log_compaction}" | cut -c 1-19)"
		cost_time="$(extract_compaction_cost_time "${log_compaction}")"
	fi
	if [ -z "${cost_time}" ]; then
		cost_time=-1
	fi

	if [ -s "${TEST_IOTDB_PATH}/logs/log_datanode_error.log" ] || [ -s "${TEST_IOTDB_PATH}/logs/log_confignode_error.log" ]; then
		errorLogSize=1
	else
		errorLogSize=0
	fi
}

# 功能：采集当前测试阶段产生的指标或文件信息
collect_prometheus_metrics() {
	local start_epoch="$1"
	local end_epoch="$2"
	local duration=$((end_epoch - start_epoch))

	if [ "${duration}" -le 0 ]; then
		duration=1
	fi

	resolve_monitor_disk_id
	maxCPULoad="$(get_single_index "max_over_time(sys_cpu_load{instance=~\"${TEST_IP}:9091\"}[${duration}s])" "${end_epoch}")"
	avgCPULoad="$(get_single_index "avg_over_time(sys_cpu_load{instance=~\"${TEST_IP}:9091\"}[${duration}s])" "${end_epoch}")"
	maxDiskIOOpsRead="$(get_single_index "sum(rate(disk_io_ops{instance=~\"${TEST_IP}:9091\",disk_id=~\"${disk_id_regex}\",type=~\"read\"}[${duration}s]))" "${end_epoch}")"
	maxDiskIOOpsWrite="$(get_single_index "sum(rate(disk_io_ops{instance=~\"${TEST_IP}:9091\",disk_id=~\"${disk_id_regex}\",type=~\"write\"}[${duration}s]))" "${end_epoch}")"
	maxDiskIOSizeRead="$(get_single_index "sum(rate(disk_io_size{instance=~\"${TEST_IP}:9091\",disk_id=~\"${disk_id_regex}\",type=~\"read\"}[${duration}s]))" "${end_epoch}")"
	maxDiskIOSizeWrite="$(get_single_index "sum(rate(disk_io_size{instance=~\"${TEST_IP}:9091\",disk_id=~\"${disk_id_regex}\",type=~\"write\"}[${duration}s]))" "${end_epoch}")"
}

# 功能：将当前场景采集的指标写入结果数据库
insert_database() {
	local remark_value="$1"
	local insert_sql=""

	insert_sql=$(cat <<EOF
insert into ${result_table} (
	commit_date_time,test_date_time,commit_id,author,ts_type,comp_type,cost_time,numOfSe0Level_before,numOfSe0Level_after,
	numOfUnse0Level_before,numOfUnse0Level_after,ts_dataSize,ts_numOfPoints,compaction_rate,comp_start_time,comp_end_time,
	dataFileSize_before,dataFileSize_after,maxNumofOpenFiles,maxNumofThread,errorLogSize,avgCPULoad,maxCPULoad,
	maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,remark
) values (
	${commit_date_time},
	${test_date_time},
	$(sql_quote "${commit_id}"),
	$(sql_quote "${author}"),
	$(sql_quote "${ts_type}"),
	$(sql_quote "${comp_type}"),
	${cost_time},
	${numOfSe0Level_before},
	${numOfSe0Level_after},
	${numOfUnse0Level_before},
	${numOfUnse0Level_after},
	${ts_dataSize},
	${ts_numOfPoints},
	${compaction_rate},
	$(sql_quote "${comp_start_time}"),
	$(sql_quote "${comp_end_time}"),
	$(sql_quote "${dataFileSize_before}"),
	$(sql_quote "${dataFileSize_after}"),
	${maxNumofOpenFiles},
	${maxNumofThread},
	${errorLogSize},
	${avgCPULoad},
	${maxCPULoad},
	${maxDiskIOSizeRead},
	${maxDiskIOSizeWrite},
	${maxDiskIOOpsRead},
	${maxDiskIOOpsWrite},
	$(sql_quote "${remark_value}")
)
EOF
)

	log "${ts_type}时间序列 ${comp_type} 合并耗时为: ${cost_time} 秒"
	mysql_exec "${insert_sql}"
	log "${insert_sql}"
}

# 功能：归档测试日志、配置、数据或结果文件
backup_test_data() {
	local current_ts_type="$1"
	local backup_parent="${BACKUP_PATH}/${current_ts_type}"
	local backup_dir="${backup_parent}/${commit_date_time}_${commit_id}_${protocol_id}"

	sudo_safe_rm "${backup_dir}"
	path_is_safe "${backup_parent}" || die "拒绝使用非预期备份路径: ${backup_parent}"
	sudo mkdir -p -- "${backup_dir}"
	sudo_safe_rm "${TEST_IOTDB_PATH}/data"
	path_is_safe "${TEST_IOTDB_PATH}" || die "拒绝移动非预期路径: ${TEST_IOTDB_PATH}"
	sudo mv "${TEST_IOTDB_PATH}" "${backup_dir}"
}

# 功能：生成或修改当前测试步骤所需的配置
configure_compaction_case() {
	local seq_enabled="$1"
	local unseq_enabled="$2"
	local cross_enabled="$3"
	local target_size="$4"

	set_iotdb_property "enable_seq_space_compaction" "${seq_enabled}"
	set_iotdb_property "enable_unseq_space_compaction" "${unseq_enabled}"
	set_iotdb_property "enable_cross_space_compaction" "${cross_enabled}"
	set_iotdb_property "target_compaction_file_size" "${target_size}"
}

# 功能：归档当前测试产生的日志和运行文件
archive_compaction_logs() {
	local archive_name="$1"
	local archive_dir="${TEST_IOTDB_PATH}/${archive_name}"

	if [ ! -d "${TEST_IOTDB_PATH}/logs" ]; then
		return 0
	fi

	mkdir -p "${archive_dir}"
	cp -rf "${TEST_IOTDB_PATH}/conf" "${archive_dir}/"
	mv "${TEST_IOTDB_PATH}/logs" "${archive_dir}/"
}

# 功能：更新当前任务或测试的状态标记
mark_restart_error() {
	local remark_value="$1"

	cost_time=-3
	comp_start_time=0
	comp_end_time=0
	insert_database "${remark_value}"
	update_task_status "RError"
}

# 功能：执行指定测试阶段或外部工具命令
run_compaction_case() {
	local current_comp_type="$1"
	local seq_enabled="$2"
	local unseq_enabled="$3"
	local cross_enabled="$4"
	local target_size="$5"
	local retry_count="$6"
	local sleep_seconds="$7"
	local metric_start=0
	local metric_end=0

	init_items
	comp_type="${current_comp_type}"
	configure_compaction_case "${seq_enabled}" "${unseq_enabled}" "${cross_enabled}" "${target_size}"
	collect_data_before

	start_iotdb
	metric_start="$(date +%s)"
	sleep "${STARTUP_GRACE_SECONDS}"
	if ! wait_iotdb_ready "${retry_count}" "${sleep_seconds}"; then
		log "IoTDB未能正常启动，写入负值测试结果"
		mark_restart_error "${protocol_id}"
		stop_iotdb
		sleep "${STOP_WAIT_SECONDS}"
		check_iotdb_pid
		return 1
	fi

	log "IoTDB正常启动，准备开始 ${comp_type} 测试"
	sleep 30
	monitor_test_status
	stop_iotdb
	sleep "${STOP_WAIT_SECONDS}"
	check_iotdb_pid

	collect_data_after
	metric_end="$(date +%s)"
	collect_prometheus_metrics "${metric_start}" "${metric_end}"
	insert_database "${protocol_id}"
	archive_compaction_logs "${comp_type}"
	return 0
}

# 功能：执行单个测试组合并收集、解析和保存结果
test_operation() {
	protocol_id="$1"
	ts_type="$2"
	local data_source="${DATA_PATH}/${protocol_id}/${ts_type}/data"

	log "开始测试${protocol_id}协议下的${ts_type}时间序列"
	check_iotdb_pid
	set_env
	modify_iotdb_config
	if ! set_protocol_class "${protocol_id}"; then
		log "协议设置错误: ${protocol_id}"
		return 1
	fi

	[ -d "${data_source}" ] || die "缺少压缩测试数据目录: ${data_source}"
	cp -rf "${data_source}" "${TEST_IOTDB_PATH}/"

	if ! run_compaction_case seq_space true false false 1073741824 10 5; then
		return 1
	fi
	if ! run_compaction_case unseq_space false true false 1073741824 20 30; then
		return 1
	fi
	if ! run_compaction_case cross_space false false true 2147483648 20 30; then
		return 1
	fi

	backup_test_data "${ts_type}"
}

# 功能：校验运行环境并编排当前脚本的完整测试流程
main() {
	local protocol=""
	local ts=""
	local task_failed=0

	trap restore_test_type_file EXIT
	ensure_runtime_dependencies
	check_password
	mark_test_in_progress

	if ! fetch_next_commit; then
		sleep 60
		return 0
	fi

	update_task_status "ontesting"
	log "当前版本${commit_id}未执行过测试，即将启动"
	if [ "${author}" = "Timecho" ]; then
		result_table="${TABLENAME_T}"
	else
		result_table="${TABLENAME}"
	fi

	test_date_time="$(date +%Y%m%d%H%M%S)"
	for protocol in "${protocol_list[@]}"; do
		for ts in "${ts_list[@]}"; do
			if ! test_operation "${protocol}" "${ts}"; then
				task_failed=1
			fi
		done
	done

	log "本轮测试${test_date_time}已结束"
	if [ "${task_failed}" -eq 0 ]; then
		update_task_status "done"
		if [ "${author}" != "Timecho" ]; then
			mark_older_commits_skip
		fi
	else
		update_task_status "RError"
	fi
}

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/runtime_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/iotdb_distribution_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/iotdb_service_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/protocol_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/monitor_common.sh"

main "$@"
