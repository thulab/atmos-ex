#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
	exec bash "$0" "$@"
fi
if shopt -oq posix; then
	exec bash "${BASH_SOURCE[0]}" "$@"
fi

set -u
set -o pipefail

readonly ACCOUNT="atmos"
readonly IOTDB_PASSWORD="TimechoDB@2021"
readonly TEST_TYPE="count_ts"

readonly INIT_PATH="/data/atmos/zk_test"
readonly ATMOS_PATH="${INIT_PATH}/atmos-ex"
readonly BM_PATH="${INIT_PATH}/iot-benchmark"
readonly BM_REPOS_PATH="/nasdata/repository/iot-benchmark"
readonly BACKUP_PATH="/nasdata/repository/count_ts"
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
readonly -a ts_list=(common aligned template tempaligned)

readonly MYSQL_HOST="111.200.37.158"
readonly MYSQL_PORT="13306"
readonly MYSQL_USERNAME="iotdbatm"
readonly MYSQL_PASSWORD="${ATMOS_DB_PASSWORD:-}"
readonly DBNAME="QA_ATM"
readonly TABLENAME="ex_count_ts"
readonly TABLENAME_T="ex_count_ts_T"
readonly TASK_TABLENAME="ex_commit_history"

readonly MONITOR_TIMEOUT_SECONDS=7200
readonly MONITOR_POLL_INTERVAL_SECONDS=10
readonly IOTDB_READY_RETRIES=10
readonly IOTDB_READY_INTERVAL_SECONDS=5
readonly STARTUP_GRACE_SECONDS=10
readonly BENCHMARK_WARMUP_SECONDS=60
readonly STOP_WAIT_SECONDS=30

result_table="${TABLENAME}"
commit_id=""
author=""
commit_date_time=""
test_date_time=""
start_time=""
end_time=""
cost_time=0
createCost_all=0
createCost_common=0
createCost_aligned=0
createCost_template=0
createCost_tempaligned=0
countCost_all=0
countCost_common=0
countCost_aligned=0
countCost_template=0
countCost_tempaligned=0
showCost_all=0
showCost_common=0
showCost_aligned=0
showCost_template=0
showCost_tempaligned=0
numOfSe0Level=0
numOfUnse0Level=0
dataFileSize=0
maxNumofOpenFiles=0
maxNumofThread=0
errorLogSize=0

# 功能：比较本地与仓库版本并同步 IoT-Benchmark
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

# 功能：重置当前测试用例使用的指标和运行状态
init_items() {
	start_time=""
	end_time=""
	cost_time=0
	createCost_all=0
	createCost_common=0
	createCost_aligned=0
	createCost_template=0
	createCost_tempaligned=0
	countCost_all=0
	countCost_common=0
	countCost_aligned=0
	countCost_template=0
	countCost_tempaligned=0
	showCost_all=0
	showCost_common=0
	showCost_aligned=0
	showCost_template=0
	showCost_tempaligned=0
	numOfSe0Level=0
	numOfUnse0Level=0
	dataFileSize=0
	maxNumofOpenFiles=0
	maxNumofThread=0
	errorLogSize=0
}

# 功能：按当前测试场景修改 IoTDB 配置
modify_iotdb_config() {
	local datanode_env="${TEST_IOTDB_PATH}/conf/datanode-env.sh"
	local confignode_env="${TEST_IOTDB_PATH}/conf/confignode-env.sh"

	[ -f "${datanode_env}" ] || die "missing config file: ${datanode_env}"
	sed -i 's/^#\?ON_HEAP_MEMORY=.*$/ON_HEAP_MEMORY="20G"/' "${datanode_env}"
	if [ -f "${confignode_env}" ]; then
		sed -i 's/^#\?ON_HEAP_MEMORY=.*$/ON_HEAP_MEMORY="6G"/' "${confignode_env}"
	fi

	set_iotdb_property "schema_engine_mode" "PBTree"
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

# 功能：清理运行目录并启动 IoT-Benchmark
start_benchmark() {
	safe_rm "${BM_PATH}/logs"
	safe_rm "${BM_PATH}/data"
	(
		cd "${BM_PATH}" || exit 1
		./benchmark.sh >/dev/null 2>&1 &
	)
}

# 功能：定位 Benchmark 生成的结果 CSV 文件
find_result_csv() {
	local had_nullglob=0
	local files=()

	if shopt -q nullglob; then
		had_nullglob=1
	else
		shopt -s nullglob
	fi

	files=("${BM_PATH}/data/csvOutput/"*result.csv)
	if [ "${had_nullglob}" -eq 0 ]; then
		shopt -u nullglob
	fi

	if [ "${#files[@]}" -gt 0 ]; then
		printf '%s\n' "${files[0]}"
	fi
}

# 功能：创建当前测试需要的数据、文件或数据库对象
create_stuck_schema_csv() {
	local csv_file="${BM_PATH}/data/csvOutput/Stuck_result.csv"
	local index=0

	mkdir -p "${csv_file%/*}"
	: > "${csv_file}"
	for ((index = 0; index < 100; index++)); do
		printf 'Schema cost(s),-1\n' >> "${csv_file}"
	done
}

# 功能：轮询测试进程和结果文件，处理完成或超时状态
monitor_test_status() {
	local csv_file=""
	local monitor_start_epoch=0
	local now_epoch=0
	local elapsed=0

	monitor_start_epoch="$(date +%s)"
	while true; do
		refresh_max_process_metrics
		csv_file="$(find_result_csv || true)"
		if [ -n "${csv_file}" ]; then
			end_time="$(current_datetime)"
			log "benchmark finished: ${csv_file}"
			return 0
		fi

		now_epoch="$(date +%s)"
		elapsed=$((now_epoch - monitor_start_epoch))
		if [ "${elapsed}" -ge "${MONITOR_TIMEOUT_SECONDS}" ]; then
			end_time="$(current_datetime)"
			log "benchmark timeout, create fallback result."
			create_stuck_schema_csv
			return 1
		fi
		sleep "${MONITOR_POLL_INTERVAL_SECONDS}"
	done
}

# 功能：从 Benchmark CSV 中提取元数据创建耗时
schema_cost_from_csv() {
	local csv_file=""
	local schema_cost=""

	csv_file="$(find_result_csv || true)"
	if [ -z "${csv_file}" ]; then
		printf '%s\n' "-1"
		return 0
	fi

	schema_cost="$(awk -F, '
		/^Schema/ {
			value = $2
			gsub(/^[ \t]+|[ \t]+$/, "", value)
			print value
			exit
		}
	' "${csv_file}")"
	if [ -z "${schema_cost}" ]; then
		schema_cost=-1
	fi
	printf '%s\n' "${schema_cost}"
}

# 功能：使用当前场景参数执行 IoTDB CLI 命令
run_iotdb_cli() {
	"${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw "${IOTDB_PASSWORD}" -h 127.0.0.1 -p 6667 "$@"
}

# 功能：从命令输出、日志或结果文件中提取目标值
extract_elapsed_seconds() {
	awk '
		/^It/ {
			value = $3
			gsub(/[^0-9. -]/, "", value)
			print value
			exit
		}
	' "$1" 2>/dev/null
}

# 功能：执行指定测试阶段或外部工具命令
run_count_cost() {
	local cost_name="$1"
	local sql="$2"
	local log_file="${TEST_IOTDB_PATH}/countCost_${cost_name}.log"
	local elapsed=""

	safe_rm "${log_file}"
	log "count timeseries: ${sql}"
	run_iotdb_cli -timeout 6000 -e "${sql}" >> "${log_file}" 2>&1 || true
	elapsed="$(extract_elapsed_seconds "${log_file}")"
	if [ -z "${elapsed}" ]; then
		elapsed=-1
	fi
	printf '%s\n' "${elapsed}"
}

# 功能：执行指定测试阶段或外部工具命令
run_show_cost() {
	local cost_name="$1"
	local sql="$2"
	local log_file="${TEST_IOTDB_PATH}/showCost_${cost_name}.log"
	local start_epoch=0
	local end_epoch=0

	safe_rm "${log_file}"
	log "show timeseries: ${sql}"
	start_epoch="$(date +%s)"
	run_iotdb_cli -timeout 20000 -e "${sql}" >> "${log_file}" 2>&1 || true
	end_epoch="$(date +%s)"
	printf '%s\n' "$((end_epoch - start_epoch))"
}

# 功能：选择并安装当前用例对应的配置文件
mv_config_file() {
	local current_ts_type="$1"
	local config_source="${ATMOS_PATH}/conf/${TEST_TYPE}/${current_ts_type}"
	local config_target="${BM_PATH}/conf/config.properties"

	[ -f "${config_source}" ] || die "missing benchmark config: ${config_source}"
	safe_rm "${config_target}"
	cp -rf "${config_source}" "${config_target}"
}

# 功能：采集当前测试窗口内的资源和文件指标
collect_monitor_data() {
	local datanode_error_log_file="${TEST_IOTDB_PATH}/logs/log_datanode_error.log"
	local confignode_error_log_file="${TEST_IOTDB_PATH}/logs/log_confignode_error.log"

	dataFileSize="$(dir_size_gb "${TEST_IOTDB_PATH}/data")"
	numOfSe0Level="$(count_tsfiles "${TEST_IOTDB_PATH}/data/datanode/data/sequence")"
	numOfUnse0Level="$(count_tsfiles "${TEST_IOTDB_PATH}/data/datanode/data/unsequence")"
	if [ -s "${datanode_error_log_file}" ] || [ -s "${confignode_error_log_file}" ]; then
		errorLogSize=1
	else
		errorLogSize=0
	fi
}

# 功能：将当前场景采集的指标写入结果数据库
insert_database() {
	local protocol_code="$1"
	local insert_sql=""

	insert_sql=$(cat <<EOF
insert into ${result_table} (
	commit_date_time,test_date_time,commit_id,author,start_time,end_time,cost_time,
	createCost_all,createCost_common,createCost_aligned,createCost_template,createCost_tempaligned,
	countCost_all,countCost_common,countCost_aligned,countCost_template,countCost_tempaligned,
	showCost_all,showCost_common,showCost_aligned,showCost_template,showCost_tempaligned,
	numOfSe0Level,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,remark
) values (
	${commit_date_time},
	${test_date_time},
	$(sql_quote "${commit_id}"),
	$(sql_quote "${author}"),
	$(sql_quote "${start_time}"),
	$(sql_quote "${end_time}"),
	${cost_time},
	${createCost_all},
	${createCost_common},
	${createCost_aligned},
	${createCost_template},
	${createCost_tempaligned},
	${countCost_all},
	${countCost_common},
	${countCost_aligned},
	${countCost_template},
	${countCost_tempaligned},
	${showCost_all},
	${showCost_common},
	${showCost_aligned},
	${showCost_template},
	${showCost_tempaligned},
	${numOfSe0Level},
	${numOfUnse0Level},
	$(sql_quote "${dataFileSize}"),
	${maxNumofOpenFiles},
	${maxNumofThread},
	${errorLogSize},
	$(sql_quote "${protocol_code}")
)
EOF
)

	mysql_exec "${insert_sql}"
	log "${insert_sql}"
}

# 功能：向配置、结果或备注中追加当前值
append_show_results() {
	local cost_name=""
	local log_file=""
	local show_result="${TEST_IOTDB_PATH}/showResult.log"
	local had_nullglob=0
	local removable_logs=()

	for cost_name in all common aligned template tempaligned; do
		log_file="${TEST_IOTDB_PATH}/showCost_${cost_name}.log"
		if [ -f "${log_file}" ]; then
			tail -n 1 "${log_file}" >> "${show_result}"
		fi
	done

	if shopt -q nullglob; then
		had_nullglob=1
	else
		shopt -s nullglob
	fi
	removable_logs=("${TEST_IOTDB_PATH}"/showCost_*.log)
	if [ "${had_nullglob}" -eq 0 ]; then
		shopt -u nullglob
	fi
	for log_file in "${removable_logs[@]}"; do
		safe_rm "${log_file}"
	done
}

# 功能：归档测试日志、配置、数据或结果文件
backup_test_data() {
	local protocol_code="$1"
	local backup_parent="${BACKUP_PATH}/${protocol_code}"
	local backup_dir="${backup_parent}/${commit_date_time}_${commit_id}_${protocol_code}"

	sudo_safe_rm "${backup_dir}"
	path_is_safe "${backup_parent}" || die "refuse to use unexpected backup path: ${backup_parent}"
	sudo mkdir -p -- "${backup_dir}"
	sudo_safe_rm "${TEST_IOTDB_PATH}/data"
	path_is_safe "${TEST_IOTDB_PATH}" || die "refuse to move unexpected path: ${TEST_IOTDB_PATH}"
	sudo mv "${TEST_IOTDB_PATH}" "${backup_dir}"
	if [ -d "${BM_PATH}/data/csvOutput" ]; then
		sudo cp -rf "${BM_PATH}/data/csvOutput" "${backup_dir}/"
	fi
}

# 功能：执行指定测试阶段或外部工具命令
run_schema_benchmark() {
	local current_ts_type="$1"

	mv_config_file "${current_ts_type}"
	log "create ${current_ts_type} timeseries"
	start_benchmark
	sleep "${BENCHMARK_WARMUP_SECONDS}"
	monitor_test_status
	schema_cost_from_csv
}

# 功能：写入当前测试的日志、状态或失败结果
write_startup_error_result() {
	local protocol_code="$1"
	local startup_cost="$2"

	end_time="$(current_datetime)"
	cost_time="${startup_cost}"
	insert_database "${protocol_code}"
	update_task_status "RError"
}

# 功能：执行单个测试组合并收集、解析和保存结果
test_operation() {
	local protocol_code="$1"
	local monitor_failed=0
	local -a schema_costs=(0 0 0 0)
	local index=0

	log "start count_ts protocol ${protocol_code}"
	init_items
	cleanup_processes
	set_env
	modify_iotdb_config
	if ! set_protocol_class "${protocol_code}"; then
		log "invalid protocol: ${protocol_code}"
		return 1
	fi

	start_iotdb
	start_time="$(current_datetime)"
	sleep "${STARTUP_GRACE_SECONDS}"
	if ! wait_for_iotdb_ready; then
		log "IoTDB startup failed."
		cost_time=-3
		write_startup_error_result "${protocol_code}" "-3"
		cleanup_processes
		return 1
	fi

	if ! change_root_password; then
		log "root password change failed."
		cost_time=-4
		write_startup_error_result "${protocol_code}" "-4"
		cleanup_processes
		return 1
	fi

	refresh_max_process_metrics
	for index in "${!ts_list[@]}"; do
		schema_costs[${index}]="$(run_schema_benchmark "${ts_list[${index}]}")" || monitor_failed=1
	done

	createCost_common="${schema_costs[0]:--1}"
	createCost_aligned="${schema_costs[1]:--1}"
	createCost_template="${schema_costs[2]:--1}"
	createCost_tempaligned="${schema_costs[3]:--1}"

	run_iotdb_cli -e "flush" >/dev/null 2>&1 || true
	countCost_all="$(run_count_cost "all" "count timeseries root.**")"
	countCost_common="$(run_count_cost "common" "count timeseries root.test.common_0.**")"
	countCost_aligned="$(run_count_cost "aligned" "count timeseries root.test.aligned_0.**")"
	countCost_template="$(run_count_cost "template" "count timeseries root.test.temp_0.**")"
	countCost_tempaligned="$(run_count_cost "tempaligned" "count timeseries root.test.tempaligned_0.**")"

	showCost_all="$(run_show_cost "all" "show timeseries root.**")"
	showCost_common="$(run_show_cost "common" "show timeseries root.test.common_0.**")"
	showCost_aligned="$(run_show_cost "aligned" "show timeseries root.test.aligned_0.**")"
	showCost_template="$(run_show_cost "template" "show timeseries root.test.temp_0.**")"
	showCost_tempaligned="$(run_show_cost "tempaligned" "show timeseries root.test.tempaligned_0.**")"

	stop_iotdb
	sleep "${STOP_WAIT_SECONDS}"
	cleanup_processes
	collect_monitor_data
	end_time="$(current_datetime)"
	cost_time=$(( $(datetime_to_epoch "${end_time}") - $(datetime_to_epoch "${start_time}") ))
	insert_database "${protocol_code}"
	append_show_results
	backup_test_data "${protocol_code}"

	return "${monitor_failed}"
}

# 功能：校验运行环境并编排当前脚本的完整测试流程
main() {
	local protocol=""
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
		if ! test_operation "${protocol}"; then
			task_failed=1
		fi
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
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/protocol_common.sh"

main "$@"
