#!/usr/bin/env bash

# 写入类测试公共库。
# 公共适用脚本：se_insert.sh、unse_insert.sh、api_insert.sh、api_insert_cts.sh、config_insert.sh、insert_records.sh 等。
# 约定：
# - 本文件中的“公共函数”由所有写入类脚本复用，入口脚本只需要在 source 前设置 TEST_IP、TEST_TYPE 等变量。
# - 本文件中的“预留扩展点”面向特定脚本，入口脚本可通过定义 hook 函数或在 source 后覆盖同名函数来定制行为。

if [ -z "${BASH_VERSION:-}" ]; then
    echo "insert_common.sh requires bash" >&2
    return 1 2>/dev/null || exit 1
fi
if shopt -oq posix; then
    echo "insert_common.sh requires non-posix bash" >&2
    return 1 2>/dev/null || exit 1
fi

: "${TEST_IP:?TEST_IP must be set before sourcing insert_common.sh}"
: "${TEST_TYPE:?TEST_TYPE must be set before sourcing insert_common.sh}"

readonly BACKUP_PATH="/nasdata/repository/${TEST_TYPE}"
readonly TABLENAME="ex_${TEST_TYPE}"
readonly TABLENAME_T="ex_${TEST_TYPE}_T"

readonly IOTDB_PW="TimechoDB@2021"

readonly INIT_PATH="/data/atmos/zk_test"
readonly ATMOS_PATH="${INIT_PATH}/atmos-ex"
readonly BM_PATH="${INIT_PATH}/iot-benchmark"
readonly REPOS_PATH="/nasdata/repository/master"
readonly BM_REPOS_PATH="/nasdata/repository/iot-benchmark"

readonly TEST_INIT_PATH="/data/atmos"
readonly TEST_IOTDB_PATH="${TEST_INIT_PATH}/apache-iotdb"

readonly -a PROTOCOL_CLASS=(
    ""
    "org.apache.iotdb.consensus.simple.SimpleConsensus"
    "org.apache.iotdb.consensus.ratis.RatisConsensus"
    "org.apache.iotdb.consensus.iot.IoTConsensus"
    "org.apache.iotdb.consensus.iot.IoTConsensusV2"
)
# 公共可覆盖配置：入口脚本可在 source 本文件前预定义 PROTOCOL_LIST，限制需要测试的共识协议组合。
if ! declare -p PROTOCOL_LIST >/dev/null 2>&1; then
    readonly -a PROTOCOL_LIST=(223)
fi
# 公共可覆盖配置：入口脚本可在 source 本文件前预定义 TS_LIST，限制需要测试的序列类型/表模型类型。
if ! declare -p TS_LIST >/dev/null 2>&1; then
    readonly -a TS_LIST=(common aligned tempaligned tablemode)
fi
# 公共可覆盖配置：入口脚本可在 source 本文件前预定义 API_LIST，限制需要测试的写入接口。
if ! declare -p API_LIST >/dev/null 2>&1; then
    readonly -a API_LIST=(SESSION_BY_TABLET)
fi
# 公共可覆盖配置：last_cache_query 等特殊脚本可在 source 前关闭默认 benchmark 版本检查。
if ! declare -p ENABLE_BENCHMARK_VERSION_CHECK >/dev/null 2>&1; then
    readonly ENABLE_BENCHMARK_VERSION_CHECK=1
else
    readonly ENABLE_BENCHMARK_VERSION_CHECK
fi

readonly MYSQLHOSTNAME="111.200.37.158"
readonly PORT="13306"
readonly USERNAME="iotdbatm"
readonly PASSWORD="${ATMOS_DB_PASSWORD:-}"
readonly DBNAME="QA_ATM"
readonly TASK_TABLENAME="ex_commit_history"

readonly METRIC_SERVER="111.200.37.158:19090"
readonly DEFAULT_DISK_ID="sdb"

readonly MONITOR_TIMEOUT_SECONDS=7200
readonly MONITOR_POLL_INTERVAL_SECONDS=10
readonly IOTDB_READY_RETRIES=10
readonly IOTDB_READY_INTERVAL_SECONDS=5
readonly STARTUP_GRACE_SECONDS=10
readonly BENCHMARK_WARMUP_SECONDS=60
readonly BENCHMARK_STOP_WAIT_SECONDS=30

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
maxCPULoad=0
avgCPULoad=0
maxDiskIOOpsRead=0
maxDiskIOOpsWrite=0
maxDiskIOSizeRead=0
maxDiskIOSizeWrite=0
m_start_time=0
m_end_time=0
disk_id_regex="^${DEFAULT_DISK_ID}$"

# -------------------- 公共基础工具函数 --------------------
# 这些函数不依赖具体测试类型，供所有写入类入口脚本和本文件内部流程复用。
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
    printf '%s' "$value"
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
    command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令: $1"
}

check_password() {
    if [ -z "${PASSWORD}" ]; then
        die "ATMOS_DB_PASSWORD 未设置，无法连接 MySQL。"
    fi
}

ensure_runtime_dependencies() {
    local cmd
    # 在改动运行环境之前先把依赖校验完，避免只在监控或失败分支才会用到的
    # 数学计算、结果解析工具缺失时，脚本运行到中途才报错。
    for cmd in awk bc cat cp curl date grep jq jps kill mkdir mv mysql rm sed sudo tr wc; do
        require_command "$cmd"
    done
}

# 将删除类操作限制在已知工作目录内，避免变量展开异常时误删宿主机上的
# 非预期路径。
# -------------------- 公共安全路径和文件操作函数 --------------------
# 所有删除/移动前先通过 path_is_safe 做路径白名单校验，避免变量为空或拼接异常时误删宿主机目录。
path_is_safe() {
    local path="$1"
    [ -n "$path" ] || return 1

    case "$path" in
        "/"|"/data"|"/nasdata"|".")
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
    [ -e "$path" ] || return 0
    path_is_safe "$path" || die "拒绝删除非预期路径: $path"
    rm -rf -- "$path"
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

# -------------------- 公共监控磁盘识别函数 --------------------
# 根据 IoTDB 配置中的数据目录/WAL 目录解析实际落盘设备，用于 Prometheus 磁盘 IO 指标过滤。
get_monitor_disk_fallback_path() {
    local data_path="${TEST_IOTDB_PATH}/data"

    if [ -d "${data_path}" ]; then
        printf '%s\n' "${data_path}"
        return 0
    fi

    printf '%s\n' "${TEST_IOTDB_PATH}"
}

get_iotdb_property_value() {
    local properties_file="$1"
    local property_key="$2"

    # 与 IoTDB 的配置读取规则保持一致：同一个配置项如果出现多次，
    # 以最后一条生效配置为准。
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
    local normalized_path=""
    local found_configured_path=0
    local -a property_keys=(dn_data_dirs dn_wal_dirs)

    if [ -f "${properties_file}" ]; then
        for property_key in "${property_keys[@]}"; do
            property_value="$(get_iotdb_property_value "${properties_file}" "${property_key}")"
            [ -n "${property_value}" ] || continue

            while IFS= read -r raw_path; do
                [ -n "${raw_path}" ] || continue
                normalized_path="$(normalize_monitor_target_path "${raw_path}")"
                [ -n "${normalized_path}" ] || continue
                printf '%s\n' "${normalized_path}"
                found_configured_path=1
            done < <(split_iotdb_path_list "${property_value}")
        done
    fi

    if [ "${found_configured_path}" -eq 0 ]; then
        get_monitor_disk_fallback_path
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

    source_device="$(findmnt -no SOURCE --target "${existing_path}" 2>/dev/null | awk 'NF { print; exit }')"
    [ -n "${source_device}" ] || return 1

    source_device="${source_device%%[*}"
    if command -v readlink >/dev/null 2>&1; then
        resolved_device="$(readlink -f "${source_device}" 2>/dev/null || printf '%s\n' "${source_device}")"
    else
        resolved_device="${source_device}"
    fi

    [ -b "${resolved_device}" ] || return 1

    while true; do
        parent_device="$(lsblk -ndo PKNAME "${resolved_device}" 2>/dev/null | awk 'NF { print; exit }')"
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

sudo_safe_rm() {
    local path="$1"
    [ -e "$path" ] || return 0
    path_is_safe "$path" || die "拒绝删除非预期路径: $path"
    sudo rm -rf -- "$path"
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
    printf "'%s'" "$value"
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

    # 人工标记为 retest 的任务优先于未测试提交，方便在队列未清空前
    # 直接重跑有问题的版本。
    row="$(query_next_commit "retest")"
    if [ -z "${row}" ]; then
        row="$(query_next_commit "pending")"
    fi
    [ -n "${row}" ] || return 1

    IFS=$'\t' read -r commit_id author raw_commit_date_time <<< "${row}"
    author="$(trim "${author}")"
    commit_date_time="$(normalize_datetime "${raw_commit_date_time}")"
    [ -n "${commit_id}" ] || return 1
    [ -n "${commit_date_time}" ] || die "commit_date_time 解析失败。"
    return 0
}

# -------------------- 公共 Benchmark 版本同步函数 --------------------
# 默认同步 iot-benchmark；last_cache_query 等特殊脚本可在 source 后覆盖同名函数。
check_benchmark_version() {
    local bm_new=""
    local bm_old=""

    [ -f "${BM_REPOS_PATH}/git.properties" ] || die "缺少 benchmark git.properties: ${BM_REPOS_PATH}/git.properties"
    bm_new="$(awk -F= '/git.commit.id.abbrev/ {print $2}' "${BM_REPOS_PATH}/git.properties")"
    [ -n "${bm_new}" ] || die "无法读取 benchmark 版本信息。"

    if [ -f "${BM_PATH}/git.properties" ]; then
        bm_old="$(awk -F= '/git.commit.id.abbrev/ {print $2}' "${BM_PATH}/git.properties")"
    fi

    if [ ! -d "${BM_PATH}" ] || [ "${bm_old}" != "${bm_new}" ]; then
        log "同步 benchmark 目录到最新版本。"
        mkdir -p "${INIT_PATH}"
        safe_rm "${BM_PATH}"
        cp -rf "${BM_REPOS_PATH}" "${BM_PATH}"
    fi
}
# -------------------- 告警通知函数 --------------------
# -------------------- 公共告警通知函数 --------------------
# 默认供吞吐监控使用，入口脚本通常不直接调用。
sendMsg() {
    local error_type="$1"
    local date_time
    local test_type="${test_type:-性能测试}"  # 默认值
    local headline=''
    local msgbody=''
    
    date_time="$(date '+%Y-%m-%d %H:%M:%S')"
    
    case "${error_type}" in
        1)
            # 1. 吞吐量监控异常
            headline="吞吐量监控异常告警"
            msgbody="[Atmos性能测试告警]\n错误类型：吞吐量异常\n告警时间：${date_time}\n测试类型：${test_type}\n当前吞吐量：${2}\n控制上限：${3}\n控制下限：${4}\n历史均值：${5}\n"
            ;;
        2)
            # 2. 其他错误类型（可根据需要扩展）
            headline="${test_type}代码编译失败"
            msgbody="错误类型：${test_type}代码编译失败\n报错时间：${date_time}\n报错Commit：${commit_id:-N/A}\n提交人：${author:-N/A}\n报错信息：${comp_mvn:-N/A}"
            ;;
        *)
            log "未知错误类型: ${error_type}"
            return 1
            ;;
    esac
    
    # 发送钉钉消息
    local dingtalk_token="f2d691d45da9a0307af8bbd853e90d0785dbaa3a3b0219dd2816882e19859e62"
    local dingtalk_url="https://oapi.dingtalk.com/robot/send?access_token=${dingtalk_token}"
    
    # 构建JSON数据
    local json_data
    json_data=$(cat <<EOF
{
    "msgtype": "text",
    "text": {
        "content": "${msgbody}"
    }
}
EOF
)
    
    # 发送请求
    curl -s -X POST \
        -H 'Content-Type: application/json' \
        -d "${json_data}" \
        "${dingtalk_url}" > /dev/null 2>&1 &
    
    log "已发送钉钉告警通知: ${headline}"
    return 0
}
# -------------------- 监控控制函数 --------------------
# -------------------- 公共吞吐监控函数 --------------------
# 默认以 ts_type/api_type/protocol 为历史基线；config_insert 可通过预留 hook 替换为配置项维度。
check_throughput_monitor() {
    local commit_date_time="$1"
    local throughput="$2"
    local protocol_code="$3"
    local current_ts_type="$4"
    local current_api_type="$5"

    
    # 获取最近100条同类型数据（排除本次测试结果）
    local data
    data="$(mysql_exec "
        SELECT throughput 
        FROM ${result_table} 
        WHERE commit_date_time < '${commit_date_time}' 
        AND ts_type = '${current_ts_type}' 
        AND api_type = '${current_api_type}'
        AND protocol = '${protocol_code}'
        AND throughput > 0  -- 只取有效数据
        ORDER BY commit_date_time DESC 
        LIMIT 100
    ")" || {
        log "监控: 获取历史数据失败"
        return 0
    }
    
    # 如果没有足够的历史数据，跳过监控
    local data_count=$(echo "$data" | wc -l)
    if [ "$data_count" -lt 20 ]; then
        log "监控: 历史数据不足 ($data_count 条)，跳过监控检查"
        return 0
    fi
    
    # 计算均值和标准差
    local mean std
    mean="$(echo "$data" | awk '
        {sum+=$1; sumsq+=$1*$1} 
        END {if(NR>0) printf "%.10f\n", sum/NR; else print 0}
    ')"
    
    std="$(echo "$data" | awk '
        {sum+=$1; sumsq+=$1*$1} 
        END {
            if(NR>0) {
                var = sumsq/NR - (sum/NR)^2
                if(var < 0) var = 0
                printf "%.10f\n", sqrt(var)
            } else {
                print 0
            }
        }
    ')"
    
    # 计算控制限
    local ucl lcl
    mean="$(normalize_decimal "${mean}")"
    std="$(normalize_decimal "${std}")"
    ucl="$(awk -v mean="${mean}" -v std="${std}" 'BEGIN { printf "%.10f\n", mean + 3 * std }')"
    lcl="$(awk -v mean="${mean}" -v std="${std}" 'BEGIN { value = mean - 3 * std; if (value < 0) value = 0; printf "%.10f\n", value }')"
    
    # 确保LCL不小于0
    ucl="$(normalize_decimal "${ucl}")"
    lcl="$(normalize_decimal "${lcl}")"
    log "吞吐量 $throughput 控制限 [$lcl, $ucl] (均值: $mean, 标准差: $std)"
    # 检查最新吞吐量是否超出控制限
    if awk -v throughput="${throughput}" 'BEGIN { exit !((throughput + 0) > 0) }'; then
        if awk -v throughput="${throughput}" -v ucl="${ucl}" 'BEGIN { exit !((throughput + 0) > (ucl + 0)) }' || \
           awk -v throughput="${throughput}" -v lcl="${lcl}" 'BEGIN { exit !((throughput + 0) < (lcl + 0) && (lcl + 0) > 0) }'; then
            log "监控警报: 吞吐量 $throughput 超出控制限 [$lcl, $ucl] (均值: $mean, 标准差: $std)"
			sendMsg 1 "${throughput}" "${ucl}" "${lcl}" "${mean}"
            return 1
        else
            log "监控正常: 吞吐量 $throughput 在控制限内 [$lcl, $ucl]"
            return 0
        fi
    else
        log "监控: 当前吞吐量为非正数 ($throughput)，跳过监控检查"
        return 0
    fi
}
# -------------------- 公共测试指标初始化函数 --------------------
# 每个 case 开始前重置全局指标，避免上一个 case 的结果污染本次入库数据。
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
    maxCPULoad=0
    avgCPULoad=0
    maxDiskIOOpsRead=0
    maxDiskIOOpsWrite=0
    maxDiskIOSizeRead=0
    maxDiskIOSizeWrite=0
    m_start_time=0
    m_end_time=0
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
        log "未检测到${desc}。"
        return 0
    fi

    while IFS= read -r pid; do
        [ -n "${pid}" ] || continue
        kill -9 "${pid}"
    done <<< "${pids}"
    log "${desc} 已停止。"
}

check_benchmark_pid() {
    check_pid_and_kill "App" "BM程序"
}

check_iotdb_pid() {
    check_pid_and_kill "DataNode" "DataNode程序"
    check_pid_and_kill "ConfigNode" "ConfigNode程序"
    check_pid_and_kill "IoTDB" "IoTDB程序"
}

# -------------------- 公共 IoTDB / Benchmark 生命周期函数 --------------------
# 负责准备待测版本、修改基础配置、设置共识协议、启动/停止服务和等待可用。
set_env() {
    local source_path="${REPOS_PATH}/${commit_id}/apache-iotdb"
    [ -d "${source_path}" ] || die "缺少待测版本目录: ${source_path}"

    safe_rm "${TEST_IOTDB_PATH}"
    mkdir -p "${TEST_IOTDB_PATH}/activation"
    cp -rf "${source_path}/." "${TEST_IOTDB_PATH}/"
    copy_if_exists "${ATMOS_PATH}/conf/${TEST_TYPE}/license" "${TEST_IOTDB_PATH}/activation/" "license"
    copy_if_exists "${ATMOS_PATH}/conf/${TEST_TYPE}/env" "${TEST_IOTDB_PATH}/.env" "env"
}

modify_iotdb_config() {
    local datanode_env="${TEST_IOTDB_PATH}/conf/datanode-env.sh"
    local properties_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"

    [ -f "${datanode_env}" ] || die "缺少配置文件: ${datanode_env}"
    [ -f "${properties_file}" ] || die "缺少配置文件: ${properties_file}"

    sed -i 's/^#\?ON_HEAP_MEMORY=.*$/ON_HEAP_MEMORY="20G"/' "${datanode_env}"

    # 每次测试都会从干净源码重新准备工作目录，因此这里直接追加覆盖配置，
    # 不会在不同 commit 之间持续累积。
    cat >> "${properties_file}" <<EOF
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
    if [ ! -d "${TEST_IOTDB_PATH}" ]; then
        return 0
    fi

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

start_benchmark() {
    safe_rm "${BM_PATH}/logs"
    safe_rm "${BM_PATH}/data"
    (
        cd "${BM_PATH}" || exit 1
        ./benchmark.sh >/dev/null 2>&1 &
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

change_root_password() {
    "${TEST_IOTDB_PATH}/sbin/start-cli.sh" -e "ALTER USER root SET PASSWORD '${IOTDB_PW}'" >/dev/null 2>&1
}

# -------------------- 公共 Benchmark 结果定位和状态监控函数 --------------------
# 通过 IoT-Benchmark 输出 CSV 判断写入是否完成；超时时生成兜底结果，保证后续入库有失败记录。
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
    local index=0

    mkdir -p "${csv_file%/*}"
    : > "${csv_file}"
    for ((index = 0; index < 100; index++)); do
        echo "INGESTION ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1 ,-1" >> "${csv_file}"
    done
}

monitor_test_status() {
    local current_ts_type="$1"
    local csv_file=""
    local now_epoch=0
    local elapsed=0

    # 这里没有可直接复用的 IoT-Benchmark 完成回调，因此以结果 CSV 是否生成
    # 作为测试完成的唯一判定依据。超时后会补写一个 stuck 结果文件，确保后续
    # 解析和入库仍能留下可见的失败记录。
    while true; do
        csv_file="$(find_result_csv || true)"
        if [ -n "${csv_file}" ]; then
            end_time="$(current_datetime)"
            log "${current_ts_type} 写入已完成。"
            return 0
        fi

        now_epoch="$(date +%s)"
        elapsed=$((now_epoch - m_start_time))
        if [ "${elapsed}" -ge "${MONITOR_TIMEOUT_SECONDS}" ]; then
            end_time="$(current_datetime)"
            log "${current_ts_type} 写入超时，写入兜底结果。"
            create_stuck_result_csv "${BM_PATH}/data/csvOutput/Stuck_result.csv"
            return 1
        fi

        sleep "${MONITOR_POLL_INTERVAL_SECONDS}"
    done
}

# -------------------- 公共 Prometheus 指标采集函数 --------------------
# 采集文件数、线程数、WAL、CPU、磁盘 IO 等通用性能指标，供结果入库使用。
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

normalize_decimal() {
    awk -v value="${1:-0}" 'BEGIN {
        value += 0
        text = sprintf("%.10f", value)
        sub(/0+$/, "", text)
        sub(/\.$/, "", text)
        if (text == "" || text == "-0") {
            text = "0"
        }
        print text
    }'
}

collect_monitor_data() {
    local ip="$1"
    local metric_window=$((m_end_time - m_start_time))
    local maxNumofThread_C=0
    local maxNumofThread_D=0
    local datanode_error_log_file="${TEST_IOTDB_PATH}/logs/log_datanode_error.log"
    local confignode_error_log_file="${TEST_IOTDB_PATH}/logs/log_confignode_error.log"
    local datanode_error_log_size=0
    local confignode_error_log_size=0

    resolve_monitor_disk_id
    dataFileSize="$(get_single_index "sum(file_global_size{instance=~\"${ip}:9091\"})" "${m_end_time}")"
    dataFileSize="$(bytes_to_gib "${dataFileSize}")"
    numOfSe0Level="$(get_single_index "sum(file_global_count{instance=~\"${ip}:9091\",name=\"seq\"})" "${m_end_time}")"
    numOfUnse0Level="$(get_single_index "sum(file_global_count{instance=~\"${ip}:9091\",name=\"unseq\"})" "${m_end_time}")"
    maxNumofThread_C="$(get_single_index "max_over_time(process_threads_count{instance=~\"${ip}:9081\"}[${metric_window}s])" "${m_end_time}")"
    maxNumofThread_D="$(get_single_index "max_over_time(process_threads_count{instance=~\"${ip}:9091\"}[${metric_window}s])" "${m_end_time}")"
    maxNumofThread=$(( $(to_int "${maxNumofThread_C}") + $(to_int "${maxNumofThread_D}") ))
    maxNumofOpenFiles="$(get_single_index "max_over_time(file_count{instance=~\"${ip}:9091\",name=\"open_file_handlers\"}[${metric_window}s])" "${m_end_time}")"
    datanode_error_log_size="$(du -sb "${datanode_error_log_file}" 2>/dev/null | awk '{print $1}')"
    confignode_error_log_size="$(du -sb "${confignode_error_log_file}" 2>/dev/null | awk '{print $1}')"
    errorLogSize=$(( ${datanode_error_log_size:-0} + ${confignode_error_log_size:-0} ))
    walFileSize="$(get_single_index "max_over_time(file_size{instance=~\"${ip}:9091\",name=~\"wal\"}[${metric_window}s])" "${m_end_time}")"
    walFileSize="$(bytes_to_gib "${walFileSize}")"
    maxCPULoad="$(get_single_index "max_over_time(sys_cpu_load{instance=~\"${ip}:9091\"}[${metric_window}s])" "${m_end_time}")"
    avgCPULoad="$(get_single_index "avg_over_time(sys_cpu_load{instance=~\"${ip}:9091\"}[${metric_window}s])" "${m_end_time}")"
    maxDiskIOOpsRead="$(get_single_index "sum(rate(disk_io_ops{instance=~\"${ip}:9091\",disk_id=~\"${disk_id_regex}\",type=~\"read\"}[${metric_window}s]))" "${m_end_time}")"
    maxDiskIOOpsWrite="$(get_single_index "sum(rate(disk_io_ops{instance=~\"${ip}:9091\",disk_id=~\"${disk_id_regex}\",type=~\"write\"}[${metric_window}s]))" "${m_end_time}")"
    maxDiskIOSizeRead="$(get_single_index "sum(rate(disk_io_size{instance=~\"${ip}:9091\",disk_id=~\"${disk_id_regex}\",type=~\"read\"}[${metric_window}s]))" "${m_end_time}")"
    maxDiskIOSizeWrite="$(get_single_index "sum(rate(disk_io_size{instance=~\"${ip}:9091\",disk_id=~\"${disk_id_regex}\",type=~\"write\"}[${metric_window}s]))" "${m_end_time}")"
}

# -------------------- 公共默认备份函数；特定脚本可覆盖 --------------------
# 默认用于 se_insert/unse_insert/api_insert/api_insert_cts。
# insert_records.sh 会在 source 后覆盖 backup_test_data，以按 seq_w/unseq_w 目录结构备份。
# last_cache_query.sh 也会覆盖 backup_test_data，以保存后台写入和查询 benchmark 的特定产物。
backup_test_data() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local current_api_type="$3"
    local backup_dir="${BACKUP_PATH}/${current_ts_type}_${current_api_type}/${commit_date_time}_${commit_id}_${protocol_code}"
    local backup_parent="${BACKUP_PATH}/${current_ts_type}_${current_api_type}"

    sudo_safe_rm "${backup_dir}"
    path_is_safe "${backup_parent}" || die "拒绝使用非预期备份路径: ${backup_parent}"
    sudo mkdir -p -- "${backup_parent}"
    path_is_safe "${backup_dir}" || die "拒绝使用非预期备份路径: ${backup_dir}"
    sudo mkdir -p -- "${backup_dir}"

    sudo_safe_rm "${TEST_IOTDB_PATH}/data"
    path_is_safe "${TEST_IOTDB_PATH}" || die "拒绝移动非预期路径: ${TEST_IOTDB_PATH}"
    sudo mv "${TEST_IOTDB_PATH}" "${backup_dir}"
    sudo cp -rf "${BM_PATH}/data/csvOutput" "${backup_dir}"
}

# -------------------- 公共默认配置文件切换函数；特定脚本可覆盖 --------------------
# 默认按 conf/${TEST_TYPE}/${ts_type}_${api_type} 选择 Benchmark 配置。
# insert_records.sh 会覆盖 mv_config_file，以支持 common_seq_w/common_unseq_w 等拆分目录。
mv_config_file() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local current_api_type="$3"
    local config_source="${ATMOS_PATH}/conf/${TEST_TYPE}/${current_ts_type}_${current_api_type}"
    local config_target="${BM_PATH}/conf/config.properties"

    [ -f "${config_source}" ] || die "缺少 benchmark 配置文件: ${config_source}"
    safe_rm "${config_target}"
    cp -rf "${config_source}" "${config_target}"
}

# -------------------- 公共结果解析和入库函数 --------------------
# parse_benchmark_result 解析通用 INGESTION 结果。
# insert_result_row 是默认入库实现；config_insert 可实现 insert_custom_result_row hook 改写入库字段。
# last_cache_query.sh 会在 source 后覆盖 insert_result_row，写入查询类的 last cache 结果字段。
parse_benchmark_result() {
    local csv_file="$1"
    local throughput_line=""
    local latency_line=""

    [ -f "${csv_file}" ] || return 1

    # IoT-Benchmark 会把吞吐和延迟写在不同的 INGESTION 行里，这里分开提取，
    # 避免强依赖固定表头或列布局。
    throughput_line="$(
        awk -F, '
            /^INGESTION/ {
                for (i = 2; i <= 6; i++) {
                    gsub(/^[ \t]+|[ \t]+$/, "", $i)
                    printf "%s%s", $i, (i == 6 ? ORS : OFS)
                }
                exit
            }
        ' OFS=$'\t' "${csv_file}"
    )"

    latency_line="$(
        awk -F, '
            /^INGESTION/ {
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
    local current_api_type="$3"
    local insert_sql=""

    if declare -F insert_custom_result_row >/dev/null 2>&1; then
        insert_custom_result_row "${protocol_code}" "${current_ts_type}" "${current_api_type}"
        return
    fi

    insert_sql=$(cat <<EOF
insert into ${result_table} (
    commit_date_time,test_date_time,commit_id,author,ts_type,okPoint,okOperation,failPoint,failOperation,throughput,
    Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,start_time,end_time,cost_time,
    numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,walFileSize,avgCPULoad,maxCPULoad,
    maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,api_type,protocol
) values (
    ${commit_date_time},
    ${test_date_time},
    $(sql_quote "${commit_id}"),
    $(sql_quote "${author}"),
    $(sql_quote "${current_ts_type}"),
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
    ${walFileSize},
    ${avgCPULoad},
    ${maxCPULoad},
    ${maxDiskIOSizeRead},
    ${maxDiskIOSizeWrite},
    ${maxDiskIOOpsRead},
    ${maxDiskIOOpsWrite},
    $(sql_quote "${current_api_type}"),
    ${protocol_code}
)
EOF
)

    mysql_exec "${insert_sql}"
}

# -------------------- 公共收尾函数 --------------------
cleanup_processes() {
    check_benchmark_pid
    check_iotdb_pid
}

# -------------------- 特定脚本预留扩展点：config_insert 吞吐监控 hook --------------------
# config_insert.sh 可定义 check_custom_throughput_monitor，用配置项名称和值作为历史基线维度。
check_current_throughput_monitor() {
    local commit_date_time="$1"
    local throughput="$2"
    local protocol_code="$3"
    local current_ts_type="$4"
    local current_api_type="$5"

    if declare -F check_custom_throughput_monitor >/dev/null 2>&1; then
        check_custom_throughput_monitor "${commit_date_time}" "${throughput}" "${protocol_code}" "${current_ts_type}" "${current_api_type}"
        return
    fi

    check_throughput_monitor "${commit_date_time}" "${throughput}" "${protocol_code}" "${current_ts_type}" "${current_api_type}"
}

# -------------------- 特定脚本预留扩展点：config_insert IoTDB 配置 hook --------------------
# config_insert.sh 可定义 modify_iotdb_config_for_case，在基础配置之后按当前 case 追加配置项。
apply_iotdb_config_hook() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local current_api_type="$3"

    if declare -F modify_iotdb_config_for_case >/dev/null 2>&1; then
        modify_iotdb_config_for_case "${protocol_code}" "${current_ts_type}" "${current_api_type}"
    fi
}

# -------------------- 公共默认单 case 执行流程；特定脚本可覆盖 --------------------
# 默认流程覆盖“准备 IoTDB -> 写入 Benchmark -> 解析结果 -> 采集指标 -> 备份数据”。
# last_cache_query.sh 会在 source 后覆盖 test_operation，因为它需要同时运行写入和查询两个 Benchmark。
test_operation() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local current_api_type="$3"
    local csv_file=""
    local monitor_failed=0
    # throughput / cost_time 的负值是约定好的哨兵值，用来在结果表中区分
    # 启动失败、鉴权失败、结果解析失败等不同异常场景。

    log "开始测试协议 ${protocol_code} 下的 ${current_ts_type} 时间序列。"
    init_items
    cleanup_processes
    set_env
    modify_iotdb_config
    apply_iotdb_config_hook "${protocol_code}" "${current_ts_type}" "${current_api_type}"

    if ! set_protocol_class "${protocol_code}"; then
        log "协议设置错误: ${protocol_code}"
        return 1
    fi

    start_iotdb
    sleep "${STARTUP_GRACE_SECONDS}"
    if ! wait_for_iotdb_ready; then
        log "IoTDB 未能正常启动，写入负值测试结果。"
        cost_time=-3
        throughput=-3
        insert_result_row "${protocol_code}" "${current_ts_type}" "${current_api_type}"
        cleanup_processes
        return 1
    fi

    if ! change_root_password; then
        log "root 密码修改失败，写入负值测试结果。"
        cost_time=-4
        throughput=-4
        insert_result_row "${protocol_code}" "${current_ts_type}" "${current_api_type}"
        cleanup_processes
        return 1
    fi

    mv_config_file "${protocol_code}" "${current_ts_type}" "${current_api_type}"
    start_benchmark
    start_time="$(current_datetime)"
    m_start_time="$(date +%s)"
    sleep "${BENCHMARK_WARMUP_SECONDS}"

    if ! monitor_test_status "${current_ts_type}"; then
        monitor_failed=1
    fi

    m_end_time="$(date +%s)"
    "${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw "${IOTDB_PW}" -h 127.0.0.1 -p 6667 -e "flush" >/dev/null 2>&1 || true
    collect_monitor_data "${TEST_IP}"

    csv_file="$(find_result_csv || true)"
    if [ -z "${csv_file}" ] || ! parse_benchmark_result "${csv_file}"; then
        log "benchmark 结果解析失败，写入负值测试结果。"
        [ -n "${end_time}" ] || end_time="$(current_datetime)"
        cost_time=-2
        throughput=-2
        insert_result_row "${protocol_code}" "${current_ts_type}" "${current_api_type}"
        stop_iotdb
        sleep "${BENCHMARK_STOP_WAIT_SECONDS}"
        cleanup_processes
        [ -d "${TEST_IOTDB_PATH}" ] && backup_test_data "${protocol_code}" "${current_ts_type}" "${current_api_type}"
        return 1
    fi

    [ -n "${end_time}" ] || end_time="$(current_datetime)"
    cost_time=$(( $(datetime_to_epoch "${end_time}") - $(datetime_to_epoch "${start_time}") ))
    insert_result_row "${protocol_code}" "${current_ts_type}" "${current_api_type}"
    
    # 在插入结果后，调用监控函数检查是否报警
    if (( $(echo "$throughput > 0" | bc -l 2>/dev/null) )); then
        if ! check_current_throughput_monitor "${commit_date_time}" "${throughput}" "${protocol_code}" "${current_ts_type}" "${current_api_type}"; then
            log "当前测试结果触发监控警报，但测试流程继续"
        else
            log "当前测试结果吞吐符合规律"
        fi
    fi

    stop_iotdb
    sleep "${BENCHMARK_STOP_WAIT_SECONDS}"
    cleanup_processes
    [ -d "${TEST_IOTDB_PATH}" ] && backup_test_data "${protocol_code}" "${current_ts_type}" "${current_api_type}"

    return "${monitor_failed}"
}

# -------------------- 公共调度状态函数 --------------------
# 与外层调度器通过 test_type_file 协同当前测试状态。
mark_test_in_progress() {
    # 这个文件会被外层调度器读取，作为当前测试状态的粗粒度协同信号，
    # 因此即使脚本提前退出，也要保证它被正确更新。
    printf 'ontesting\n' > "${INIT_PATH}/test_type_file"
}

# Scheduler reads this file to decide which test suite should run next.
restore_test_type_file() {
    printf '%s\n' "${TEST_TYPE}" > "${INIT_PATH}/test_type_file"
}

# -------------------- 公共主流程入口 --------------------
# 由各入口脚本在 source 后调用 main "$@"，统一完成依赖检查、取 commit、遍历协议/类型/API 并更新任务状态。
main() {
    local protocol=""
    local ts=""
    local task_failed=0

    trap restore_test_type_file EXIT

    ensure_runtime_dependencies
    check_password
    if [ "${ENABLE_BENCHMARK_VERSION_CHECK}" = "1" ]; then
        check_benchmark_version
    fi

    mark_test_in_progress
    if ! fetch_next_commit; then
        sleep 60
        return 0
    fi

    update_task_status "ontesting"
    log "当前版本 ${commit_id} 未执行过测试，即将启动测试流程。"

    if [ "${author}" = "Timecho" ]; then
        result_table="${TABLENAME_T}"
    else
        result_table="${TABLENAME}"
    fi

    test_date_time="$(date +%Y%m%d%H%M%S)"
    for protocol in "${PROTOCOL_LIST[@]}"; do
        for ts in "${TS_LIST[@]}"; do
            for api in "${API_LIST[@]}"; do
                if ! test_operation "${protocol}" "${ts}" "${api}"; then
                    task_failed=1
                fi
            done
        done
    done

    log "本轮测试 ${test_date_time} 已结束。"
    if [ "${task_failed}" -eq 0 ]; then
        update_task_status "done"
        if [ "${author}" != "Timecho" ]; then
            mark_older_commits_skip
        fi
    else
        update_task_status "RError"
    fi
}
