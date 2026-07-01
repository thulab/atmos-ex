#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
	exec bash "$0" "$@"
fi
if shopt -oq posix; then
	exec bash "${BASH_SOURCE[0]}" "$@"
fi

set -u
set -o pipefail

readonly test_type="restart_db"

readonly INIT_PATH="/data/atmos/zk_test"
readonly ATMOS_PATH="${INIT_PATH}/atmos-ex"
readonly DATA_PATH="/data/atmos/DataSet"
readonly BUCKUP_PATH="/nasdata/repository/restart_db"
readonly REPOS_PATH="/nasdata/repository/master"

readonly TEST_INIT_PATH="/data/atmos"
readonly TEST_IOTDB_PATH="${TEST_INIT_PATH}/apache-iotdb"

readonly MYSQLHOSTNAME="111.200.37.158"
readonly PORT="13306"
readonly USERNAME="iotdbatm"
readonly PASSWORD="${ATMOS_DB_PASSWORD:-}"
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

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

die() {
	log "ERROR: $*"
	exit 1
}

trim() {
	local value="${1:-}"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "${value}"
}

current_datetime() {
	date '+%Y-%m-%d %H:%M:%S'
}

datetime_to_epoch() {
	date -d "$1" +%s
}

normalize_datetime() {
	printf '%s' "$1" | tr -cd '0-9'
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

ensure_runtime_dependencies() {
	local cmd=""

	for cmd in awk cat cp cut date du find grep jps kill lsof mkdir mv mysql ps rm sed sudo tr wc; do
		require_command "${cmd}"
	done
}

check_password() {
	if [ -z "${PASSWORD}" ]; then
		die "ATMOS_DB_PASSWORD is not set."
	fi
}

mysql_exec() {
	local sql="$1"
	MYSQL_PWD="${PASSWORD}" mysql -N -B -h"${MYSQLHOSTNAME}" -P"${PORT}" -u"${USERNAME}" "${DBNAME}" -e "${sql}"
}

sql_quote() {
	local value="${1:-}"
	value="${value//\\/\\\\}"
	value="$(printf '%s' "${value}" | sed "s/'/''/g")"
	printf "'%s'" "${value}"
}

update_task_status() {
	local status="$1"
	mysql_exec "update ${TASK_TABLENAME} set ${test_type} = $(sql_quote "${status}") where commit_id = $(sql_quote "${commit_id}")"
}

mark_older_commits_skip() {
	mysql_exec "update ${TASK_TABLENAME} set ${test_type} = 'skip' where ${test_type} is NULL and commit_date_time < $(sql_quote "${commit_date_time}")"
}

query_next_commit() {
	local status_filter="$1"

	if [ "${status_filter}" = "retest" ]; then
		mysql_exec "SELECT commit_id, author, commit_date_time FROM ${TASK_TABLENAME} WHERE ${test_type} = 'retest' ORDER BY commit_date_time desc LIMIT 1"
	else
		mysql_exec "SELECT commit_id, author, commit_date_time FROM ${TASK_TABLENAME} WHERE ${test_type} is NULL ORDER BY commit_date_time desc LIMIT 1"
	fi
}

fetch_next_commit() {
	local row=""
	local raw_commit_date_time=""

	row="$(query_next_commit "retest")"
	if [ -z "${row}" ]; then
		row="$(query_next_commit "pending")"
	fi
	[ -n "${row}" ] || return 1

	IFS=$'\t' read -r commit_id author raw_commit_date_time <<< "${row}"
	author="$(trim "${author}")"
	commit_date_time="$(normalize_datetime "${raw_commit_date_time}")"
	[ -n "${commit_id}" ] && [ -n "${commit_date_time}" ]
}

path_is_safe() {
	local path="$1"

	[ -n "${path}" ] || return 1
	case "${path}" in
		/|/data|/nasdata|.)
			return 1
			;;
		"${INIT_PATH}"/*|"${TEST_INIT_PATH}"/*|"${BUCKUP_PATH}"/*)
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
	path_is_safe "${path}" || die "refuse to remove unexpected path: ${path}"
	rm -rf -- "${path}"
}

sudo_safe_rm() {
	local path="$1"

	[ -e "${path}" ] || return 0
	path_is_safe "${path}" || die "refuse to remove unexpected path: ${path}"
	sudo rm -rf -- "${path}"
}

copy_if_exists() {
	local source="$1"
	local target="$2"
	local label="${3:-$1}"

	if [ ! -e "${source}" ]; then
		log "skip copy, missing ${label}: ${source}"
		return 0
	fi

	cp -rf -- "${source}" "${target}"
}

dir_size_gb() {
	local target_dir="$1"

	if [ ! -d "${target_dir}" ]; then
		printf '0\n'
	else
		du -sk "${target_dir}" 2>/dev/null | awk '{printf "%.2f\n", $1 / 1048576}'
	fi
}

count_tsfiles() {
	local target_dir="$1"

	if [ ! -d "${target_dir}" ]; then
		printf '0\n'
	else
		find "${target_dir}" -name "*.tsfile" | wc -l | tr -d '[:space:]'
	fi
}

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

check_pid_and_kill() {
	local pname="$1"
	local desc="$2"
	local pids=""
	local pid=""

	pids="$(jps | awk -v pname="${pname}" '$2 == pname {print $1}')"
	if [ -z "${pids}" ]; then
		log "no ${desc} process found."
		return 0
	fi

	while IFS= read -r pid; do
		[ -n "${pid}" ] || continue
		kill -9 "${pid}" 2>/dev/null || true
	done <<< "${pids}"
	log "${desc} stopped."
}

check_iotdb_pid() {
	check_pid_and_kill "DataNode" "DataNode"
	check_pid_and_kill "ConfigNode" "ConfigNode"
	check_pid_and_kill "IoTDB" "IoTDB"
}

process_pids() {
	local process_name="$1"
	jps | awk -v process_name="${process_name}" '$2 == process_name {print $1}'
}

refresh_max_process_metrics() {
	local process_name=""
	local pid=""
	local open_files=0
	local threads=0
	local total_open_files=0
	local total_threads=0

	for process_name in DataNode ConfigNode IoTDB; do
		while IFS= read -r pid; do
			[ -n "${pid}" ] || continue
			open_files="$(lsof -p "${pid}" 2>/dev/null | wc -l | tr -d '[:space:]')"
			threads="$(ps -o nlwp= -p "${pid}" 2>/dev/null | awk '{sum += $1} END {print sum + 0}')"
			total_open_files=$((total_open_files + open_files))
			total_threads=$((total_threads + threads))
		done < <(process_pids "${process_name}")
	done

	if [ "${maxNumofOpenFiles}" -lt "${total_open_files}" ]; then
		maxNumofOpenFiles="${total_open_files}"
	fi
	if [ "${maxNumofThread}" -lt "${total_threads}" ]; then
		maxNumofThread="${total_threads}"
	fi
}

set_iotdb_property() {
	local key="$1"
	local value="$2"
	local conf_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"

	[ -f "${conf_file}" ] || die "missing config file: ${conf_file}"
	if grep -q "^[[:space:]]*${key}[[:space:]]*=" "${conf_file}"; then
		sed -i "s|^[[:space:]]*${key}[[:space:]]*=.*$|${key}=${value}|g" "${conf_file}"
	else
		printf '%s=%s\n' "${key}" "${value}" >> "${conf_file}"
	fi
}

set_env() {
	local source_path="${REPOS_PATH}/${commit_id}/apache-iotdb"

	[ -d "${source_path}" ] || die "missing IoTDB build: ${source_path}"
	safe_rm "${TEST_IOTDB_PATH}"
	mkdir -p "${TEST_IOTDB_PATH}/activation"
	cp -rf "${source_path}/." "${TEST_IOTDB_PATH}/"
	copy_if_exists "${ATMOS_PATH}/conf/${test_type}/license" "${TEST_IOTDB_PATH}/activation/" "license"
}

modify_iotdb_config() {
	local datanode_env="${TEST_IOTDB_PATH}/conf/datanode-env.sh"

	[ -f "${datanode_env}" ] || die "missing config file: ${datanode_env}"
	sed -i 's/^#\?ON_HEAP_MEMORY=.*$/ON_HEAP_MEMORY="20G"/' "${datanode_env}"

	set_iotdb_property "cluster_name" "${test_type}"
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

start_iotdb() {
	(
		cd "${TEST_IOTDB_PATH}" || exit 1
		./sbin/start-confignode.sh >/dev/null 2>&1 &
	)
	sleep "${STARTUP_GRACE_SECONDS}"
	(
		cd "${TEST_IOTDB_PATH}" || exit 1
		./sbin/start-datanode.sh -H "${TEST_IOTDB_PATH}/dn_dump.hprof" >/dev/null 2>&1 &
	)
}

stop_iotdb() {
	[ -d "${TEST_IOTDB_PATH}" ] || return 0
	(
		cd "${TEST_IOTDB_PATH}" || exit 1
		./sbin/stop-datanode.sh >/dev/null 2>&1 &
	)
	sleep "${STARTUP_GRACE_SECONDS}"
	(
		cd "${TEST_IOTDB_PATH}" || exit 1
		./sbin/stop-confignode.sh >/dev/null 2>&1 &
	)
}

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

can_query_iotdb_after_startup() {
	local iotdb_state=""

	iotdb_state="$("${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw root -e "show cluster" 2>/dev/null | grep -F 'Total line number = 2' || true)"
	[ "${iotdb_state}" = "Total line number = 2" ]
}

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

collect_data_before() {
	local collect_path="${1%/}"

	dataFileSize_before="$(dir_size_gb "${collect_path}/data/datanode/data")"
	numOfSe0Level_before="$(count_tsfiles "${collect_path}/data/datanode/data/sequence")"
	numOfUnse0Level_before="$(count_tsfiles "${collect_path}/data/datanode/data/unsequence")"
	WALSize_before="$(dir_size_gb "${collect_path}/data/datanode/wal")"
}

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

archive_logs() {
	local archive_dir_name="$1"
	local archive_dir="${TEST_IOTDB_PATH}/${archive_dir_name}"

	if [ -z "${archive_dir_name}" ] || [ ! -d "${TEST_IOTDB_PATH}/logs" ]; then
		return 0
	fi

	mkdir -p "${archive_dir}"
	mv "${TEST_IOTDB_PATH}/logs" "${archive_dir}/"
}

backup_test_data() {
	local current_ts_type="$1"
	local backup_parent="${BUCKUP_PATH}/${current_ts_type}"
	local backup_dir="${backup_parent}/${commit_date_time}_${commit_id}_${protocol_id}"

	sudo_safe_rm "${backup_dir}"
	path_is_safe "${backup_parent}" || die "refuse to use unexpected backup path: ${backup_parent}"
	sudo mkdir -p -- "${backup_dir}"
	sudo_safe_rm "${TEST_IOTDB_PATH}/data"
	path_is_safe "${TEST_IOTDB_PATH}" || die "refuse to move unexpected path: ${TEST_IOTDB_PATH}"
	sudo mv "${TEST_IOTDB_PATH}" "${backup_dir}"
}

run_restart_case() {
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

prepare_test_data() {
	local source_data="${DATA_PATH}/data"

	[ -d "${source_data}" ] || die "missing restart data: ${source_data}"
	cp -rf "${source_data}" "${TEST_IOTDB_PATH}/"
}

test_operation() {
	protocol_id="$1"
	ts_type="$2"
	data_type="$3"
	local task_failed=0

	log "start ${test_type}: protocol=${protocol_id}, ts=${ts_type}, data=${data_type}"
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

mark_test_in_progress() {
	printf 'ontesting\n' > "${INIT_PATH}/test_type_file"
}

restore_test_type_file() {
	printf '%s\n' "${test_type}" > "${INIT_PATH}/test_type_file"
}

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
	log "current commit ${commit_id} starts ${test_type}"
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

main "$@"
