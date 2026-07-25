#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
if shopt -oq posix; then
    exec bash "${BASH_SOURCE[0]}" "$@"
fi

set -u
set -o pipefail

readonly TEST_IP="11.101.17.153"
readonly TEST_TYPE="insert_records"
readonly -a PROTOCOL_LIST=(223)
readonly -a TS_LIST=(
    common_seq_w
    common_unseq_w
    aligned_seq_w
    aligned_unseq_w
    tempaligned_seq_w
    tempaligned_unseq_w
)
readonly -a API_LIST=(SESSION_BY_RECORDS)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/common/insert_common.sh
source "${SCRIPT_DIR}/../common/insert_common.sh"

# 功能：拆分 Insert Records 场景的模型和数据模式
split_insert_records_type() {
    local current_ts_type="$1"
    local base_ts_type=""
    local insert_mode=""

    case "${current_ts_type}" in
        *_seq_w)
            base_ts_type="${current_ts_type%_seq_w}"
            insert_mode="seq_w"
            ;;
        *_unseq_w)
            base_ts_type="${current_ts_type%_unseq_w}"
            insert_mode="unseq_w"
            ;;
        *)
            return 1
            ;;
    esac

    printf '%s %s\n' "${base_ts_type}" "${insert_mode}"
}

# 功能：生成 Insert Records 场景 Benchmark 配置的统一 case 标识
insert_benchmark_case_id() {
    local current_ts_type="$1"
    local current_api_type="$2"
    local base_ts_type=""
    local insert_mode=""

    [ "${current_api_type}" = "SESSION_BY_RECORDS" ] || die "unsupported insert_records api type: ${current_api_type}"
    read -r base_ts_type insert_mode < <(split_insert_records_type "${current_ts_type}") || return 1
    config_build_case_id model "${base_ts_type}" data "${insert_mode}"
}

# 功能：归档测试日志、配置、数据或结果文件
backup_test_data() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local current_api_type="$3"
    local case_id=""

    [ "${current_api_type}" = "SESSION_BY_RECORDS" ] || die "unsupported insert_records api type: ${current_api_type}"

    case_id="$(backup_build_case_id protocol "${protocol_code}" model "${current_ts_type}" api "${current_api_type}")"
    backup_standard_case "${case_id}"
}

main "$@"
