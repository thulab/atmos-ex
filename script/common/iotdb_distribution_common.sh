#!/usr/bin/env bash

# 功能：从提交仓库准备当前待测 IoTDB 安装目录
prepare_iotdb_distribution() {
    local source_path="${REPOS_PATH}/${commit_id}/apache-iotdb"
    [ -d "${source_path}" ] || die "missing tested IoTDB path: ${source_path}"
    safe_rm "${TEST_IOTDB_PATH}"
    mkdir -p "${TEST_IOTDB_PATH}/activation"
    cp -rf -- "${source_path}/." "${TEST_IOTDB_PATH}/"
    copy_if_exists "${ATMOS_PATH}/conf/${TEST_TYPE}/license" "${TEST_IOTDB_PATH}/activation/" "license"
    if [ "${COPY_IOTDB_ENV:-0}" = "1" ]; then
        copy_if_exists "${ATMOS_PATH}/conf/${TEST_TYPE}/env" "${TEST_IOTDB_PATH}/.env" "env"
    fi
    if declare -F after_prepare_iotdb_distribution >/dev/null 2>&1; then
        after_prepare_iotdb_distribution
    fi
}

# 功能：准备当前测试所需的 IoTDB 安装环境
set_env() {
    prepare_iotdb_distribution
}
