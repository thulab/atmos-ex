#!/usr/bin/env bash

# 功能：根据三位协议编号和 protocol_class 数组设置共识协议
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
