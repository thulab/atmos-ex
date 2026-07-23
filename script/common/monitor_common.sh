#!/usr/bin/env bash

# 功能：读取并返回指定配置、路径或指标值
get_monitor_disk_fallback_path() {
    local data_path="${TEST_IOTDB_PATH}/data"
    if [ -d "${data_path}" ]; then
        printf '%s\n' "${data_path}"
    else
        printf '%s\n' "${TEST_IOTDB_PATH}"
    fi
}

# 功能：读取并返回指定配置、路径或指标值
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
        END { if (last_value != "") print last_value }
    ' "${properties_file}"
}

# 功能：拆分 IoTDB 配置中的逗号或分号分隔路径列表
split_iotdb_path_list() {
    local value="$1"
    local item=""
    local -a items=()
    value="${value//;/,}"
    value="${value//\"/}"
    IFS=',' read -r -a items <<< "${value}"
    for item in "${items[@]}"; do
        item="$(trim "${item}")"
        [ -n "${item}" ] && printf '%s\n' "${item}"
    done
}

# 功能：规范化输入值以便后续比较或存储
normalize_monitor_target_path() {
    local path="$(trim "$1")"
    path="${path%/}"
    case "${path}" in
        /*) printf '%s\n' "${path}" ;;
        *) printf '%s\n' "${TEST_IOTDB_PATH}/${path}" ;;
    esac
}

# 功能：读取并返回指定配置、路径或指标值
get_monitor_disk_target_paths() {
    local properties_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
    local property_key=""
    local property_value=""
    local raw_path=""
    local found=0
    local -a property_keys=(dn_data_dirs dn_wal_dirs)

    if [ -f "${properties_file}" ]; then
        for property_key in "${property_keys[@]}"; do
            property_value="$(get_iotdb_property_value "${properties_file}" "${property_key}")"
            [ -n "${property_value}" ] || continue
            while IFS= read -r raw_path; do
                [ -n "${raw_path}" ] || continue
                normalize_monitor_target_path "${raw_path}"
                found=1
            done < <(split_iotdb_path_list "${property_value}")
        done
    fi
    [ "${found}" -ne 0 ] || get_monitor_disk_fallback_path
}

# 功能：从候选监控目录中返回第一个实际存在的路径
find_existing_monitor_path() {
    local path="$1"
    while [ ! -e "${path}" ] && [ "${path}" != / ]; do
        path="${path%/*}"
        [ -n "${path}" ] || path=/
    done
    [ -e "${path}" ] || return 1
    printf '%s\n' "${path}"
}

# 功能：判断集合中是否包含指定值
contains_value() {
    local expected="$1"
    shift
    local actual=""
    for actual in "$@"; do
        [ "${actual}" = "${expected}" ] && return 0
    done
    return 1
}

# 功能：根据当前配置构造路径、表达式或参数
build_disk_id_regex() {
    local regex=""
    local disk_id=""
    for disk_id in "$@"; do
        regex="${regex:+${regex}|}${disk_id}"
    done
    printf '^(%s)$\n' "${regex:-${DEFAULT_DISK_ID:-sdb}}"
}

# 功能：探测当前主机、磁盘或运行环境信息
detect_disk_id_from_path() {
    local target_path="$1"
    local existing_path=""
    local source_device=""
    local resolved_device=""
    local parent_device=""

    require_command findmnt
    require_command lsblk
    existing_path="$(find_existing_monitor_path "${target_path}" || true)"
    [ -n "${existing_path}" ] || return 1
    source_device="$(findmnt -no SOURCE --target "${existing_path}" 2>/dev/null | awk 'NF {print; exit}')"
    [ -n "${source_device}" ] || return 1
    source_device="${source_device%%[*}"
    resolved_device="$(readlink -f "${source_device}" 2>/dev/null || printf '%s\n' "${source_device}")"
    [ -b "${resolved_device}" ] || return 1
    while true; do
        parent_device="$(lsblk -ndo PKNAME "${resolved_device}" 2>/dev/null | awk 'NF {print; exit}')"
        [ -n "${parent_device}" ] || break
        resolved_device="/dev/${parent_device}"
    done
    printf '%s\n' "${resolved_device##*/}"
}

# 功能：根据候选路径或配置解析最终使用值
resolve_monitor_disk_id() {
    local target_path=""
    local detected_disk_id=""
    local -a disk_ids=()
    local -a target_paths=()

    disk_id_regex="^${DEFAULT_DISK_ID:-sdb}$"
    while IFS= read -r target_path; do
        [ -n "${target_path}" ] || continue
        target_paths+=("${target_path}")
        detected_disk_id="$(detect_disk_id_from_path "${target_path}" || true)"
        [ -n "${detected_disk_id}" ] || continue
        contains_value "${detected_disk_id}" "${disk_ids[@]:-}" || disk_ids+=("${detected_disk_id}")
    done < <(get_monitor_disk_target_paths)

    if [ "${#disk_ids[@]}" -gt 0 ]; then
        disk_id_regex="$(build_disk_id_regex "${disk_ids[@]}")"
        log "resolved disk ids ${disk_ids[*]} from ${target_paths[*]}"
    else
        log "failed to resolve disk ids; fallback to ${DEFAULT_DISK_ID:-sdb}"
    fi
}

# 功能：查询并转换 Prometheus 指标值
prometheus_value() {
    local query="$1"
    local metric_time="$2"
    curl -G -s "http://${METRIC_SERVER}/api/v1/query" \
        --data-urlencode "query=${query}" --data-urlencode "time=${metric_time}" |
        jq -r '.data.result[0].value[1] // 0'
}

# 功能：读取并返回指定配置、路径或指标值
get_single_index() {
    prometheus_value "$1" "$2"
}

# 功能：将字节数转换为 GiB 数值
bytes_to_gib() {
    awk -v value="${1:-0}" 'BEGIN {printf "%.6f", value / 1024 / 1024 / 1024}'
}

# 功能：将输入值规范化为整数
to_int() {
    awk -v value="${1:-0}" 'BEGIN {printf "%d", value + 0}'
}

# 功能：返回指定文件的字节大小
file_size_bytes() {
    local path="$1"
    [ -f "${path}" ] && wc -c < "${path}" || printf '0\n'
}

# 功能：记录监控窗口开始时间
begin_monitor_window() {
    m_start_time="$(date +%s)"
}

# 功能：记录监控窗口结束时间并计算有效窗口长度
end_monitor_window() {
    m_end_time="$(date +%s)"
    monitor_window_seconds=$((m_end_time - m_start_time))
    [ "${monitor_window_seconds}" -gt 0 ] || monitor_window_seconds=1
}

# 功能：采集标准 IoTDB 文件、线程、CPU、WAL 和磁盘指标
collect_standard_monitor_snapshot() {
    local ip="${1:-${TEST_IP}}"
    local window="${2:-${monitor_window_seconds:-$((m_end_time - m_start_time))}}"
    local cn_threads=0
    local dn_threads=0

    [ "${window}" -gt 0 ] || window=1
    dataFileSize="$(bytes_to_gib "$(prometheus_value "sum(file_global_size{instance=~\"${ip}:9091\"})" "${m_end_time}")")"
    numOfSe0Level="$(prometheus_value "sum(file_global_count{instance=~\"${ip}:9091\",name=\"seq\"})" "${m_end_time}")"
    numOfUnse0Level="$(prometheus_value "sum(file_global_count{instance=~\"${ip}:9091\",name=\"unseq\"})" "${m_end_time}")"
    cn_threads="$(prometheus_value "max_over_time(process_threads_count{instance=~\"${ip}:9081\"}[${window}s])" "${m_end_time}")"
    dn_threads="$(prometheus_value "max_over_time(process_threads_count{instance=~\"${ip}:9091\"}[${window}s])" "${m_end_time}")"
    maxNumofThread=$(( $(to_int "${cn_threads}") + $(to_int "${dn_threads}") ))
    maxNumofOpenFiles="$(prometheus_value "max_over_time(file_count{instance=~\"${ip}:9091\",name=\"open_file_handlers\"}[${window}s])" "${m_end_time}")"
    walFileSize="$(bytes_to_gib "$(prometheus_value "max_over_time(file_size{instance=~\"${ip}:9091\",name=~\"wal\"}[${window}s])" "${m_end_time}")")"
    maxCPULoad="$(prometheus_value "max_over_time(sys_cpu_load{instance=~\"${ip}:9091\"}[${window}s])" "${m_end_time}")"
    avgCPULoad="$(prometheus_value "avg_over_time(sys_cpu_load{instance=~\"${ip}:9091\"}[${window}s])" "${m_end_time}")"
    maxDiskIOOpsRead="$(prometheus_value "sum(rate(disk_io_ops{instance=~\"${ip}:9091\",disk_id=~\"${disk_id_regex:-.*}\",type=~\"read\"}[${window}s]))" "${m_end_time}")"
    maxDiskIOOpsWrite="$(prometheus_value "sum(rate(disk_io_ops{instance=~\"${ip}:9091\",disk_id=~\"${disk_id_regex:-.*}\",type=~\"write\"}[${window}s]))" "${m_end_time}")"
    maxDiskIOSizeRead="$(prometheus_value "sum(rate(disk_io_size{instance=~\"${ip}:9091\",disk_id=~\"${disk_id_regex:-.*}\",type=~\"read\"}[${window}s]))" "${m_end_time}")"
    maxDiskIOSizeWrite="$(prometheus_value "sum(rate(disk_io_size{instance=~\"${ip}:9091\",disk_id=~\"${disk_id_regex:-.*}\",type=~\"write\"}[${window}s]))" "${m_end_time}")"
}
