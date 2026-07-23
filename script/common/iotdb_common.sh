#!/usr/bin/env bash

COPY_IOTDB_ENV="${COPY_IOTDB_ENV:-1}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/iotdb_distribution_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/iotdb_service_common.sh"

# 功能：按当前测试场景修改 IoTDB 配置
modify_iotdb_config() {
    local datanode_env="${TEST_IOTDB_PATH}/conf/datanode-env.sh"
    local properties_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
    [ -f "${datanode_env}" ] || die "missing config file: ${datanode_env}"
    [ -f "${properties_file}" ] || die "missing config file: ${properties_file}"
    sed -i "s/^#\?ON_HEAP_MEMORY=.*$/ON_HEAP_MEMORY=\"${IOTDB_HEAP_MEMORY:-20G}\"/" "${datanode_env}"
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
    if declare -F append_iotdb_case_properties >/dev/null 2>&1; then
        append_iotdb_case_properties "${properties_file}"
    fi
}

# 功能：根据协议编号设置各共识组使用的协议实现
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

# 功能：检测并设置 IoTDB root 用户密码
change_root_password() {
    if "${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw "${IOTDB_PASSWORD}" -e "show cluster" >/dev/null 2>&1; then
        return 0
    fi
    "${TEST_IOTDB_PATH}/sbin/start-cli.sh" -e "ALTER USER root SET PASSWORD '${IOTDB_PASSWORD}'" >/dev/null 2>&1
}
