#!/usr/bin/env bash
set -o pipefail

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

readonly IOTDB_PASSWORD="TimechoDB@2021"

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

readonly MYSQL_HOST="111.200.37.158"
readonly MYSQL_PORT="13306"
readonly MYSQL_USERNAME="iotdbatm"
readonly MYSQL_PASSWORD="${ATMOS_DB_PASSWORD:-}"
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
# 将删除类操作限制在已知工作目录内，避免变量展开异常时误删宿主机上的
# 非预期路径。
# -------------------- 公共安全路径和文件操作函数 --------------------
# 所有删除/移动前先通过 path_is_safe 做路径白名单校验，避免变量为空或拼接异常时误删宿主机目录。
# -------------------- 公共监控磁盘识别函数 --------------------
# 根据 IoTDB 配置中的数据目录/WAL 目录解析实际落盘设备，用于 Prometheus 磁盘 IO 指标过滤。
# -------------------- 公共 MySQL 和任务队列函数 --------------------
# 负责访问 QA_ATM、读取待测 commit、更新任务状态和安全拼接 SQL 字符串。
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
    # Atmos性能测试告警功能已按要求注释掉；保留函数壳避免历史调用报错。
    return 0

    : <<'ATMOS_PERF_ALERT_DISABLED'
    local error_type="$1"
    local date_time
    local alert_test_type="${alert_test_type:-性能测试}"  # 默认值
    local headline=''
    local msgbody=''
    
    date_time="$(date '+%Y-%m-%d %H:%M:%S')"
    
    case "${error_type}" in
        1)
            # 1. 吞吐量监控异常
            headline="吞吐量监控异常告警"
            msgbody="[Atmos性能测试告警]\n错误类型：吞吐量异常\n告警时间：${date_time}\n测试类型：${alert_test_type}\n当前吞吐量：${2}\n控制上限：${3}\n控制下限：${4}\n历史均值：${5}\n"
            ;;
        2)
            # 2. 其他错误类型（可根据需要扩展）
            headline="${alert_test_type}代码编译失败"
            msgbody="错误类型：${alert_test_type}代码编译失败\n报错时间：${date_time}\n报错Commit：${commit_id:-N/A}\n提交人：${author:-N/A}\n报错信息：${comp_mvn:-N/A}"
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
ATMOS_PERF_ALERT_DISABLED
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
            # Atmos性能测试告警功能已注释掉，不再发送通知。
            # sendMsg 1 "${throughput}" "${ucl}" "${lcl}" "${mean}"
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
# -------------------- 公共 Benchmark 结果定位和状态监控函数 --------------------
# 通过 IoT-Benchmark 输出 CSV 判断写入是否完成；超时时生成兜底结果，保证后续入库有失败记录。
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
    "${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw "${IOTDB_PASSWORD}" -h 127.0.0.1 -p 6667 -e "flush" >/dev/null 2>&1 || true
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
# Scheduler reads this file to decide which test suite should run next.
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

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runtime_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/iotdb_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/benchmark_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remote_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/monitor_common.sh"
