#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
	exec bash "$0" "$@"
fi
if shopt -oq posix; then
	exec bash "${BASH_SOURCE[0]}" "$@"
fi

set -u
set -o pipefail

readonly TEST_IP="11.101.17.115"
readonly ACCOUNT="atmos"
readonly TEST_TYPE="ts_performance"

readonly INIT_PATH="/data/atmos/zk_test"
readonly ATMOS_PATH="${INIT_PATH}/atmos-ex"
readonly BM_PATH="${INIT_PATH}/iot-benchmark"
readonly BM_REPOS_PATH="/nasdata/repository/iot-benchmark"
readonly DATA_PATH="/data/atmos/DataSet"
readonly BACKUP_PATH="/nasdata/repository/ts_performance"
readonly REPOS_PATH="/nasdata/repository/master"

readonly TEST_INIT_PATH="/data/atmos"
readonly TEST_IOTDB_PATH="${TEST_INIT_PATH}/apache-iotdb"

readonly -a protocol_class=(
	""
	"org.apache.iotdb.consensus.simple.SimpleConsensus"
	"org.apache.iotdb.consensus.ratis.RatisConsensus"
	"org.apache.iotdb.consensus.iot.IoTConsensus"
)
readonly -a protocol_list=(223)
readonly -a ts_list=(common aligned tempaligned tablemode)
readonly -a data_type_list=(sequence unsequence)

readonly MYSQL_HOST="111.200.37.158"
readonly MYSQL_PORT="13306"
readonly MYSQL_USERNAME="iotdbatm"
readonly MYSQL_PASSWORD="${ATMOS_DB_PASSWORD:-}"
readonly DBNAME="QA_ATM"
readonly TABLENAME="ex_ts_performance"
readonly TABLENAME_T="ex_ts_performance_T"
readonly TASK_TABLENAME="ex_commit_history"

readonly MONITOR_TIMEOUT_SECONDS=7200
readonly MONITOR_POLL_INTERVAL_SECONDS=10
readonly IOTDB_READY_RETRIES=10
readonly IOTDB_READY_INTERVAL_SECONDS=5
readonly STARTUP_GRACE_SECONDS=10
readonly OPERATION_GRACE_SECONDS=30
readonly STOP_WAIT_SECONDS=30

result_table="${TABLENAME}"
commit_id=""
author=""
commit_date_time=""
test_date_time=""
protocol_id=""
ts_type=""
data_type=""
cost_time=0
numOfSe0Level_before=0
numOfSe0Level_after=0
numOfUnse0Level_before=0
numOfUnse0Level_after=0
ts_dataSize=0
ts_numOfPoints=0
ts_rate=0
start_time=""
end_time=""
dataFileSize_before=0
dataFileSize_after=0
maxNumofOpenFiles=0
maxNumofThread=0
errorLogSize=0

# 功能：比较本地与仓库版本并同步 IoT-Benchmark
check_benchmark_version() {
	sync_benchmark_distribution "${BM_REPOS_PATH}" "${BM_PATH}"
}

# 功能：重置当前测试用例使用的指标和运行状态
init_items() {
	cost_time=0
	numOfSe0Level_before=0
	numOfSe0Level_after=0
	numOfUnse0Level_before=0
	numOfUnse0Level_after=0
	ts_dataSize=0
	ts_numOfPoints=0
	ts_rate=0
	start_time=""
	end_time=""
	dataFileSize_before=0
	dataFileSize_after=0
	maxNumofOpenFiles=0
	maxNumofThread=0
	errorLogSize=0
}

# 功能：在安装包准备完成后创建工具测试日志目录
after_prepare_iotdb_distribution() {
	mkdir -p "${TEST_IOTDB_PATH}/tools/testlog"
}

# 功能：按当前测试场景修改 IoTDB 配置
modify_iotdb_config() {
	local datanode_env="${TEST_IOTDB_PATH}/conf/datanode-env.sh"

	[ -f "${datanode_env}" ] || die "missing config file: ${datanode_env}"
	sed -i 's/^#\?ON_HEAP_MEMORY=.*$/ON_HEAP_MEMORY="20G"/' "${datanode_env}"

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

# 功能：使用当前场景参数执行 IoTDB CLI 命令
run_iotdb_cli() {
	iotdb_cli_run -h 127.0.0.1 -p 6667 "$@"
}

# 功能：输出表模型 CLI 调用所需的公共参数
table_cli_args() {
	printf '%s\n' "-sql_dialect" "table"
}

# 功能：创建当前测试需要的数据、文件或数据库对象
create_tablemode_schema() {
	if [ "${ts_type}" != "tablemode" ]; then
		return 0
	fi

	run_iotdb_cli -sql_dialect table -e "create database test_g_0" >/dev/null 2>&1 || true
	"${TEST_IOTDB_PATH}/tools/schema/import-schema.sh" \
		-sql_dialect table \
		-s "${ATMOS_PATH}/conf/${TEST_TYPE}/metadata/dump_test_g_0.sql" \
		-db test_g_0 >/dev/null 2>&1 || true
}

# 功能：监控导入或导出工具进程并处理超时和错误日志
monitor_tool_status() {
	local operation="$1"
	local monitor_start_epoch=0
	local now_epoch=0
	local elapsed=0
	local log_file="${TEST_IOTDB_PATH}/tools/testlog/log.txt"
	local pattern='Import completely!|Export completely!|Work has been completed!'

	monitor_start_epoch="$(date +%s)"
	maxNumofOpenFiles=0
	maxNumofThread=0

	while true; do
		refresh_max_process_metrics
		if [ -f "${log_file}" ] && grep -E -q "${pattern}" "${log_file}" 2>/dev/null; then
			end_time="$(current_datetime)"
			cost_time=$(( $(datetime_to_epoch "${end_time}") - $(datetime_to_epoch "${start_time}") ))
			log "${operation} finished, cost ${cost_time}s."
			return 0
		fi

		now_epoch="$(date +%s)"
		elapsed=$((now_epoch - monitor_start_epoch))
		if [ "${elapsed}" -ge "${MONITOR_TIMEOUT_SECONDS}" ]; then
			end_time=-1
			cost_time=-100
			log "${operation} timeout."
			return 1
		fi

		sleep "${MONITOR_POLL_INTERVAL_SECONDS}"
	done
}

# 功能：采集当前测试阶段产生的指标或文件信息
collect_data_before() {
	local collect_path="${1%/}"

	dataFileSize_before="$(dir_size_gb "${collect_path}/data")"
	numOfSe0Level_before="$(count_tsfiles "${collect_path}/data/datanode/data/sequence")"
	numOfUnse0Level_before="$(count_tsfiles "${collect_path}/data/datanode/data/unsequence")"
}

# 功能：采集当前测试阶段产生的指标或文件信息
collect_data_after() {
	local collect_path="${1%/}"

	dataFileSize_after="$(dir_size_gb "${collect_path}/data")"
	numOfSe0Level_after="$(count_tsfiles "${collect_path}/data/datanode/data/sequence")"
	numOfUnse0Level_after="$(count_tsfiles "${collect_path}/data/datanode/data/unsequence")"
	if [ -s "${TEST_IOTDB_PATH}/logs/log_datanode_error.log" ] || [ -s "${TEST_IOTDB_PATH}/logs/log_confignode_error.log" ]; then
		errorLogSize=1
	else
		errorLogSize=0
	fi
}

# 功能：从命令输出、日志或结果文件中提取目标值
extract_count_result() {
	awk '
		/^[|]/ {
			line = $0
			gsub(/\|/, "", line)
			gsub(/[[:space:]]/, "", line)
			if (line ~ /^-?[0-9]+$/) {
				value = line
			}
		}
		END {
			if (value != "") {
				print value
			}
		}
	'
}

# 功能：采集当前测试阶段产生的指标或文件信息
collect_point_count() {
	local count_result=""

	if [ "${ts_type}" = "tablemode" ]; then
		count_result="$(run_iotdb_cli -sql_dialect table -e "select count(s_0) from test_g_0.table_0 where device_id = 'd_0'" 2>/dev/null | extract_count_result)"
	else
		count_result="$(run_iotdb_cli -e "select count(s_0) from root.test.g_0.d_0" 2>/dev/null | extract_count_result)"
	fi

	if [ -z "${count_result}" ]; then
		count_result=-1
	fi
	ts_numOfPoints="${count_result}"
}

# 功能：将当前场景采集的指标写入结果数据库
insert_database() {
	local remark_value="$1"
	local insert_sql=""

	insert_sql=$(cat <<EOF
insert into ${result_table} (
	commit_date_time,test_date_time,commit_id,author,ts_type,data_type,cost_time,
	numOfSe0Level_before,numOfSe0Level_after,numOfUnse0Level_before,numOfUnse0Level_after,
	ts_dataSize,ts_numOfPoints,ts_rate,start_time,end_time,dataFileSize_before,dataFileSize_after,
	maxNumofOpenFiles,maxNumofThread,errorLogSize,remark
) values (
	${commit_date_time},
	${test_date_time},
	$(sql_quote "${commit_id}"),
	$(sql_quote "${author}"),
	$(sql_quote "${ts_type}"),
	$(sql_quote "${data_type}"),
	${cost_time},
	${numOfSe0Level_before},
	${numOfSe0Level_after},
	${numOfUnse0Level_before},
	${numOfUnse0Level_after},
	${ts_dataSize},
	${ts_numOfPoints},
	${ts_rate},
	$(sql_quote "${start_time}"),
	$(sql_quote "${end_time}"),
	$(sql_quote "${dataFileSize_before}"),
	$(sql_quote "${dataFileSize_after}"),
	${maxNumofOpenFiles},
	${maxNumofThread},
	${errorLogSize},
	$(sql_quote "${remark_value}")
)
EOF
)

	log "${ts_type} ${data_type} ${remark_value} cost: ${cost_time}s"
	mysql_exec "${insert_sql}"
	log "${insert_sql}"
}

# 功能：写入当前测试的日志、状态或失败结果
write_startup_error_result() {
	local remark_value="$1"

	cost_time=-3
	start_time="${start_time:-0}"
	end_time="${end_time:-0}"
	insert_database "${remark_value}"
	update_task_status "RError"
}

# 功能：启动指定服务、工具或测试步骤
start_iotdb_or_record_error() {
	local remark_value="$1"

	if start_iotdb_and_wait; then
		log "IoTDB started for ${remark_value}."
		return 0
	fi

	log "IoTDB startup failed for ${remark_value}."
	write_startup_error_result "${remark_value}"
	stop_iotdb
	sleep "${STOP_WAIT_SECONDS}"
	check_iotdb_pid
	return 1
}

# 功能：解析并返回当前操作使用的源文件路径
source_tsfile_path() {
	printf '%s\n' "${DATA_PATH}/${data_type}/${ts_type}"
}

# 功能：确保当前测试依赖的资源或结果存在
ensure_source_tsfile_path() {
	local source_path=""

	source_path="$(source_tsfile_path)"
	[ -d "${source_path}" ] || die "missing tsfile data: ${source_path}"
}

# 功能：执行指定测试阶段或外部工具命令
run_load_tsfile_tool() {
	local source_path=""
	local log_file="${TEST_IOTDB_PATH}/tools/testlog/log.txt"

	source_path="$(source_tsfile_path)"
	mkdir -p "${log_file%/*}"
	if [ -f "${TEST_IOTDB_PATH}/tools/import-data.sh" ]; then
		if [ "${ts_type}" = "tablemode" ]; then
			"${TEST_IOTDB_PATH}/tools/import-data.sh" \
				-ft tsfile \
				-sql_dialect table \
				-db test_g_0 \
				-s "${source_path}" \
				-h 127.0.0.1 \
				-p 6667 \
				-os none \
				-of none > "${log_file}" 2>&1 &
		else
			"${TEST_IOTDB_PATH}/tools/import-data.sh" \
				-ft tsfile \
				-s "${source_path}" \
				-h 127.0.0.1 \
				-p 6667 \
				-os none \
				-of none > "${log_file}" 2>&1 &
		fi
	else
		"${TEST_IOTDB_PATH}/tools/load-tsfile.sh" \
			-s "${source_path}" \
			-h 127.0.0.1 \
			-p 6667 \
			-os none \
			-of none > "${log_file}" 2>&1 &
	fi
}

# 功能：执行指定测试阶段或外部工具命令
run_export_tsfile_tool() {
	local target_dir="${TEST_IOTDB_PATH}/tools/data/datanode/data/sequence"
	local log_file="${TEST_IOTDB_PATH}/tools/testlog/log.txt"

	mkdir -p "${target_dir}" "${log_file%/*}"
	if [ -f "${TEST_IOTDB_PATH}/tools/export-data.sh" ]; then
		if [ "${ts_type}" = "tablemode" ]; then
			"${TEST_IOTDB_PATH}/tools/export-data.sh" \
				-ft tsfile \
				-sql_dialect table \
				-db test_g_0 \
				-table table_0 \
				-h 127.0.0.1 \
				-p 6667 \
				-t "${target_dir}" \
				-q "select * from table_0 where device_id = 'd_0'" > "${log_file}" 2>&1 &
		else
			"${TEST_IOTDB_PATH}/tools/export-data.sh" \
				-h 127.0.0.1 \
				-p 6667 \
				-t "${target_dir}" \
				-ft tsfile \
				-q "select * from root.test.g_0.d_0" > "${log_file}" 2>&1 &
		fi
	else
		"${TEST_IOTDB_PATH}/tools/export-tsfile.sh" \
			-h 127.0.0.1 \
			-p 6667 \
			-t "${target_dir}" \
			-q "select * from root.test.g_0.d_0" > "${log_file}" 2>&1 &
	fi
}

# 功能：执行指定测试阶段或外部工具命令
run_export_csv_tool() {
	local target_dir="${TEST_IOTDB_PATH}/tools/data/datanode/data/sequence"
	local log_file="${TEST_IOTDB_PATH}/tools/testlog/log.txt"

	mkdir -p "${target_dir}" "${log_file%/*}"
	if [ -f "${TEST_IOTDB_PATH}/tools/export-data.sh" ]; then
		if [ "${ts_type}" = "tablemode" ]; then
			"${TEST_IOTDB_PATH}/tools/export-data.sh" \
				-ft csv \
				-sql_dialect table \
				-db test_g_0 \
				-table table_0 \
				-h 127.0.0.1 \
				-p 6667 \
				-t "${target_dir}" \
				-q "select * from table_0 where device_id = 'd_0'" > "${log_file}" 2>&1 &
		else
			"${TEST_IOTDB_PATH}/tools/export-data.sh" \
				-h 127.0.0.1 \
				-p 6667 \
				-t "${target_dir}" \
				-ft csv \
				-q "select * from root.test.g_0.d_0" > "${log_file}" 2>&1 &
		fi
	else
		"${TEST_IOTDB_PATH}/tools/export-csv.sh" \
			-h 127.0.0.1 \
			-p 6667 \
			-t "${target_dir}" \
			-f export_csv \
			-q "select * from root.test.g_0.d_0" > "${log_file}" 2>&1 &
	fi
}

# 功能：归档当前测试产生的日志和运行文件
archive_tool_log() {
	local archive_name="$1"
	local log_file="${TEST_IOTDB_PATH}/tools/testlog/log.txt"
	local target_log="${TEST_IOTDB_PATH}/tools/testlog/log.${archive_name}"

	if [ -f "${log_file}" ]; then
		mv "${log_file}" "${target_log}"
	fi
}

# 功能：执行指定测试阶段或外部工具命令
run_tool_operation() {
	run_isolated_case run_tool_operation_impl "$@"
}

# 功能：执行单轮 TsFile 工具测试；由 run_tool_operation 隔离运行状态
run_tool_operation_impl() {
	local remark_value="$1"
	local collect_before_path="$2"
	local collect_after_path="$3"
	local tool_runner="$4"
	local monitor_failed=0

	init_items
	collect_data_before "${collect_before_path}"
	if [ "${remark_value}" = "export-tsfile" ]; then
		set_iotdb_property "max_deduplicated_path_num" "60000000"
		set_iotdb_property "query_timeout_threshold" "60000000"
	fi
	if ! start_iotdb_or_record_error "${remark_value}"; then
		return 1
	fi

	if [ "${remark_value}" = "load-tsfile" ]; then
		create_tablemode_schema
	fi

	sleep "${OPERATION_GRACE_SECONDS}"
	start_time="$(current_datetime)"
	"${tool_runner}"
	if ! monitor_tool_status "${remark_value}"; then
		monitor_failed=1
	fi
	collect_point_count

	stop_iotdb
	sleep "${STOP_WAIT_SECONDS}"
	check_iotdb_pid
	collect_data_after "${collect_after_path}"
	insert_database "${remark_value}"
	archive_tool_log "${remark_value}"

	return "${monitor_failed}"
}

# 功能：归档测试日志、配置、数据或结果文件
backup_test_data() {
	local current_ts_type="$1"
	local backup_parent="${BACKUP_PATH}/${current_ts_type}"
	local backup_dir="${backup_parent}/${commit_date_time}_${commit_id}_${protocol_id}"

	prepare_archive_directory "${backup_dir}"
	if [ -d "${TEST_IOTDB_PATH}/tools/testlog" ]; then
		sudo mv "${TEST_IOTDB_PATH}/tools/testlog" "${backup_dir}/"
	fi
	sudo_safe_rm "${TEST_IOTDB_PATH}/data"
	sudo_safe_rm "${TEST_IOTDB_PATH}/tools"
	path_is_safe "${TEST_IOTDB_PATH}" || die "refuse to move unexpected path: ${TEST_IOTDB_PATH}"
	sudo mv "${TEST_IOTDB_PATH}" "${backup_dir}"
}

# 功能：执行单个测试组合并收集、解析和保存结果
test_operation() {
	protocol_id="$1"
	ts_type="$2"
	data_type="$3"
	local source_path=""
	local task_failed=0

	log "start ${TEST_TYPE}: protocol=${protocol_id}, ts=${ts_type}, data=${data_type}"
	ensure_source_tsfile_path
	cleanup_processes
	set_env
	modify_iotdb_config
	if ! set_protocol_class "${protocol_id}"; then
		log "invalid protocol: ${protocol_id}"
		return 1
	fi

	source_path="$(source_tsfile_path)"
	if ! run_tool_operation "load-tsfile" "${source_path}" "${TEST_IOTDB_PATH}" run_load_tsfile_tool; then
		task_failed=1
	fi
	if ! run_tool_operation "export-tsfile" "${TEST_IOTDB_PATH}" "${TEST_IOTDB_PATH}/tools" run_export_tsfile_tool; then
		task_failed=1
	fi
	if ! run_tool_operation "export-csv" "${TEST_IOTDB_PATH}" "${TEST_IOTDB_PATH}/tools" run_export_csv_tool; then
		task_failed=1
	fi

	backup_test_data "${ts_type}"
	return "${task_failed}"
}

# 功能：校验运行环境并编排当前脚本的完整测试流程
main() {
	local protocol=""
	local ts=""
	local current_data_type=""
	local task_failed=0

	trap restore_test_type_file EXIT
	ensure_runtime_dependencies
	check_password
	check_benchmark_version
	mark_test_in_progress

	if ! fetch_next_commit; then
		sleep 60
		return 0
	fi

	update_task_status "ontesting"
	log "current commit ${commit_id} starts ${TEST_TYPE}"
	if [ "${author}" = "Timecho" ]; then
		result_table="${TABLENAME_T}"
	else
		result_table="${TABLENAME}"
	fi

	test_date_time="$(date +%Y%m%d%H%M%S)"
	for protocol in "${protocol_list[@]}"; do
		for ts in "${ts_list[@]}"; do
			for current_data_type in "${data_type_list[@]}"; do
				if ! test_operation "${protocol}" "${ts}" "${current_data_type}"; then
					task_failed=1
				fi
			done
		done
	done

	log "test round ${test_date_time} finished"
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
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/benchmark_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/iotdb_distribution_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/iotdb_service_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/protocol_common.sh"

main "$@"
