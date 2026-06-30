#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
if shopt -oq posix; then
    exec bash "${BASH_SOURCE[0]}" "$@"
fi

set -u
set -o pipefail

readonly TEST_IP="11.101.17.134"
readonly TEST_TYPE="config_insert"
readonly -a PROTOCOL_LIST=(111)
readonly -a TS_LIST=(aligned)
readonly -a API_LIST=(
    wal_mode_ASYNC
    wal_mode_DISABLE
    wal_mode_SYNC
    array_size_32
    array_size_64
    array_size_128
    array_size_256
    time_partition_604800000000
    time_partition_86400000
    time_partition_604800000
    chunk_metadata_size_0.1
    chunk_metadata_size_0.2
    chunk_metadata_size_0.3
    chunk_metadata_size_0.5
    compaction_priority_BALANCE
    compaction_priority_INNER_CROSS
    compaction_priority_CROSS_INNER
    target_chunk_size_1048576
    target_chunk_size_2097152
    target_chunk_size_4194304
    max_cross_compaction_candidate_file_size_5368709120
    max_cross_compaction_candidate_file_size_1073741824
    max_cross_compaction_candidate_file_size_10737418240
    max_cross_compaction_candidate_file_size_21474836480
)

config_case_name() {
    local case_id="$1"

    case "${case_id}" in
        wal_mode_*) printf 'wal_mode\n' ;;
        array_size_*) printf 'array_size\n' ;;
        time_partition_*) printf 'time_partition\n' ;;
        chunk_metadata_size_*) printf 'chunk_metadata_size\n' ;;
        compaction_priority_*) printf 'compaction_priority\n' ;;
        target_chunk_size_*) printf 'target_chunk_size\n' ;;
        max_cross_compaction_candidate_file_size_*) printf 'max_cross_compaction_candidate_file_size\n' ;;
        *) return 1 ;;
    esac
}

config_case_value() {
    local case_id="$1"

    case "${case_id}" in
        wal_mode_*) printf '%s\n' "${case_id#wal_mode_}" ;;
        array_size_*) printf '%s\n' "${case_id#array_size_}" ;;
        time_partition_*) printf '%s\n' "${case_id#time_partition_}" ;;
        chunk_metadata_size_*) printf '%s\n' "${case_id#chunk_metadata_size_}" ;;
        compaction_priority_*) printf '%s\n' "${case_id#compaction_priority_}" ;;
        target_chunk_size_*) printf '%s\n' "${case_id#target_chunk_size_}" ;;
        max_cross_compaction_candidate_file_size_*) printf '%s\n' "${case_id#max_cross_compaction_candidate_file_size_}" ;;
        *) return 1 ;;
    esac
}

append_iotdb_property() {
    local key="$1"
    local value="$2"
    local properties_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"

    printf '%s=%s\n' "${key}" "${value}" >> "${properties_file}"
}

enable_compaction_for_config_case() {
    append_iotdb_property "enable_seq_space_compaction" "true"
    append_iotdb_property "enable_unseq_space_compaction" "true"
    append_iotdb_property "enable_cross_space_compaction" "true"
}

modify_iotdb_config_for_case() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local current_api_type="$3"
    local config_name=""
    local config_value=""

    config_name="$(config_case_name "${current_api_type}")" || die "unsupported config case: ${current_api_type}"
    config_value="$(config_case_value "${current_api_type}")" || die "unsupported config case: ${current_api_type}"

    case "${config_name}" in
        time_partition)
            append_iotdb_property "time_partition_interval" "${config_value}"
            ;;
        wal_mode)
            append_iotdb_property "wal_mode" "${config_value}"
            ;;
        array_size)
            append_iotdb_property "primitive_array_size" "${config_value}"
            ;;
        chunk_metadata_size)
            append_iotdb_property "chunk_metadata_size_proportion_in_write" "${config_value}"
            ;;
        compaction_priority)
            enable_compaction_for_config_case
            append_iotdb_property "compaction_priority" "${config_value}"
            ;;
        target_chunk_size)
            enable_compaction_for_config_case
            append_iotdb_property "target_chunk_size" "${config_value}"
            ;;
        max_cross_compaction_candidate_file_size)
            enable_compaction_for_config_case
            append_iotdb_property "max_cross_compaction_candidate_file_size" "${config_value}"
            ;;
        *)
            die "unsupported config name: ${config_name}"
            ;;
    esac
}

insert_custom_result_row() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local current_api_type="$3"
    local config_name=""
    local config_value=""
    local insert_sql=""

    config_name="$(config_case_name "${current_api_type}")" || die "unsupported config case: ${current_api_type}"
    config_value="$(config_case_value "${current_api_type}")" || die "unsupported config case: ${current_api_type}"

    insert_sql=$(cat <<EOF
insert into ${result_table} (
    commit_date_time,test_date_time,commit_id,author,ts_type,config_name,config_value,okPoint,okOperation,failPoint,
    failOperation,throughput,Latency,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,numOfSe0Level,
    start_time,end_time,cost_time,numOfUnse0Level,dataFileSize,maxNumofOpenFiles,maxNumofThread,errorLogSize,
    walFileSize,avgCPULoad,maxCPULoad,maxDiskIOSizeRead,maxDiskIOSizeWrite,maxDiskIOOpsRead,maxDiskIOOpsWrite,protocol
) values (
    ${commit_date_time},
    ${test_date_time},
    $(sql_quote "${commit_id}"),
    $(sql_quote "${author}"),
    $(sql_quote "${current_ts_type}"),
    $(sql_quote "${config_name}"),
    $(sql_quote "${config_value}"),
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
    ${protocol_code}
)
EOF
)

    mysql_exec "${insert_sql}"
}

check_custom_throughput_monitor() {
    local commit_date_time="$1"
    local throughput="$2"
    local protocol_code="$3"
    local current_ts_type="$4"
    local current_api_type="$5"
    local config_name=""
    local config_value=""
    local data=""
    local data_count=0
    local mean=""
    local std=""
    local ucl=""
    local lcl=""

    config_name="$(config_case_name "${current_api_type}")" || die "unsupported config case: ${current_api_type}"
    config_value="$(config_case_value "${current_api_type}")" || die "unsupported config case: ${current_api_type}"

    data="$(mysql_exec "
        SELECT throughput
        FROM ${result_table}
        WHERE commit_date_time < $(sql_quote "${commit_date_time}")
        AND ts_type = $(sql_quote "${current_ts_type}")
        AND config_name = $(sql_quote "${config_name}")
        AND config_value = $(sql_quote "${config_value}")
        AND protocol = $(sql_quote "${protocol_code}")
        AND throughput > 0
        ORDER BY commit_date_time DESC
        LIMIT 100
    ")" || {
        log "monitor: failed to fetch config_insert history"
        return 0
    }

    data_count="$(printf '%s\n' "${data}" | awk 'NF { count++ } END { print count + 0 }')"
    if [ "${data_count}" -lt 20 ]; then
        log "monitor: config_insert history is not enough (${data_count} rows), skip"
        return 0
    fi

    mean="$(printf '%s\n' "${data}" | awk '
        NF {sum+=$1; sumsq+=$1*$1; count++}
        END {if(count>0) printf "%.10f\n", sum/count; else print 0}
    ')"

    std="$(printf '%s\n' "${data}" | awk '
        NF {sum+=$1; sumsq+=$1*$1; count++}
        END {
            if(count>0) {
                var = sumsq/count - (sum/count)^2
                if(var < 0) var = 0
                printf "%.10f\n", sqrt(var)
            } else {
                print 0
            }
        }
    ')"

    mean="$(normalize_decimal "${mean}")"
    std="$(normalize_decimal "${std}")"
    ucl="$(awk -v mean="${mean}" -v std="${std}" 'BEGIN { printf "%.10f\n", mean + 3 * std }')"
    lcl="$(awk -v mean="${mean}" -v std="${std}" 'BEGIN { value = mean - 3 * std; if (value < 0) value = 0; printf "%.10f\n", value }')"
    ucl="$(normalize_decimal "${ucl}")"
    lcl="$(normalize_decimal "${lcl}")"

    log "monitor: config_insert throughput ${throughput}, limit [${lcl}, ${ucl}] (${config_name}=${config_value}, protocol=${protocol_code})"
    if awk -v throughput="${throughput}" -v ucl="${ucl}" 'BEGIN { exit !((throughput + 0) > (ucl + 0)) }' || \
       awk -v throughput="${throughput}" -v lcl="${lcl}" 'BEGIN { exit !((throughput + 0) < (lcl + 0) && (lcl + 0) > 0) }'; then
        log "monitor alert: config_insert throughput ${throughput} is outside [${lcl}, ${ucl}]"
        sendMsg 1 "${throughput}" "${ucl}" "${lcl}" "${mean}"
        return 1
    fi

    log "monitor: config_insert throughput ${throughput} is inside [${lcl}, ${ucl}]"
    return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/insert_common.sh
source "${SCRIPT_DIR}/insert_common.sh"

main "$@"
