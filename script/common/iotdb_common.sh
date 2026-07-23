#!/usr/bin/env bash

prepare_iotdb_distribution() {
    local source_path="${REPOS_PATH}/${commit_id}/apache-iotdb"
    [ -d "${source_path}" ] || die "missing tested IoTDB path: ${source_path}"
    safe_rm "${TEST_IOTDB_PATH}"
    mkdir -p "${TEST_IOTDB_PATH}/activation"
    cp -rf -- "${source_path}/." "${TEST_IOTDB_PATH}/"
    copy_if_exists "${ATMOS_PATH}/conf/${TEST_TYPE}/license" "${TEST_IOTDB_PATH}/activation/" "license"
    copy_if_exists "${ATMOS_PATH}/conf/${TEST_TYPE}/env" "${TEST_IOTDB_PATH}/.env" "env"
}

set_env() {
    prepare_iotdb_distribution
}

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
    if declare -F before_iotdb_start >/dev/null 2>&1; then
        before_iotdb_start
    fi
    (cd "${TEST_IOTDB_PATH}" && ./sbin/start-confignode.sh >/dev/null 2>&1 &)
    sleep "${STARTUP_GRACE_SECONDS:-10}"
    (cd "${TEST_IOTDB_PATH}" && ./sbin/start-datanode.sh -H "${TEST_IOTDB_PATH}/dn_dump.hprof" >/dev/null 2>&1 &)
}

stop_iotdb_once() {
    (cd "${TEST_IOTDB_PATH}" && ./sbin/stop-datanode.sh >/dev/null 2>&1 &)
    sleep "${IOTDB_STOP_DATANODE_WAIT_SECONDS:-${STARTUP_GRACE_SECONDS:-10}}"
    (cd "${TEST_IOTDB_PATH}" && ./sbin/stop-confignode.sh >/dev/null 2>&1 &)
    sleep "${IOTDB_STOP_CONFIGNODE_WAIT_SECONDS:-0}"
}

iotdb_processes_stopped() {
    [ -z "$(process_pids_by_name DataNode)" ] && [ -z "$(process_pids_by_name ConfigNode)" ]
}

stop_iotdb() {
    local attempt=0
    local retries="${IOTDB_STOP_RETRIES:-0}"
    [ -d "${TEST_IOTDB_PATH}" ] || return 0
    for ((attempt = 0; attempt <= retries; attempt++)); do
        stop_iotdb_once
        [ "${retries}" -eq 0 ] && return 0
        iotdb_processes_stopped && return 0
    done
    return 1
}

iotdb_is_ready() {
    local output=""
    local -a cli_args=()
    [ -z "${IOTDB_READY_USER:-}" ] || cli_args+=(-u "${IOTDB_READY_USER}")
    [ -z "${IOTDB_READY_PASSWORD:-}" ] || cli_args+=(-pw "${IOTDB_READY_PASSWORD}")
    output="$("${TEST_IOTDB_PATH}/sbin/start-cli.sh" "${cli_args[@]}" -e "show cluster" 2>/dev/null | grep -F 'Total line number = 2' || true)"
    [ "${output}" = "Total line number = 2" ]
}

wait_for_iotdb_ready() {
    wait_for_attempts "${IOTDB_READY_RETRIES:-10}" "${IOTDB_READY_INTERVAL_SECONDS:-5}" iotdb_is_ready
}

change_root_password() {
    if "${TEST_IOTDB_PATH}/sbin/start-cli.sh" -u root -pw "${IOTDB_PASSWORD}" -e "show cluster" >/dev/null 2>&1; then
        return 0
    fi
    "${TEST_IOTDB_PATH}/sbin/start-cli.sh" -e "ALTER USER root SET PASSWORD '${IOTDB_PASSWORD}'" >/dev/null 2>&1
}
