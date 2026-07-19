#!/usr/bin/env bash

get_monitor_disk_fallback_path() {
    local data_path="${TEST_IOTDB_PATH}/data"
    if [ -d "${data_path}" ]; then
        printf '%s\n' "${data_path}"
    else
        printf '%s\n' "${TEST_IOTDB_PATH}"
    fi
}

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

normalize_monitor_target_path() {
    local path="$(trim "$1")"
    path="${path%/}"
    case "${path}" in
        /*) printf '%s\n' "${path}" ;;
        *) printf '%s\n' "${TEST_IOTDB_PATH}/${path}" ;;
    esac
}

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

find_existing_monitor_path() {
    local path="$1"
    while [ ! -e "${path}" ] && [ "${path}" != / ]; do
        path="${path%/*}"
        [ -n "${path}" ] || path=/
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
    local disk_id=""
    for disk_id in "$@"; do
        regex="${regex:+${regex}|}${disk_id}"
    done
    printf '^(%s)$\n' "${regex:-${DEFAULT_DISK_ID:-sdb}}"
}

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

prometheus_value() {
    local query="$1"
    local metric_time="$2"
    curl -G -s "http://${METRIC_SERVER}/api/v1/query" \
        --data-urlencode "query=${query}" --data-urlencode "time=${metric_time}" |
        jq -r '.data.result[0].value[1] // 0'
}

get_single_index() {
    prometheus_value "$1" "$2"
}

bytes_to_gib() {
    awk -v value="${1:-0}" 'BEGIN {printf "%.6f", value / 1024 / 1024 / 1024}'
}

to_int() {
    awk -v value="${1:-0}" 'BEGIN {printf "%d", value + 0}'
}

file_size_bytes() {
    local path="$1"
    [ -f "${path}" ] && wc -c < "${path}" || printf '0\n'
}
