#!/usr/bin/env bash
# 场景名称：se query test
# 测试目的：执行单机版 IoTDB 查询功能测试。
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

readonly TEST_IP="11.101.17.141"
readonly TEST_TYPE="se_query_test"
readonly QUERY_DATA_TYPE="sequence"
readonly -a QUERY_TS_LIST=(tablemode tempaligned)
readonly QUERY_CREATE_QA_USER=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/common/query_common.sh
source "${SCRIPT_DIR}/../common/query_common.sh"

main "$@"
