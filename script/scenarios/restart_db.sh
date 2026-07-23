#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
	exec bash "$0" "$@"
fi
if shopt -oq posix; then
	exec bash "${BASH_SOURCE[0]}" "$@"
fi

set -u
set -o pipefail

readonly TEST_TYPE="restart_db"

readonly INIT_PATH="/data/atmos/zk_test"
readonly ATMOS_PATH="${INIT_PATH}/atmos-ex"
readonly DATA_PATH="/data/atmos/DataSet"
readonly BACKUP_PATH="/nasdata/repository/restart_db"
readonly REPOS_PATH="/nasdata/repository/master"

readonly TEST_INIT_PATH="/data/atmos"
readonly TEST_IOTDB_PATH="${TEST_INIT_PATH}/apache-iotdb"

readonly MYSQL_HOST="111.200.37.158"
readonly MYSQL_PORT="13306"
readonly MYSQL_USERNAME="iotdbatm"
readonly MYSQL_PASSWORD="${ATMOS_DB_PASSWORD:-}"
readonly DBNAME="QA_ATM"
readonly TABLENAME="ex_restart_db"
readonly TABLENAME_T="ex_restart_db_T"
readonly TASK_TABLENAME="ex_commit_history"

readonly MONITOR_TIMEOUT_SECONDS=7200
readonly MONITOR_POLL_INTERVAL_SECONDS=10
readonly STARTUP_GRACE_SECONDS=10
readonly STOP_WAIT_SECONDS=10

readonly -a protocol_list=(211)
readonly -a ts_list=(common)
readonly -a data_type_list=(sequence)

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
start_time=""
end_time=""
dataFileSize_before=0
dataFileSize_after=0
WALSize_before=0
WALSize_after=0
maxNumofOpenFiles=0
maxNumofThread=0
errorLogSize=0

# 功能：重置当前测试用例使用的指标和运行状态
init_items() {
	cost_time=0
	numOfSe0Level_before=0
	numOfSe0Level_after=0
	numOfUnse0Level_before=0
	numOfUnse0Level_after=0
	start_time=""
	end_time=""
	dataFileSize_before=0
	dataFileSize_after=0
	WALSize_before=0
	WALSize_after=0
	maxNumofOpenFiles=0
	maxNumofThread=0
	errorLogSize=0
}

# 功能：按当前测试场景修改 IoTDB 配置
modify_iotdb_config() {
	local datanode_env="${TEST_IOTDB_PATH}/conf/datanode-env.sh"

	[ -f "${datanode_env}" ] || die "missing config file: ${datanode_env}"
	sed -i 's/^#\?ON_HEAP_MEMORY=.*$/ON_HEAP_MEMORY="20G"/' "${datanode_env}"

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

# 功能：从命令输出、日志或结果文件中提取目标值
extract_log_timestamp() {
	local log_file="$1"
	local pattern="${2:-}"
	local timestamp=""

	if [ ! -f "${log_file}" ]; then
		return 1
	fi

	if [ -n "${pattern}" ]; then
		timestamp="$(awk -v pattern="${pattern}" '$0 ~ pattern {print $1, $2; exit}' "${log_file}" | cut -c 1-19)"
	else
		timestamp="$(awk 'NR == 1 {print $1, $2; exit}' "${log_file}" | cut -c 1-19)"
	fi

	[ -n "${timestamp}" ] || return 1
	printf '%s\n' "${timestamp}"
}

# 功能：计算当前测试所需的时间、大小或统计值
calculate_startup_cost() {
	if [ -z "${start_time}" ] || [ -z "${end_time}" ] || [ "${end_time}" = "-1" ]; then
		printf '%s\n' "-100"
		return 0
	fi

	if ! datetime_to_epoch "${start_time}" >/dev/null 2>&1 || ! datetime_to_epoch "${end_time}" >/dev/null 2>&1; then
		printf '%s\n' "-100"
		return 0
	fi

	printf '%s\n' "$(( $(datetime_to_epoch "${end_time}") - $(datetime_to_epoch "${start_time}") ))"
}

# 功能：检查 IoTDB 启动后是否能够成功执行查询
can_query_iotdb_after_startup() {
	local iotdb_state=""

	iotdb_state="$("${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw root -e "show cluster" 2>/dev/null | grep -F 'Total line number = 2' || true)"
	[ "${iotdb_state}" = "Total line number = 2" ]
}

# 功能：轮询测试进程和结果文件，处理完成或超时状态
monitor_test_status() {
	local monitor_start_epoch=0
	local elapsed=0
	local setup_count=0
	local now_epoch=0
	local datanode_log="${TEST_IOTDB_PATH}/logs/log_datanode_all.log"

	monitor_start_epoch="$(date +%s)"
	maxNumofOpenFiles=0
	maxNumofThread=0

	while true; do
		refresh_max_process_metrics
		if [ -f "${datanode_log}" ]; then
			setup_count="$(grep -E -c 'IoTDB DataNode is set up successfully. Now, enjoy yourself!?' "${datanode_log}" 2>/dev/null || true)"
		else
			setup_count=0
		fi

		if [ "${setup_count}" -gt 0 ]; then
			start_time="$(extract_log_timestamp "${datanode_log}" || current_datetime)"
			end_time="$(extract_log_timestamp "${datanode_log}" "IoTDB DataNode is set up successfully" || current_datetime)"
			cost_time="$(calculate_startup_cost)"
			if ! can_query_iotdb_after_startup; then
				cost_time=-50
				log "IoTDB started but CLI query failed."
				return 1
			fi
			log "${data_type} restart finished, cost ${cost_time}s."
			return 0
		fi

		now_epoch="$(date +%s)"
		elapsed=$((now_epoch - monitor_start_epoch))
		if [ "${elapsed}" -ge "${MONITOR_TIMEOUT_SECONDS}" ]; then
			end_time=-1
			cost_time=-100
			log "${data_type} restart timeout."
			return 1
		fi

		sleep "${MONITOR_POLL_INTERVAL_SECONDS}"
	done
}

# 功能：采集当前测试阶段产生的指标或文件信息
collect_data_before() {
	local collect_path="${1%/}"

	dataFileSize_before="$(dir_size_gb "${collect_path}/data/datanode/data")"
	numOfSe0Level_before="$(count_tsfiles "${collect_path}/data/datanode/data/sequence")"
	numOfUnse0Level_before="$(count_tsfiles "${collect_path}/data/datanode/data/unsequence")"
	WALSize_before="$(dir_size_gb "${collect_path}/data/datanode/wal")"
}

# 功能：采集当前测试阶段产生的指标或文件信息
collect_data_after() {
	local collect_path="${1%/}"

	dataFileSize_after="$(dir_size_gb "${collect_path}/data/datanode/data")"
	numOfSe0Level_after="$(count_tsfiles "${collect_path}/data/datanode/data/sequence")"
	numOfUnse0Level_after="$(count_tsfiles "${collect_path}/data/datanode/data/unsequence")"
	WALSize_after="$(dir_size_gb "${collect_path}/data/datanode/wal")"

	if [ -s "${collect_path}/logs/log_datanode_error.log" ] || [ -s "${collect_path}/logs/log_confignode_error.log" ]; then
		errorLogSize=1
	else
		errorLogSize=0
	fi
}

# 功能：将当前场景采集的指标写入结果数据库
insert_database() {
	local remark_value="$1"
	local insert_sql=""

	insert_sql=$(cat <<EOF
insert into ${result_table} (
	commit_date_time,test_date_time,commit_id,author,ts_type,data_type,cost_time,
	numOfSe0Level_before,numOfSe0Level_after,numOfUnse0Level_before,numOfUnse0Level_after,
	start_time,end_time,dataFileSize_before,dataFileSize_after,WALSize_before,WALSize_after,
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
	$(sql_quote "${start_time}"),
	$(sql_quote "${end_time}"),
	$(sql_quote "${dataFileSize_before}"),
	$(sql_quote "${dataFileSize_after}"),
	$(sql_quote "${WALSize_before}"),
	$(sql_quote "${WALSize_after}"),
	${maxNumofOpenFiles},
	${maxNumofThread},
	${errorLogSize},
	$(sql_quote "${remark_value}")
)
EOF
)

	log "${ts_type} ${data_type} restart cost: ${cost_time}s"
	mysql_exec "${insert_sql}"
	log "${insert_sql}"
}

# 功能：归档当前测试产生的日志和运行文件
archive_logs() {
	local archive_dir_name="$1"
	local archive_dir="${TEST_IOTDB_PATH}/${archive_dir_name}"

	if [ -z "${archive_dir_name}" ] || [ ! -d "${TEST_IOTDB_PATH}/logs" ]; then
		return 0
	fi

	mkdir -p "${archive_dir}"
	mv "${TEST_IOTDB_PATH}/logs" "${archive_dir}/"
}

# 功能：归档测试日志、配置、数据或结果文件
backup_test_data() {
	local current_ts_type="$1"
	local backup_parent="${BACKUP_PATH}/${current_ts_type}"
	local backup_dir="${backup_parent}/${commit_date_time}_${commit_id}_${protocol_id}"

	prepare_archive_directory "${backup_dir}"
	sudo_safe_rm "${TEST_IOTDB_PATH}/data"
	path_is_safe "${TEST_IOTDB_PATH}" || die "refuse to move unexpected path: ${TEST_IOTDB_PATH}"
	sudo mv "${TEST_IOTDB_PATH}" "${backup_dir}"
}

# 功能：执行指定测试阶段或外部工具命令
run_restart_case() {
	run_isolated_case run_restart_case_impl "$@"
}

# 功能：执行单轮重启测试；由 run_restart_case 隔离运行状态
run_restart_case_impl() {
	local remark_value="$1"
	local archive_dir="$2"
	local case_failed=0

	init_items
	collect_data_before "${TEST_IOTDB_PATH}"
	start_iotdb
	sleep "${STARTUP_GRACE_SECONDS}"
	if ! monitor_test_status; then
		case_failed=1
	fi
	sleep "${STOP_WAIT_SECONDS}"
	stop_iotdb
	sleep "${STOP_WAIT_SECONDS}"
	check_iotdb_pid
	collect_data_after "${TEST_IOTDB_PATH}"
	insert_database "${remark_value}"
	archive_logs "${archive_dir}"

	return "${case_failed}"
}

# 功能：准备当前步骤所需的目录、配置或测试数据
prepare_test_data() {
	local source_data="${DATA_PATH}/data"

	[ -d "${source_data}" ] || die "missing restart data: ${source_data}"
	cp -rf "${source_data}" "${TEST_IOTDB_PATH}/"
}

# 功能：执行单个测试组合并收集、解析和保存结果
test_operation() {
	protocol_id="$1"
	ts_type="$2"
	data_type="$3"
	local task_failed=0

	log "start ${TEST_TYPE}: protocol=${protocol_id}, ts=${ts_type}, data=${data_type}"
	check_iotdb_pid
	set_env
	modify_iotdb_config
	prepare_test_data

	if ! run_restart_case "restart_db" "R1"; then
		task_failed=1
	fi
	if ! run_restart_case "restart_db_2" ""; then
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
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/iotdb_distribution_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/iotdb_service_common.sh"

main "$@"
