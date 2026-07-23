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

# 功能：构造并写入当前场景的结果记录
insert_records_config_path() {
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

    printf '%s/%s/%s\n' "${ATMOS_PATH}/conf/${TEST_TYPE}" "${base_ts_type}" "${insert_mode}"
}

# 功能：选择并安装当前用例对应的配置文件
mv_config_file() {
    local current_ts_type="$2"
    local current_api_type="$3"
    local config_source=""
    local config_target="${BM_PATH}/conf/config.properties"

    [ "${current_api_type}" = "SESSION_BY_RECORDS" ] || die "unsupported insert_records api type: ${current_api_type}"
    config_source="$(insert_records_config_path "${current_ts_type}")" || die "unsupported insert_records ts type: ${current_ts_type}"

    [ -f "${config_source}" ] || die "missing benchmark config file: ${config_source}"
    safe_rm "${config_target}"
    cp -rf -- "${config_source}" "${config_target}"
}

# 功能：归档测试日志、配置、数据或结果文件
backup_test_data() {
    local protocol_code="$1"
    local current_ts_type="$2"
    local current_api_type="$3"
    local backup_parent="${BACKUP_PATH}/${current_ts_type}"
    local backup_dir="${backup_parent}/${commit_date_time}_${commit_id}_${protocol_code}"

    [ "${current_api_type}" = "SESSION_BY_RECORDS" ] || die "unsupported insert_records api type: ${current_api_type}"

    sudo_safe_rm "${backup_dir}"
    path_is_safe "${backup_parent}" || die "refuse unexpected backup path: ${backup_parent}"
    sudo mkdir -p -- "${backup_parent}"
    path_is_safe "${backup_dir}" || die "refuse unexpected backup path: ${backup_dir}"
    sudo mkdir -p -- "${backup_dir}"

    sudo_safe_rm "${TEST_IOTDB_PATH}/data"
    path_is_safe "${TEST_IOTDB_PATH}" || die "refuse unexpected IoTDB path: ${TEST_IOTDB_PATH}"
    sudo mv "${TEST_IOTDB_PATH}" "${backup_dir}"
    if [ -d "${BM_PATH}/data/csvOutput" ]; then
        sudo cp -rf -- "${BM_PATH}/data/csvOutput" "${backup_dir}"
    fi
}

main "$@"
