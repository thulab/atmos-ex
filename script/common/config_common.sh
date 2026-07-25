#!/usr/bin/env bash

# 功能：将配置维度转换为可安全用于文件名的值；保留查询编号原有大小写和格式
config_safe_component() {
    local value="${1:-}"
    value="$(printf '%s' "${value}" | sed 's/[^A-Za-z0-9._=-]/_/g; s/^_*//; s/_*$//')"
    [ -n "${value}" ] || value="unknown"
    printf '%s' "${value}"
}

# 功能：按 key/value 维度生成统一 Benchmark case 标识
config_build_case_id() {
    local result=""
    local key=""
    local value=""

    [ $(( $# % 2 )) -eq 0 ] || die "config dimensions must be key/value pairs"
    while [ "$#" -gt 0 ]; do
        key="$(config_safe_component "$1")"
        value="$(config_safe_component "$2")"
        result="${result:+${result}__}${key}=${value}"
        shift 2
    done
    printf '%s' "${result:-case=default}"
}

# 功能：返回当前场景统一配置根目录
scenario_config_root() {
    printf '%s/conf/%s' "${ATMOS_PATH}" "${TEST_TYPE}"
}

# 功能：返回当前场景指定 Benchmark case 的配置路径
benchmark_case_config_path() {
    local case_id="$1"
    printf '%s/benchmark/cases/%s.properties' "$(scenario_config_root)" "$(config_safe_component "${case_id}")"
}

# 功能：复制并安装指定配置文件
install_config_file() {
    local source_file="$1"
    local target_file="$2"
    [ -f "${source_file}" ] || die "missing config file: ${source_file}"
    mkdir -p "${target_file%/*}"
    cp -f -- "${source_file}" "${target_file}"
}

# 功能：安装 Benchmark 配置文件
install_benchmark_config() {
    install_config_file "$1" "${2:-${BM_PATH}/conf/config.properties}"
}

# 功能：按统一 case 标识原子安装 Benchmark 配置
install_benchmark_case_config() {
    local case_id="$1"
    local benchmark_path="${2:-${BM_PATH}}"
    local source_file=""
    local target_file="${benchmark_path}/conf/config.properties"
    local temp_file="${target_file}.tmp.${BASHPID}"

    source_file="$(benchmark_case_config_path "${case_id}")"
    [ -f "${source_file}" ] || die "missing benchmark case config: ${source_file}"
    mkdir -p "${target_file%/*}"
    cp -f -- "${source_file}" "${temp_file}"
    mv -f -- "${temp_file}" "${target_file}"
    log "installed benchmark config: case=${case_id}, source=${source_file}"
}

# 功能：安装配置后单独应用运行时 Benchmark 覆盖项
apply_benchmark_overrides() {
    local benchmark_path="$1"
    shift
    upsert_properties "${benchmark_path}/conf/config.properties" "$@"
}

# 功能：安装当前场景统一存放的 IoTDB license 和 env
install_iotdb_runtime_config() {
    local scenario_root=""
    local include_env="${1:-${COPY_IOTDB_ENV:-1}}"
    scenario_root="$(scenario_config_root)/iotdb"
    copy_if_exists "${scenario_root}/activation/license" "${TEST_IOTDB_PATH}/activation/" "license"
    if [ "${include_env}" = "1" ]; then
        copy_if_exists "${scenario_root}/env/.env" "${TEST_IOTDB_PATH}/.env" "env"
    fi
}

# 功能：安装多节点场景中指定角色的 IoTDB license 和 env
install_iotdb_node_runtime_config() {
    local role="$1"
    local target_root="$2"
    local node_root=""

    node_root="$(scenario_config_root)/nodes/$(config_safe_component "${role}")/iotdb"
    copy_if_exists "${node_root}/activation/license" "${target_root}/activation/" "${role} license"
    copy_if_exists "${node_root}/env/.env" "${target_root}/.env" "${role} env"
}

# 功能：批量更新 properties 文件
upsert_properties() {
    local properties_file="$1"
    local property=""
    shift
    for property in "$@"; do
        set_iotdb_property "${properties_file}" "${property%%=*}" "${property#*=}"
    done
}

# 功能：应用标准 IoTDB 配置组
apply_iotdb_profile() {
    local profile="$1"
    local properties_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
    case "${profile}" in
        no_compaction)
            upsert_properties "${properties_file}" \
                "enable_seq_space_compaction=false" \
                "enable_unseq_space_compaction=false" \
                "enable_cross_space_compaction=false"
            ;;
        metrics)
            upsert_properties "${properties_file}" \
                "cn_enable_metric=true" "cn_enable_performance_stat=true" \
                "cn_metric_reporter_list=PROMETHEUS" "cn_metric_level=ALL" \
                "cn_metric_prometheus_reporter_port=9081" \
                "dn_enable_metric=true" "dn_enable_performance_stat=true" \
                "dn_metric_reporter_list=PROMETHEUS" "dn_metric_level=ALL" \
                "dn_metric_prometheus_reporter_port=9091"
            ;;
        base)
            apply_iotdb_profile no_compaction
            upsert_properties "${properties_file}" "cluster_name=${TEST_TYPE}"
            apply_iotdb_profile metrics
            ;;
        *) die "unknown IoTDB profile: ${profile}" ;;
    esac
}

# 功能：统一设置 DataNode 和 ConfigNode 堆内存
set_iotdb_heap_memory() {
    local datanode_memory="$1"
    local confignode_memory="${2:-}"
    local datanode_env="${TEST_IOTDB_PATH}/conf/datanode-env.sh"
    local confignode_env="${TEST_IOTDB_PATH}/conf/confignode-env.sh"
    [ -f "${datanode_env}" ] || die "missing config file: ${datanode_env}"
    sed -i "s/^#\?ON_HEAP_MEMORY=.*$/ON_HEAP_MEMORY=\"${datanode_memory}\"/" "${datanode_env}"
    if [ -n "${confignode_memory}" ] && [ -f "${confignode_env}" ]; then
        sed -i "s/^#\?ON_HEAP_MEMORY=.*$/ON_HEAP_MEMORY=\"${confignode_memory}\"/" "${confignode_env}"
    fi
}
