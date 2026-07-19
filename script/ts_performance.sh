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

	for cmd in awk cat cp date du find grep jps kill lsof mkdir mv mysql ps rm sed sudo tr wc; do
		require_command "${cmd}"
	done
}

check_password() {
	if [ -z "${MYSQL_PASSWORD}" ]; then
		die "ATMOS_DB_PASSWORD is not set."
	fi
}

mysql_exec() {
	local sql="$1"
	MYSQL_PWD="${MYSQL_PASSWORD}" mysql -N -B -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USERNAME}" "${DBNAME}" -e "${sql}"
}

sql_quote() {
	local value="${1:-}"
	value="${value//\\/\\\\}"
	value="$(printf '%s' "${value}" | sed "s/'/''/g")"
	printf "'%s'" "${value}"
}

update_task_status() {
	local status="$1"
	mysql_exec "update ${TASK_TABLENAME} set ${TEST_TYPE} = $(sql_quote "${status}") where commit_id = $(sql_quote "${commit_id}")"
}

mark_older_commits_skip() {
	mysql_exec "update ${TASK_TABLENAME} set ${TEST_TYPE} = 'skip' where ${TEST_TYPE} is NULL and commit_date_time < $(sql_quote "${commit_date_time}")"
}

query_next_commit() {
	local status_filter="$1"

	if [ "${status_filter}" = "retest" ]; then
		mysql_exec "SELECT commit_id, author, commit_date_time FROM ${TASK_TABLENAME} WHERE ${TEST_TYPE} = 'retest' ORDER BY commit_date_time desc LIMIT 1"
	else
		mysql_exec "SELECT commit_id, author, commit_date_time FROM ${TASK_TABLENAME} WHERE ${TEST_TYPE} is NULL ORDER BY commit_date_time desc LIMIT 1"
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

git_commit_abbrev() {
	awk -F= '/git.commit.id.abbrev/ {print $2; exit}' "$1" 2>/dev/null
}

path_is_safe() {
	local path="$1"

	[ -n "${path}" ] || return 1
	case "${path}" in
		/|/data|/nasdata|.)
			return 1
			;;
		"${INIT_PATH}"/*|"${TEST_INIT_PATH}"/*|"${BACKUP_PATH}"/*)
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

check_benchmark_version() {
	local bm_new=""
	local bm_old=""

	if [ ! -f "${BM_REPOS_PATH}/git.properties" ]; then
		log "skip benchmark sync, missing ${BM_REPOS_PATH}/git.properties"
		return 0
	fi

	bm_new="$(git_commit_abbrev "${BM_REPOS_PATH}/git.properties")"
	[ -n "${bm_new}" ] || return 0
	if [ -f "${BM_PATH}/git.properties" ]; then
		bm_old="$(git_commit_abbrev "${BM_PATH}/git.properties")"
	fi

	if [ ! -d "${BM_PATH}" ] || [ "${bm_old}" != "${bm_new}" ]; then
		log "sync benchmark to ${bm_new}"
		safe_rm "${BM_PATH}"
		cp -rf "${BM_REPOS_PATH}" "${BM_PATH}"
	fi
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
		kill -TERM "${pid}" 2>/dev/null || true
		sleep 2
		kill -KILL "${pid}" 2>/dev/null || true
	done <<< "${pids}"
	log "${desc} stopped."
}

check_benchmark_pid() {
	check_pid_and_kill "App" "benchmark"
}

check_iotdb_pid() {
	check_pid_and_kill "DataNode" "DataNode"
	check_pid_and_kill "ConfigNode" "ConfigNode"
	check_pid_and_kill "IoTDB" "IoTDB"
}

cleanup_processes() {
	check_benchmark_pid
	check_iotdb_pid
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
	copy_if_exists "${ATMOS_PATH}/conf/${TEST_TYPE}/license" "${TEST_IOTDB_PATH}/activation/" "license"
	mkdir -p "${TEST_IOTDB_PATH}/tools/testlog"
}

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

set_protocol_class() {
	local protocol_code="$1"
	local config_node="${protocol_code:0:1}"
	local schema_region="${protocol_code:1:1}"
	local data_region="${protocol_code:2:1}"

	[ "${#protocol_code}" -eq 3 ] || return 1
	[ -n "${protocol_class[${config_node}]:-}" ] || return 1
	[ -n "${protocol_class[${schema_region}]:-}" ] || return 1
	[ -n "${protocol_class[${data_region}]:-}" ] || return 1

	set_iotdb_property "config_node_consensus_protocol_class" "${protocol_class[${config_node}]}"
	set_iotdb_property "schema_region_consensus_protocol_class" "${protocol_class[${schema_region}]}"
	set_iotdb_property "data_region_consensus_protocol_class" "${protocol_class[${data_region}]}"
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

wait_for_iotdb_ready() {
	local attempt=0
	local iotdb_state=""

	for ((attempt = 1; attempt <= IOTDB_READY_RETRIES; attempt++)); do
		iotdb_state="$("${TEST_IOTDB_PATH}/sbin/start-cli.sh" -e "show cluster" 2>/dev/null | grep -F 'Total line number = 2' || true)"
		if [ "${iotdb_state}" = "Total line number = 2" ]; then
			return 0
		fi
		sleep "${IOTDB_READY_INTERVAL_SECONDS}"
	done
	return 1
}

run_iotdb_cli() {
	"${TEST_IOTDB_PATH}/sbin/start-cli.sh" -h 127.0.0.1 -p 6667 "$@"
}

table_cli_args() {
	printf '%s\n' "-sql_dialect" "table"
}

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

collect_data_before() {
	local collect_path="${1%/}"

	dataFileSize_before="$(dir_size_gb "${collect_path}/data")"
	numOfSe0Level_before="$(count_tsfiles "${collect_path}/data/datanode/data/sequence")"
	numOfUnse0Level_before="$(count_tsfiles "${collect_path}/data/datanode/data/unsequence")"
}

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

write_startup_error_result() {
	local remark_value="$1"

	cost_time=-3
	start_time="${start_time:-0}"
	end_time="${end_time:-0}"
	insert_database "${remark_value}"
	update_task_status "RError"
}

start_iotdb_or_record_error() {
	local remark_value="$1"

	start_iotdb
	sleep "${STARTUP_GRACE_SECONDS}"
	if wait_for_iotdb_ready; then
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

source_tsfile_path() {
	printf '%s\n' "${DATA_PATH}/${data_type}/${ts_type}"
}

ensure_source_tsfile_path() {
	local source_path=""

	source_path="$(source_tsfile_path)"
	[ -d "${source_path}" ] || die "missing tsfile data: ${source_path}"
}

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

archive_tool_log() {
	local archive_name="$1"
	local log_file="${TEST_IOTDB_PATH}/tools/testlog/log.txt"
	local target_log="${TEST_IOTDB_PATH}/tools/testlog/log.${archive_name}"

	if [ -f "${log_file}" ]; then
		mv "${log_file}" "${target_log}"
	fi
}

run_tool_operation() {
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

backup_test_data() {
	local current_ts_type="$1"
	local backup_parent="${BACKUP_PATH}/${current_ts_type}"
	local backup_dir="${backup_parent}/${commit_date_time}_${commit_id}_${protocol_id}"

	sudo_safe_rm "${backup_dir}"
	path_is_safe "${backup_parent}" || die "refuse to use unexpected backup path: ${backup_parent}"
	sudo mkdir -p -- "${backup_dir}"
	if [ -d "${TEST_IOTDB_PATH}/tools/testlog" ]; then
		sudo mv "${TEST_IOTDB_PATH}/tools/testlog" "${backup_dir}/"
	fi
	sudo_safe_rm "${TEST_IOTDB_PATH}/data"
	sudo_safe_rm "${TEST_IOTDB_PATH}/tools"
	path_is_safe "${TEST_IOTDB_PATH}" || die "refuse to move unexpected path: ${TEST_IOTDB_PATH}"
	sudo mv "${TEST_IOTDB_PATH}" "${backup_dir}"
}

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

mark_test_in_progress() {
	printf 'ontesting\n' > "${INIT_PATH}/test_type_file"
}

restore_test_type_file() {
	printf '%s\n' "${TEST_TYPE}" > "${INIT_PATH}/test_type_file"
}

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

main "$@"
