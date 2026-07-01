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
readonly test_type="compaction"

readonly INIT_PATH="/data/atmos/zk_test"
readonly ATMOS_PATH="${INIT_PATH}/atmos-ex"
readonly DATA_PATH="/data/atmos/DataSet"
readonly BUCKUP_PATH="/nasdata/repository/compaction"
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

readonly MYSQLHOSTNAME="111.200.37.158"
readonly PORT="13306"
readonly USERNAME="iotdbatm"
readonly PASSWORD="${ATMOS_DB_PASSWORD:-}"
readonly DBNAME="QA_ATM"
readonly TABLENAME="ex_compaction"
readonly TABLENAME_T="ex_compaction_T"
readonly TASK_TABLENAME="ex_commit_history"

readonly metric_server="111.200.37.158:19090"
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

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*"
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

normalize_datetime() {
	printf '%s' "$1" | tr -cd '0-9'
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令: $1"
}

ensure_runtime_dependencies() {
	local cmd=""

	for cmd in awk cat cp curl cut date du find grep jq jps kill lsof mkdir mv mysql ps rm sed sudo tail tr wc; do
		require_command "${cmd}"
	done
}

check_password() {
	if [ -z "${PASSWORD}" ]; then
		die "ATMOS_DB_PASSWORD 未设置，无法连接 MySQL。"
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
	path_is_safe "${path}" || die "拒绝删除非预期路径: ${path}"
	rm -rf -- "${path}"
}

sudo_safe_rm() {
	local path="$1"

	[ -e "${path}" ] || return 0
	path_is_safe "${path}" || die "拒绝删除非预期路径: ${path}"
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
	local name_pattern="$2"

	if [ ! -d "${target_dir}" ]; then
		printf '0\n'
	else
		find "${target_dir}" -name "${name_pattern}" | wc -l | tr -d '[:space:]'
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

check_pid_and_kill() {
	local pname="$1"
	local desc="$2"
	local pids=""
	local pid=""

	pids="$(jps | awk -v pname="${pname}" '$2 == pname {print $1}')"
	if [ -z "${pids}" ]; then
		log "未检测到${desc}。"
		return 0
	fi

	while IFS= read -r pid; do
		[ -n "${pid}" ] || continue
		kill -9 "${pid}" 2>/dev/null || true
	done <<< "${pids}"
	log "${desc} 已停止。"
}

check_iotdb_pid() {
	check_pid_and_kill "DataNode" "DataNode程序"
	check_pid_and_kill "ConfigNode" "ConfigNode程序"
	check_pid_and_kill "IoTDB" "IoTDB程序"
}

set_iotdb_property() {
	local key="$1"
	local value="$2"
	local conf_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"

	[ -f "${conf_file}" ] || die "缺少配置文件: ${conf_file}"
	if grep -q "^[[:space:]]*${key}[[:space:]]*=" "${conf_file}"; then
		sed -i "s|^[[:space:]]*${key}[[:space:]]*=.*$|${key}=${value}|g" "${conf_file}"
	else
		printf '%s=%s\n' "${key}" "${value}" >> "${conf_file}"
	fi
}

set_env() {
	local source_path="${REPOS_PATH}/${commit_id}/apache-iotdb"

	[ -d "${source_path}" ] || die "缺少待测版本目录: ${source_path}"
	safe_rm "${TEST_IOTDB_PATH}"
	mkdir -p "${TEST_IOTDB_PATH}/activation"
	cp -rf "${source_path}/." "${TEST_IOTDB_PATH}/"
	copy_if_exists "${ATMOS_PATH}/conf/${test_type}/license" "${TEST_IOTDB_PATH}/activation/" "license"
}

modify_iotdb_config() {
	local datanode_env="${TEST_IOTDB_PATH}/conf/datanode-env.sh"

	[ -f "${datanode_env}" ] || die "缺少配置文件: ${datanode_env}"
	sed -i 's/^#\?ON_HEAP_MEMORY=.*$/ON_HEAP_MEMORY="20G"/' "${datanode_env}"

	set_iotdb_property "series_slot_num" "10000"
	set_iotdb_property "target_compaction_file_size" "1073741824"
	set_iotdb_property "enable_seq_space_compaction" "false"
	set_iotdb_property "enable_unseq_space_compaction" "false"
	set_iotdb_property "enable_cross_space_compaction" "false"
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

wait_iotdb_ready() {
	local retry_count="$1"
	local sleep_seconds="$2"
	local attempt=0
	local iotdb_state=""

	for ((attempt = 0; attempt <= retry_count; attempt++)); do
		iotdb_state="$("${TEST_IOTDB_PATH}/sbin/start-cli.sh" -e "show cluster" 2>/dev/null | grep -F 'Total line number = 2' || true)"
		if [ "${iotdb_state}" = "Total line number = 2" ]; then
			return 0
		fi
		sleep "${sleep_seconds}"
	done
	return 1
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

write_timeout_compaction_log() {
	local log_compaction="${TEST_IOTDB_PATH}/logs/log_datanode_compaction.log"

	mkdir -p "${log_compaction%/*}"
	cat >> "${log_compaction}" <<EOF
$(current_datetime),000 [pool-21-IoTDB-Compaction-1] INFO  o.a.i.d.e.c.c.CrossSpaceCompactionTask:207 - root.test.g_0-1 [Compaction] CrossSpaceCompaction task finishes successfully, time cost is -1 s, compaction speed is 0 MB/s
$(current_datetime),000 [pool-21-IoTDB-Compaction-1] INFO  o.a.i.d.e.c.i.InnerSpaceCompactionTask:239 - root.test.g_0-1 [Compaction] InnerSpaceCompaction task finishes successfully, target file is timeout.tsfile,time cost is -1 s, compaction speed is 0 MB/s
EOF
}

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

collect_data_before() {
	dataFileSize_before="$(dir_size_gb "${TEST_IOTDB_PATH}/data")"
	numOfSe0Level_before="$(count_tsfiles "${TEST_IOTDB_PATH}/data/datanode/data/sequence" "*-0-*.tsfile")"
	numOfUnse0Level_before="$(count_tsfiles "${TEST_IOTDB_PATH}/data/datanode/data/unsequence" "*-0-*.tsfile")"
}

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

get_single_index() {
	local query="$1"
	local end="$2"
	local index_value=""

	index_value="$(
		curl -G -s "http://${metric_server}/api/v1/query" \
			--data-urlencode "query=${query}" \
			--data-urlencode "time=${end}" \
			| jq -r '.data.result[0].value[1] // 0'
	)"
	if [ "${index_value}" = "null" ] || [ -z "${index_value}" ]; then
		index_value=0
	fi
	printf '%s\n' "${index_value}"
}

get_iotdb_property_value() {
	local properties_file="$1"
	local property_key="$2"

	awk -v property_key="${property_key}" '
		/^[[:space:]]*#/ { next }
		{
			line = $0
			sub(/\r$/, "", line)
			if (line ~ "^[[:space:]]*" property_key "[[:space:]]*=") {
				sub("^[[:space:]]*" property_key "[[:space:]]*=[[:space:]]*", "", line)
				last_value = line
			}
		}
		END {
			if (last_value != "") {
				print last_value
			}
		}
	' "${properties_file}"
}

split_iotdb_path_list() {
	local value="$1"
	local item=""
	local -a items=()

	value="${value//;/,}"
	value="${value//\"/}"
	IFS=',' read -r -a items <<< "${value}"
	for item in "${items[@]}"; do
		item="$(trim "${item}")"
		[ -n "${item}" ] || continue
		printf '%s\n' "${item}"
	done
}

normalize_monitor_target_path() {
	local path="$1"

	path="$(trim "${path}")"
	path="${path%/}"
	case "${path}" in
		/*)
			printf '%s\n' "${path}"
			;;
		*)
			printf '%s\n' "${TEST_IOTDB_PATH}/${path}"
			;;
	esac
}

get_monitor_disk_target_paths() {
	local properties_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
	local property_key=""
	local property_value=""
	local raw_path=""
	local found_configured_path=0
	local -a property_keys=(dn_data_dirs dn_wal_dirs)

	if [ -f "${properties_file}" ]; then
		for property_key in "${property_keys[@]}"; do
			property_value="$(get_iotdb_property_value "${properties_file}" "${property_key}")"
			[ -n "${property_value}" ] || continue
			while IFS= read -r raw_path; do
				[ -n "${raw_path}" ] || continue
				normalize_monitor_target_path "${raw_path}"
				found_configured_path=1
			done < <(split_iotdb_path_list "${property_value}")
		done
	fi

	if [ "${found_configured_path}" -eq 0 ]; then
		printf '%s\n' "${TEST_IOTDB_PATH}/data"
	fi
}

find_existing_monitor_path() {
	local path="$1"

	while [ ! -e "${path}" ] && [ "${path}" != "/" ]; do
		path="${path%/*}"
		[ -n "${path}" ] || path="/"
	done
	[ -e "${path}" ] || return 1
	printf '%s\n' "${path}"
}

contains_value() {
	local expected="$1"
	shift
	local actual=""

	for actual in "$@"; do
		[ "${actual}" = "${expected}" ] && return 0
	done
	return 1
}

build_disk_id_regex() {
	local regex=""
	local current_disk_id=""

	for current_disk_id in "$@"; do
		if [ -z "${regex}" ]; then
			regex="${current_disk_id}"
		else
			regex="${regex}|${current_disk_id}"
		fi
	done
	[ -n "${regex}" ] || regex="${DEFAULT_DISK_ID}"
	printf '^(%s)$\n' "${regex}"
}

detect_disk_id_from_path() {
	local target_path="$1"
	local existing_path=""
	local source_device=""
	local resolved_device=""
	local parent_device=""

	command -v findmnt >/dev/null 2>&1 || return 1
	command -v lsblk >/dev/null 2>&1 || return 1

	existing_path="$(find_existing_monitor_path "${target_path}" || true)"
	[ -n "${existing_path}" ] || return 1
	source_device="$(findmnt -no SOURCE --target "${existing_path}" 2>/dev/null | awk 'NF {print; exit}')"
	[ -n "${source_device}" ] || return 1

	source_device="${source_device%%[*}"
	if command -v readlink >/dev/null 2>&1; then
		resolved_device="$(readlink -f "${source_device}" 2>/dev/null || printf '%s\n' "${source_device}")"
	else
		resolved_device="${source_device}"
	fi
	[ -b "${resolved_device}" ] || return 1

	while true; do
		parent_device="$(lsblk -ndo PKNAME "${resolved_device}" 2>/dev/null | awk 'NF {print; exit}')"
		[ -n "${parent_device}" ] || break
		resolved_device="/dev/${parent_device}"
	done
	printf '%s\n' "${resolved_device##*/}"
}

resolve_monitor_disk_id() {
	local target_path=""
	local detected_disk_id=""
	local -a detected_disk_ids=()
	local -a monitor_target_paths=()

	disk_id_regex="^${DEFAULT_DISK_ID}$"
	while IFS= read -r target_path; do
		[ -n "${target_path}" ] || continue
		monitor_target_paths+=("${target_path}")
		detected_disk_id="$(detect_disk_id_from_path "${target_path}" || true)"
		[ -n "${detected_disk_id}" ] || continue
		if ! contains_value "${detected_disk_id}" "${detected_disk_ids[@]:-}"; then
			detected_disk_ids+=("${detected_disk_id}")
		fi
	done < <(get_monitor_disk_target_paths)

	if [ "${#detected_disk_ids[@]:-}" -gt 0 ]; then
		disk_id_regex="$(build_disk_id_regex "${detected_disk_ids[@]:-}")"
		log "resolved disk ids ${detected_disk_ids[*]:-} from ${monitor_target_paths[*]:-}"
	else
		log "failed to resolve disk ids from ${monitor_target_paths[*]:-${TEST_IOTDB_PATH}}, fallback to ${DEFAULT_DISK_ID}"
	fi
}

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

backup_test_data() {
	local current_ts_type="$1"
	local backup_parent="${BUCKUP_PATH}/${current_ts_type}"
	local backup_dir="${backup_parent}/${commit_date_time}_${commit_id}_${protocol_id}"

	sudo_safe_rm "${backup_dir}"
	path_is_safe "${backup_parent}" || die "拒绝使用非预期备份路径: ${backup_parent}"
	sudo mkdir -p -- "${backup_dir}"
	sudo_safe_rm "${TEST_IOTDB_PATH}/data"
	path_is_safe "${TEST_IOTDB_PATH}" || die "拒绝移动非预期路径: ${TEST_IOTDB_PATH}"
	sudo mv "${TEST_IOTDB_PATH}" "${backup_dir}"
}

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

mark_restart_error() {
	local remark_value="$1"

	cost_time=-3
	comp_start_time=0
	comp_end_time=0
	insert_database "${remark_value}"
	update_task_status "RError"
}

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

mark_test_in_progress() {
	printf 'ontesting\n' > "${INIT_PATH}/test_type_file"
}

restore_test_type_file() {
	printf '%s\n' "${test_type}" > "${INIT_PATH}/test_type_file"
}

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

main "$@"
