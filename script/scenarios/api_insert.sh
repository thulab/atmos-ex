#!/usr/bin/env bash
# 场景名称：api insert
# 测试目的：验证 Java API 的 IoTDB 写入能力。
# 具体步骤：
# 步骤一：准备测试所需的 IoTDB 环境、配置和数据。
# 步骤二：部署并启动目标 IoTDB 服务及相关测试工具。
# 步骤三：调用当前场景实现执行指定测试负载。
# 步骤四：监控测试过程并收集运行状态和结果数据。
# 步骤五：保存测试结果、更新任务状态并清理测试现场。
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
if shopt -oq posix; then
    exec bash "${BASH_SOURCE[0]}" "$@"
fi

set -u
set -o pipefail

readonly TEST_IP="11.101.17.225"
readonly TEST_TYPE="api_insert"
readonly -a TS_LIST=(tempaligned)
readonly -a API_LIST=(
    SESSION_BY_TABLET_TABLE
    SESSION_BY_TABLET
    SESSION_BY_RECORDS
    SESSION_BY_RECORD
    JDBC
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/common/insert_common.sh
source "${SCRIPT_DIR}/../common/insert_common.sh"

main "$@"
