#!/usr/bin/env bash

# 查询类测试公共库。
# 公共适用脚本：se_query.sh、unse_query.sh、se_query_test.sh。
# 约定：
# - 本文件中的“公共函数”由所有查询类脚本复用，入口脚本在 source 前设置 TEST_IP、TEST_TYPE、QUERY_DATA_TYPE。
# - 本文件中的“预留配置/预留函数”主要面向 se_query_test.sh，用于缩小测试矩阵并创建 QA 查询用户。

if [ -z "${BASH_VERSION:-}" ]; then
    echo "query_common.sh requires bash" >&2
    return 1 2>/dev/null || exit 1
fi
if shopt -oq posix; then
    echo "query_common.sh requires non-posix bash" >&2
    return 1 2>/dev/null || exit 1
fi

: "${TEST_IP:?TEST_IP must be set before sourcing query_common.sh}"
: "${TEST_TYPE:?TEST_TYPE must be set before sourcing query_common.sh}"
# 公共必填配置：se_query.sh/se_query_test.sh 设置为 sequence，unse_query.sh 设置为 unsequence。
: "${QUERY_DATA_TYPE:?QUERY_DATA_TYPE must be set before sourcing query_common.sh}"

readonly IOTDB_PW="${IOTDB_PW:-TimechoDB@2021}"

readonly INIT_PATH="${INIT_PATH:-/data/atmos/zk_test}"
readonly ATMOS_PATH="${ATMOS_PATH:-${INIT_PATH}/atmos-ex}"
readonly BM_PATH="${BM_PATH:-${INIT_PATH}/iot-benchmark}"
readonly DATA_PATH="${DATA_PATH:-/data/atmos/DataSet}"
readonly BACKUP_PATH="${BACKUP_PATH:-/nasdata/repository/${TEST_TYPE}}"
readonly REPOS_PATH="${REPOS_PATH:-/nasdata/repository/master}"
readonly BM_REPOS_PATH="${BM_REPOS_PATH:-/nasdata/repository/iot-benchmark}"

readonly TEST_INIT_PATH="${TEST_INIT_PATH:-/data/atmos}"
readonly TEST_IOTDB_PATH="${TEST_IOTDB_PATH:-${TEST_INIT_PATH}/apache-iotdb}"

readonly -a PROTOCOL_CLASS=(
    ""
    "org.apache.iotdb.consensus.simple.SimpleConsensus"
    "org.apache.iotdb.consensus.ratis.RatisConsensus"
    "org.apache.iotdb.consensus.iot.IoTConsensus"
    "org.apache.iotdb.consensus.iot.IoTConsensusV2"
)
# 公共可覆盖配置：入口脚本可在 source 本文件前预定义 PROTOCOL_LIST，限制需要测试的共识协议组合。
if ! declare -p PROTOCOL_LIST >/dev/null 2>&1; then
    readonly -a PROTOCOL_LIST=(211)
fi
# 公共可覆盖配置：入口脚本可在 source 本文件前预定义 QUERY_TS_LIST，限制需要测试的序列类型/表模型类型。
# se_query_test.sh 使用该配置只跑 tablemode 和 tempaligned。
if ! declare -p QUERY_TS_LIST >/dev/null 2>&1; then
    readonly -a QUERY_TS_LIST=(tablemode common aligned tempaligned)
fi
# 特定脚本预留配置：se_query_test.sh 设置为 1 时，prepare_query_users 会创建 QA 查询用户。
if ! declare -p QUERY_CREATE_QA_USER >/dev/null 2>&1; then
    readonly QUERY_CREATE_QA_USER=0
else
    readonly QUERY_CREATE_QA_USER
fi
# 公共可覆盖配置：默认查询用例列表；未来新增专项查询脚本可在 source 前重定义。
if ! declare -p QUERY_LIST >/dev/null 2>&1; then
    readonly -a QUERY_LIST=(
        Q1
        Q2-1
        Q2-2
        Q2-3
        Q3-1
        Q3-2
        Q3-3
        Q4a-1
        Q4a-2
        Q4a-3
        Q4b-1
        Q4b-2
        Q4b-3
        Q5
        Q6-1
        Q6-2
        Q6-3
        Q7-1
        Q7-2
        Q7-3
        Q8
        Q9-1
        Q9-2
        Q9-3
        Q10
    )
fi
# 公共可覆盖配置：QUERY_RESULT_LABELS 与 QUERY_LIST 一一对应，用于解析 benchmark CSV 中的结果行。
if ! declare -p QUERY_RESULT_LABELS >/dev/null 2>&1; then
    readonly -a QUERY_RESULT_LABELS=(
        PRECISE_POINT
        TIME_RANGE
        TIME_RANGE
        TIME_RANGE
        VALUE_RANGE
        VALUE_RANGE
        VALUE_RANGE
        AGG_RANGE
        AGG_RANGE
        AGG_RANGE
        AGG_RANGE
        AGG_RANGE
        AGG_RANGE
        AGG_VALUE
        AGG_RANGE_VALUE
        AGG_RANGE_VALUE
        AGG_RANGE_VALUE
        GROUP_BY
        GROUP_BY
        GROUP_BY
        LATEST_POINT
        RANGE_QUERY_DESC
        RANGE_QUERY_DESC
        RANGE_QUERY_DESC
        VALUE_RANGE_QUERY_DESC
    )
fi

readonly MYSQLHOSTNAME="${MYSQLHOSTNAME:-111.200.37.158}"
readonly PORT="${PORT:-13306}"
readonly USERNAME="${USERNAME:-iotdbatm}"
readonly PASSWORD="${PASSWORD:-${ATMOS_DB_PASSWORD:-}}"
readonly DBNAME="${DBNAME:-QA_ATM}"
readonly TABLENAME="${TABLENAME:-ex_${TEST_TYPE}}"
readonly TABLENAME_T="${TABLENAME_T:-ex_${TEST_TYPE}_T}"
readonly TASK_TABLENAME="${TASK_TABLENAME:-ex_commit_history}"

readonly METRIC_SERVER="${METRIC_SERVER:-111.200.37.158:19090}"
readonly MONITOR_TIMEOUT_SECONDS="${MONITOR_TIMEOUT_SECONDS:-7200}"
readonly MONITOR_POLL_INTERVAL_SECONDS="${MONITOR_POLL_INTERVAL_SECONDS:-10}"
readonly IOTDB_READY_RETRIES="${IOTDB_READY_RETRIES:-10}"
readonly IOTDB_READY_INTERVAL_SECONDS="${IOTDB_READY_INTERVAL_SECONDS:-5}"
readonly IOTDB_READY_USER="${IOTDB_READY_USER:-root}"
readonly IOTDB_READY_PASSWORD="${IOTDB_READY_PASSWORD:-root}"
readonly STARTUP_GRACE_SECONDS="${STARTUP_GRACE_SECONDS:-10}"
readonly BENCHMARK_RESULT_WAIT_SECONDS="${BENCHMARK_RESULT_WAIT_SECONDS:-2}"
readonly BENCHMARK_STOP_WAIT_SECONDS="${BENCHMARK_STOP_WAIT_SECONDS:-30}"

result_table="${TABLENAME}"
commit_id=""
author=""
commit_date_time=""
test_date_time=""

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
start_time=""
end_time=""
cost_time=0
numOfUnse0Level=0
dataFileSize=0
maxNumofOpenFiles=0
maxNumofThread=0
errorLogSize=0
walFileSize=0
m_start_time=0
m_end_time=0

# -------------------- 公共基础工具函数 --------------------
# 这些函数不依赖具体查询类型，供所有查询类入口脚本和本文件内部流程复用。
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

datetime_to_epoch() {
    date -d "$1" +%s
}

normalize_datetime() {
    printf '%s' "$1" | tr -cd '0-9'
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

ensure_runtime_dependencies() {
    local cmd=""

    for cmd in awk cat cp curl date du grep jq jps kill mkdir mv mysql rm sed sudo tr; do
        require_command "${cmd}"
    done
}

check_password() {
    [ -n "${PASSWORD}" ] || die "ATMOS_DB_PASSWORD is not set, cannot connect to MySQL."
}

# -------------------- 公共安全路径和文件操作函数 --------------------
# 所有删除/移动前先通过 path_is_safe 做路径白名单校验，避免变量为空或拼接异常时误删宿主机目录。
path_is_safe() {
    local path="$1"
    [ -n "${path}" ] || return 1

    case "${path}" in
        "/"|"/data"|"/nasdata"|".")
            return 1
            ;;
        "${INIT_PATH}"/*|"${TEST_INIT_PATH}"/*|"${BACKUP_PATH}"/*)
            return 0
            ;;
        *"/data/csvOutput/"*.csv)
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

# -------------------- 公共 MySQL 和任务队列函数 --------------------
# 负责访问 QA_ATM、读取待测 commit、更新任务状态和安全拼接 SQL 字符串。
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
    [ -n "${commit_id}" ] || return 1
    [ -n "${commit_date_time}" ] || die "failed to parse commit_date_time."
}

# -------------------- 公共 Benchmark 版本同步函数 --------------------
# git_commit_abbrev/check_benchmark_version 负责保持查询测试使用的 iot-benchmark 为最新版本。
git_commit_abbrev() {
    awk -F= '/git.commit.id.abbrev/ {print $2; exit}' "$1" 2>/dev/null
}

check_benchmark_version() {
    local source_version=""
    local target_version=""

    [ -f "${BM_REPOS_PATH}/git.properties" ] || die "missing benchmark git.properties: ${BM_REPOS_PATH}/git.properties"
    source_version="$(git_commit_abbrev "${BM_REPOS_PATH}/git.properties")"
    [ -n "${source_version}" ] || die "failed to read benchmark version."

    if [ -f "${BM_PATH}/git.properties" ]; then
        target_version="$(git_commit_abbrev "${BM_PATH}/git.properties")"
    fi

    if [ ! -d "${BM_PATH}" ] || [ "${target_version}" != "${source_version}" ]; then
        log "sync benchmark to ${BM_PATH}"
        safe_rm "${BM_PATH}"
        cp -rf -- "${BM_REPOS_PATH}" "${BM_PATH}"
    fi
}

# -------------------- 公共测试指标初始化函数 --------------------
# 每个协议或查询 case 开始前重置全局指标，避免上一次结果污染本次入库数据。
init_items() {
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
    start_time=""
    end_time=""
    cost_time=0
    numOfUnse0Level=0
    dataFileSize=0
    maxNumofOpenFiles=0
    maxNumofThread=0
    errorLogSize=0
    walFileSize=0
    m_start_time=0
    m_end_time=0
}

reset_benchmark_metrics() {
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
}

set_negative_benchmark_metrics() {
    local value="$1"
    okPoint="${value}"
    okOperation="${value}"
    failPoint="${value}"
    failOperation="${value}"
    throughput="${value}"
    Latency="${value}"
    MIN="${value}"
    P10="${value}"
    P25="${value}"
    MEDIAN="${value}"
    P75="${value}"
    P90="${value}"
    P95="${value}"
    P99="${value}"
    P999="${value}"
    MAX="${value}"
}

# -------------------- 公共进程清理函数 --------------------
# 统一清理 Benchmark 和 IoTDB 相关 Java 进程，供正常流程和异常流程复用。
check_pid_and_kill() {
    local pname="$1"
    local desc="$2"
    local pids=""
    local pid=""

    pids="$(jps | awk -v pname="${pname}" '$2 == pname {print $1}')"
    if [ -z "${pids}" ]; then
        log "no ${desc} process detected."
        return 0
    fi

    while IFS= read -r pid; do
        [ -n "${pid}" ] || continue
        kill -9 "${pid}"
    done <<< "${pids}"
    log "${desc} process stopped."
}

cleanup_processes() {
    check_pid_and_kill "App" "Benchmark"
    check_pid_and_kill "DataNode" "DataNode"
    check_pid_and_kill "ConfigNode" "ConfigNode"
    check_pid_and_kill "IoTDB" "IoTDB"
}

# -------------------- 公共 IoTDB / Benchmark 生命周期函数 --------------------
# 负责准备待测版本、修改基础配置、设置共识协议、启动/停止服务和等待可用。
set_env() {
    local source_path="${REPOS_PATH}/${commit_id}/apache-iotdb"

    [ -d "${source_path}" ] || die "missing tested IoTDB path: ${source_path}"
    safe_rm "${TEST_IOTDB_PATH}"
    mkdir -p "${TEST_IOTDB_PATH}/activation"
    cp -rf -- "${source_path}/." "${TEST_IOTDB_PATH}/"
    copy_if_exists "${ATMOS_PATH}/conf/${TEST_TYPE}/license" "${TEST_IOTDB_PATH}/activation/" "license"
    copy_if_exists "${ATMOS_PATH}/conf/${TEST_TYPE}/env" "${TEST_IOTDB_PATH}/.env" "env"
}

modify_iotdb_config() {
    local datanode_env="${TEST_IOTDB_PATH}/conf/datanode-env.sh"
    local properties_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"

    [ -f "${datanode_env}" ] || die "missing config file: ${datanode_env}"
    [ -f "${properties_file}" ] || die "missing config file: ${properties_file}"
    sed -i 's/^#\?ON_HEAP_MEMORY=.*$/ON_HEAP_MEMORY="20G"/' "${datanode_env}"

    cat >> "${properties_file}" <<EOF
series_slot_num=10000
enable_seq_space_compaction=false
enable_unseq_space_compaction=false
enable_cross_space_compaction=false
cluster_name=${TEST_TYPE}
cn_enable_metric=true
cn_enable_performance_stat=true
cn_metric_reporter_list=PROMETHEUS
cn_metric_level=ALL
cn_metric_prometheus_reporter_port=9081
dn_enable_metric=true
dn_enable_performance_stat=true
dn_metric_reporter_list=PROMETHEUS
dn_metric_level=ALL
dn_metric_prometheus_reporter_port=9091
EOF
}

set_protocol_class() {
    local protocol_code="$1"
    local config_node="${protocol_code:0:1}"
    local schema_region="${protocol_code:1:1}"
    local data_region="${protocol_code:2:1}"
    local properties_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"

    [ "${#protocol_code}" -eq 3 ] || return 1
    [ -n "${PROTOCOL_CLASS[${config_node}]:-}" ] || return 1
    [ -n "${PROTOCOL_CLASS[${schema_region}]:-}" ] || return 1
    [ -n "${PROTOCOL_CLASS[${data_region}]:-}" ] || return 1

    cat >> "${properties_file}" <<EOF
config_node_consensus_protocol_class=${PROTOCOL_CLASS[${config_node}]}
schema_region_consensus_protocol_class=${PROTOCOL_CLASS[${schema_region}]}
data_region_consensus_protocol_class=${PROTOCOL_CLASS[${data_region}]}
EOF
}

drop_system_caches() {
    if [ -w /proc/sys/vm/drop_caches ]; then
        echo 3 > /proc/sys/vm/drop_caches || true
    fi
}

start_iotdb() {
    drop_system_caches
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
    local attempt=0
    local dn_pid=""
    local cn_pid=""

    if [ ! -d "${TEST_IOTDB_PATH}" ]; then
        return 0
    fi

    for ((attempt = 0; attempt <= IOTDB_READY_RETRIES; attempt++)); do
        (
            cd "${TEST_IOTDB_PATH}" || exit 1
            ./sbin/stop-datanode.sh >/dev/null 2>&1 &
        )
        sleep 3
        (
            cd "${TEST_IOTDB_PATH}" || exit 1
            ./sbin/stop-confignode.sh >/dev/null 2>&1 &
        )
        sleep 5

        dn_pid="$(jps | awk '$2 == "DataNode" {print $1; exit}')"
        cn_pid="$(jps | awk '$2 == "ConfigNode" {print $1; exit}')"
        if [ -z "${dn_pid}" ] && [ -z "${cn_pid}" ]; then
            return 0
        fi
    done

    return 1
}

wait_for_iotdb_ready() {
    local attempt=0
    local iotdb_state=""
    local -a cli_args=()

    if [ -n "${IOTDB_READY_USER}" ]; then
        cli_args+=(-u "${IOTDB_READY_USER}")
    fi
    if [ -n "${IOTDB_READY_PASSWORD}" ]; then
        cli_args+=(-pw "${IOTDB_READY_PASSWORD}")
    fi

    for ((attempt = 1; attempt <= IOTDB_READY_RETRIES; attempt++)); do
        if [ "${#cli_args[@]}" -gt 0 ]; then
            iotdb_state="$("${TEST_IOTDB_PATH}/sbin/start-cli.sh" "${cli_args[@]}" -e "show cluster" 2>/dev/null | grep -F 'Total line number = 2' || true)"
        else
            iotdb_state="$("${TEST_IOTDB_PATH}/sbin/start-cli.sh" -e "show cluster" 2>/dev/null | grep -F 'Total line number = 2' || true)"
        fi
        if [ "${iotdb_state}" = "Total line number = 2" ]; then
            return 0
        fi
        sleep "${IOTDB_READY_INTERVAL_SECONDS}"
    done

    return 1
}

# -------------------- 特定脚本预留函数：se_query_test QA 用户准备 --------------------
# 只有 se_query_test.sh 将 QUERY_CREATE_QA_USER 设为 1 时才会实际创建 qa_user。
prepare_query_users() {
    if [ "${QUERY_CREATE_QA_USER}" != "1" ]; then
        return 0
    fi

    "${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw root -e "CREATE USER qa_user 'test123456789'" >/dev/null 2>&1 || true
    "${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw root -e "GRANT ALL ON root.** TO USER qa_user WITH GRANT OPTION" >/dev/null 2>&1 || true
    "${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw root -sql_dialect table -e "GRANT ALL TO USER qa_user" >/dev/null 2>&1 || true
}

# -------------------- 公共 Benchmark 结果定位和状态监控函数 --------------------
# 启动查询 Benchmark，并通过输出 CSV 判断查询是否完成；超时时生成兜底结果。
start_benchmark() {
    safe_rm "${BM_PATH}/logs"
    safe_rm "${BM_PATH}/data"
    (
        cd "${BM_PATH}" || exit 1
        ./benchmark.sh >/dev/null 2>&1 &
    )
}

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

create_stuck_result_csv() {
    local csv_file="$1"
    local result_label="$2"

    mkdir -p "${csv_file%/*}"
    : > "${csv_file}"
    echo "${result_label} ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1" >> "${csv_file}"
    echo "${result_label} ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1" >> "${csv_file}"
}

monitor_test_status() {
    local query_name="$1"
    local result_label="$2"
    local csv_file=""
    local now_epoch=0
    local elapsed=0

    while true; do
        csv_file="$(find_result_csv || true)"
        if [ -n "${csv_file}" ]; then
            end_time="$(current_datetime)"
            log "${query_name} query finished."
            return 0
        fi

        now_epoch="$(date +%s)"
        elapsed=$((now_epoch - m_start_time))
        if [ "${elapsed}" -ge "${MONITOR_TIMEOUT_SECONDS}" ]; then
            end_time="$(current_datetime)"
            log "${query_name} query timed out, writing stuck result."
            create_stuck_result_csv "${BM_PATH}/data/csvOutput/Stuck_result.csv" "${result_label}"
            return 1
        fi

        sleep "${MONITOR_POLL_INTERVAL_SECONDS}"
    done
}

# -------------------- 公共 Prometheus 指标采集函数 --------------------
# 采集文件数、线程数、WAL、日志大小等通用性能指标，供结果入库使用。
get_single_index() {
    local query="$1"
    local end="$2"
    local index_value=""

    index_value="$(
        curl -G -s "http://${METRIC_SERVER}/api/v1/query" \
            --data-urlencode "query=${query}" \
            --data-urlencode "time=${end}" \
            | jq -r '.data.result[0].value[1] // 0'
    )"

    if [ "${index_value}" = "null" ] || [ -z "${index_value}" ]; then
        index_value=0
    fi

    printf '%s\n' "${index_value}"
}

bytes_to_gib() {
    awk -v value="${1:-0}" 'BEGIN { printf "%.2f\n", value / 1073741824 }'
}

to_int() {
    awk -v value="${1:-0}" 'BEGIN { printf "%d\n", value }'
}

file_size_bytes() {
    local file="$1"
    if [ -f "${file}" ]; then
        du -sb "${file}" 2>/dev/null | awk '{print $1}'
    else
        printf '0\n'
    fi
}

collect_monitor_data() {
    local metric_window=$((m_end_time - m_start_time))
    local maxNumofThread_C=0
    local maxNumofThread_D=0
    local datanode_error_log_size=0
    local confignode_error_log_size=0

    [ "${metric_window}" -gt 0 ] || metric_window=1

    dataFileSize="$(get_single_index "sum(file_global_size{instance=~\"${TEST_IP}:9091\"})" "${m_end_time}")"
    dataFileSize="$(bytes_to_gib "${dataFileSize}")"
    numOfSe0Level="$(get_single_index "sum(file_global_count{instance=~\"${TEST_IP}:9091\",name=\"seq\"})" "${m_end_time}")"
    numOfUnse0Level="$(get_single_index "sum(file_global_count{instance=~\"${TEST_IP}:9091\",name=\"unseq\"})" "${m_end_time}")"
    maxNumofThread_C="$(get_single_index "max_over_time(process_threads_count{instance=~\"${TEST_IP}:9081\"}[${metric_window}s])" "${m_end_time}")"
    maxNumofThread_D="$(get_single_index "max_over_time(process_threads_count{instance=~\"${TEST_IP}:9091\"}[${metric_window}s])" "${m_end_time}")"
    maxNumofThread=$(( $(to_int "${maxNumofThread_C}") + $(to_int "${maxNumofThread_D}") ))
    maxNumofOpenFiles="$(get_single_index "max_over_time(file_count{instance=~\"${TEST_IP}:9091\",name=\"open_file_handlers\"}[${metric_window}s])" "${m_end_time}")"
    walFileSize="$(get_single_index "max_over_time(file_size{instance=~\"${TEST_IP}:9091\",name=~\"wal\"}[${metric_window}s])" "${m_end_time}")"
    walFileSize="$(bytes_to_gib "${walFileSize}")"
    datanode_error_log_size="$(file_size_bytes "${TEST_IOTDB_PATH}/logs/log_datanode_error.log")"
    confignode_error_log_size="$(file_size_bytes "${TEST_IOTDB_PATH}/logs/log_confignode_error.log")"
    errorLogSize=$((datanode_error_log_size + confignode_error_log_size))
}

# -------------------- 公共查询配置、结果解析和入库函数 --------------------
# configure_benchmark 按 ts_type/query_name 切换 Benchmark 配置；parse_benchmark_result 按 label 解析查询结果。
configure_benchmark() {
    local current_ts_type="$1"
    local current_query_name="$2"
    local source_config="${ATMOS_PATH}/conf/${TEST_TYPE}/${current_ts_type}/${current_query_name}"
    local target_config="${BM_PATH}/conf/config.properties"

    [ -f "${source_config}" ] || die "missing benchmark config file: ${source_config}"
    safe_rm "${target_config}"
    cp -rf -- "${source_config}" "${target_config}"

    if [ "${current_ts_type}" = "tablemode" ]; then
        if grep -q '^IoTDB_DIALECT_MODE=' "${target_config}"; then
            sed -i 's/^IoTDB_DIALECT_MODE=.*$/IoTDB_DIALECT_MODE=table/' "${target_config}"
        else
            printf 'IoTDB_DIALECT_MODE=table\n' >> "${target_config}"
        fi
    fi
}

parse_benchmark_result() {
    local csv_file="$1"
    local result_label="$2"
    local throughput_line=""
    local latency_line=""

    [ -f "${csv_file}" ] || return 1

    throughput_line="$(
        awk -F, -v label="${result_label}" '
            {
                name = $1
                gsub(/^[ \t]+|[ \t]+$/, "", name)
            }
            name == label {
                for (i = 2; i <= 6; i++) {
                    gsub(/^[ \t]+|[ \t]+$/, "", $i)
                    printf "%s%s", $i, (i == 6 ? ORS : OFS)
                }
                exit
            }
        ' OFS=$'\t' "${csv_file}"
    )"

    latency_line="$(
        awk -F, -v label="${result_label}" '
            {
                name = $1
                gsub(/^[ \t]+|[ \t]+$/, "", name)
            }
            name == label {
                count++
                if (count == 2) {
                    for (i = 2; i <= 12; i++) {
                        gsub(/^[ \t]+|[ \t]+$/, "", $i)
                        printf "%s%s", $i, (i == 12 ? ORS : OFS)
                    }
                    exit
                }
            }
        ' OFS=$'\t' "${csv_file}"
    )"

    [ -n "${throughput_line}" ] || return 1
    [ -n "${latency_line}" ] || return 1

    IFS=$'\t' read -r okOperation okPoint failOperation failPoint throughput <<< "${throughput_line}"
    IFS=$'\t' read -r Latency MIN P10 P25 MEDIAN P75 P90 P95 P99 P999 MAX <<< "${latency_line}"
}

insert_result_row() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local current_query_type="$3"
    local insert_sql=""

    insert_sql=$(cat <<EOF
insert into ${result_table} (
    commit_date_time,test_date_time,commit_id,author,ts_type,data_type,query_type,okPoint,okOperation,failPoint,failOperation,
    throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,
    numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,remark
) values (
    ${commit_date_time},
    ${test_date_time},
    $(sql_quote "${commit_id}"),
    $(sql_quote "${author}"),
    $(sql_quote "${current_ts_type}"),
    $(sql_quote "${QUERY_DATA_TYPE}"),
    $(sql_quote "${current_query_type}"),
    ${okPoint},
    ${okOperation},
    ${failPoint},
    ${failOperation},
    ${throughput},
    ${Latency},
    ${MIN},
    ${P10},
    ${P25},
    ${MEDIAN},
    ${P75},
    ${P90},
    ${P95},
    ${P99},
    ${P999},
    ${MAX},
    ${numOfSe0Level},
    $(sql_quote "${start_time}"),
    $(sql_quote "${end_time}"),
    ${cost_time},
    ${numOfUnse0Level},
    ${dataFileSize},
    ${maxNumofOpenFiles},
    ${maxNumofThread},
    ${errorLogSize},
    $(sql_quote "${protocol_code}")
)
EOF
)

    mysql_exec "${insert_sql}"
}

# -------------------- 公共数据集搬运和日志备份函数 --------------------
# 查询类脚本复用预生成数据集，单个 ts_type 测完后再把 data 目录还原到数据集仓库。
move_dataset_to_iotdb() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local source_data="${DATA_PATH}/${protocol_code}/${current_ts_type}/data"

    [ -d "${source_data}" ] || die "missing query dataset: ${source_data}"
    mv -- "${source_data}" "${TEST_IOTDB_PATH}/"
}

restore_dataset_from_iotdb() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local target_parent="${DATA_PATH}/${protocol_code}/${current_ts_type}"

    if [ -d "${TEST_IOTDB_PATH}/data" ]; then
        mkdir -p "${target_parent}"
        mv -- "${TEST_IOTDB_PATH}/data" "${target_parent}/"
    fi
}

save_query_logs() {
    local query_name="$1"
    local logs_target="${TEST_IOTDB_PATH}/logs_${query_name}"
    local csv_dir="${BM_PATH}/data/csvOutput"
    local had_nullglob=0
    local csv_files=()
    local csv_file=""

    mkdir -p "${TEST_IOTDB_PATH}/logs"
    if [ -d "${csv_dir}" ]; then
        cp -rf -- "${csv_dir}" "${TEST_IOTDB_PATH}/logs/"
    fi

    safe_rm "${logs_target}"
    if [ -d "${TEST_IOTDB_PATH}/logs" ]; then
        mv -- "${TEST_IOTDB_PATH}/logs" "${logs_target}"
    fi

    if shopt -q nullglob; then
        had_nullglob=1
    else
        shopt -s nullglob
    fi

    csv_files=("${csv_dir}/"*.csv)

    if [ "${had_nullglob}" -eq 0 ]; then
        shopt -u nullglob
    fi

    for csv_file in "${csv_files[@]}"; do
        safe_rm "${csv_file}"
    done
}

backup_test_data() {
    local current_ts_type="$1"
    local backup_parent="${BACKUP_PATH}/${current_ts_type}"
    local backup_dir="${backup_parent}/${commit_date_time}_${commit_id}"

    sudo_safe_rm "${backup_dir}"
    path_is_safe "${backup_parent}" || die "refuse unexpected backup path: ${backup_parent}"
    sudo mkdir -p -- "${backup_parent}"
    path_is_safe "${backup_dir}" || die "refuse unexpected backup path: ${backup_dir}"
    sudo mkdir -p -- "${backup_dir}"

    sudo_safe_rm "${TEST_IOTDB_PATH}/data"
    path_is_safe "${TEST_IOTDB_PATH}" || die "refuse unexpected IoTDB path: ${TEST_IOTDB_PATH}"
    sudo mv "${TEST_IOTDB_PATH}" "${backup_dir}"
    if [ -d "${BM_PATH}/data/csvOutput" ]; then
        sudo cp -rf -- "${BM_PATH}/data/csvOutput" "${backup_dir}"
    fi
}

# -------------------- 公共查询 case 执行流程 --------------------
# 单个 query case 流程：启动 IoTDB -> 准备用户 -> 运行 Benchmark -> 解析结果 -> 入库 -> 保存日志。
run_query_case() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local query_index="$3"
    local query_name="${QUERY_LIST[${query_index}]}"
    local result_label="${QUERY_RESULT_LABELS[${query_index}]}"
    local csv_file=""
    local case_failed=0

    reset_benchmark_metrics
    log "start query: protocol=${protocol_code}, ts_type=${current_ts_type}, query=${query_name}"
    cleanup_processes
    sleep 1
    start_iotdb
    sleep "${STARTUP_GRACE_SECONDS}"

    if ! wait_for_iotdb_ready; then
        log "IoTDB failed to start, writing negative result."
        start_time="0"
        end_time="0"
        cost_time=-3
        set_negative_benchmark_metrics -3
        insert_result_row "${protocol_code}" "${current_ts_type}" "${query_name}"
        update_task_status "RError"
        cleanup_processes
        return 1
    fi

    prepare_query_users
    configure_benchmark "${current_ts_type}" "${query_name}"
    sleep 3
    start_benchmark
    start_time="$(current_datetime)"
    m_start_time="$(date +%s)"
    sleep "${BENCHMARK_RESULT_WAIT_SECONDS}"

    if ! monitor_test_status "${query_name}" "${result_label}"; then
        case_failed=1
    fi

    m_end_time="$(date +%s)"
    collect_monitor_data
    csv_file="$(find_result_csv || true)"
    if [ -z "${csv_file}" ] || ! parse_benchmark_result "${csv_file}" "${result_label}"; then
        log "failed to parse ${result_label} from benchmark result, writing negative result."
        set_negative_benchmark_metrics -2
        case_failed=1
    fi

    [ -n "${end_time}" ] || end_time="$(current_datetime)"
    cost_time=$(( $(datetime_to_epoch "${end_time}") - $(datetime_to_epoch "${start_time}") ))
    insert_result_row "${protocol_code}" "${current_ts_type}" "${query_name}"
    log "${commit_id} ${current_ts_type} ${QUERY_DATA_TYPE} ${query_name}: okPoint=${okPoint}, latency=${Latency}ms"

    save_query_logs "${query_name}"
    stop_iotdb || true
    sleep "${BENCHMARK_STOP_WAIT_SECONDS}"
    cleanup_processes
    sleep 5

    return "${case_failed}"
}

# -------------------- 公共序列类型执行流程 --------------------
# 单个 ts_type 流程：准备 IoTDB 目录和数据集，然后遍历 QUERY_LIST 中的所有查询用例。
run_ts_type() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local query_index=0
    local ts_failed=0

    log "start ts_type: protocol=${protocol_code}, ts_type=${current_ts_type}"
    cleanup_processes
    set_env
    modify_iotdb_config

    if ! set_protocol_class "${protocol_code}"; then
        log "invalid protocol code: ${protocol_code}"
        return 1
    fi

    move_dataset_to_iotdb "${protocol_code}" "${current_ts_type}"
    sleep 10

    for ((query_index = 0; query_index < ${#QUERY_LIST[@]}; query_index++)); do
        if ! run_query_case "${protocol_code}" "${current_ts_type}" "${query_index}"; then
            ts_failed=1
        fi
    done

    restore_dataset_from_iotdb "${protocol_code}" "${current_ts_type}"
    backup_test_data "${current_ts_type}"
    return "${ts_failed}"
}

# -------------------- 公共协议执行流程 --------------------
# 单个协议下遍历 QUERY_TS_LIST；se_query_test.sh 通过覆盖 QUERY_TS_LIST 缩小测试范围。
test_operation() {
    local protocol_code="$1"
    local current_ts_type=""
    local task_failed=0

    for current_ts_type in "${QUERY_TS_LIST[@]}"; do
        if ! run_ts_type "${protocol_code}" "${current_ts_type}"; then
            task_failed=1
        fi
    done

    return "${task_failed}"
}

# -------------------- 公共调度状态函数 --------------------
# 与外层调度器通过 test_type_file 协同当前测试状态。
mark_test_in_progress() {
    mkdir -p "${INIT_PATH}"
    printf 'ontesting\n' > "${INIT_PATH}/test_type_file"
}

restore_test_type_file() {
    mkdir -p "${INIT_PATH}"
    printf '%s\n' "${TEST_TYPE}" > "${INIT_PATH}/test_type_file"
}

# -------------------- 公共主流程入口 --------------------
# 由各入口脚本在 source 后调用 main "$@"，统一完成依赖检查、取 commit、遍历协议并更新任务状态。
main() {
    local protocol=""
    local task_failed=0

    trap restore_test_type_file EXIT

    [ "${#QUERY_LIST[@]}" -eq "${#QUERY_RESULT_LABELS[@]}" ] || die "QUERY_LIST and QUERY_RESULT_LABELS length mismatch."
    ensure_runtime_dependencies
    check_password
    check_benchmark_version

    mark_test_in_progress
    if ! fetch_next_commit; then
        sleep 60
        return 0
    fi

    update_task_status "ontesting"
    log "current commit ${commit_id} is pending, start query test."

    if [ "${author}" = "Timecho" ]; then
        result_table="${TABLENAME_T}"
    else
        result_table="${TABLENAME}"
    fi

    test_date_time="$(date +%Y%m%d%H%M%S)"
    for protocol in "${PROTOCOL_LIST[@]}"; do
        init_items
        if ! test_operation "${protocol}"; then
            task_failed=1
        fi
    done

    log "test round ${test_date_time} finished."
    if [ "${task_failed}" -eq 0 ]; then
        update_task_status "done"
        if [ "${author}" != "Timecho" ]; then
            mark_older_commits_skip
        fi
    else
        update_task_status "RError"
    fi
}
