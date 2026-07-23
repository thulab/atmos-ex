#!/usr/bin/env bash

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
