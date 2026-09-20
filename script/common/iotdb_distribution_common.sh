#!/usr/bin/env bash

# 功能：从提交仓库准备当前待测 IoTDB 安装目录
prepare_iotdb_distribution() {
    local source_path="${REPOS_PATH}/${commit_id}/apache-iotdb"

    if ! validate_iotdb_distribution_layout "${source_path}"; then
        mark_environment_deployment_error "environment deployment check failed for ${source_path}"
        return 1
    fi

    safe_rm "${TEST_IOTDB_PATH}"
    if ! copy_iotdb_distribution "${source_path}" "${TEST_IOTDB_PATH}"; then
        return 1
    fi
    mkdir -p "${TEST_IOTDB_PATH}/activation"
    install_iotdb_runtime_config "${COPY_IOTDB_ENV:-0}"
    if declare -F after_prepare_iotdb_distribution >/dev/null 2>&1; then
        after_prepare_iotdb_distribution
    fi
}

# 功能：准备当前测试所需的 IoTDB 安装环境
set_env() {
    prepare_iotdb_distribution
}
