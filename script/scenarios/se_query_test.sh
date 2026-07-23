#!/usr/bin/env bash
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
