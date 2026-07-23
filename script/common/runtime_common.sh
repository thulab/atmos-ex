#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    printf '[ERROR] runtime_common.sh requires bash\n' >&2
    return 1 2>/dev/null || exit 1
fi

# 功能：输出带时间戳的运行日志到标准错误
log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

# 功能：记录错误信息并立即终止当前脚本
die() {
    log "ERROR: $*"
    exit 1
}

# 功能：移除字符串首尾的空白字符
trim() {
    local value="${1:-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

# 功能：返回当前本地日期时间字符串
current_datetime() {
    date '+%Y-%m-%d %H:%M:%S'
}

# 功能：将日期时间字符串转换为 Unix 时间戳
datetime_to_epoch() {
    date -d "$1" +%s
}

# 功能：规范化输入值以便后续比较或存储
normalize_datetime() {
    printf '%s' "$1" | tr -cd '0-9'
}

# 功能：检查指定外部命令是否存在，不存在时终止运行
require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

# 功能：确保当前测试依赖的资源或结果存在
ensure_runtime_dependencies() {
    local command_name=""
    local -a required_commands=(
        awk bc cat cp curl cut date du find findmnt grep hostname jps jq kill
        lsof lsblk mkdir mv mysql ps readlink rm scp sed sleep ssh sudo tail
        touch tr wc
    )

    for command_name in "${required_commands[@]}"; do
        require_command "${command_name}"
    done
}

# 功能：检查当前场景的前置条件、进程状态或结果有效性
check_password() {
    [ -n "${MYSQL_PASSWORD:-}" ] || die "ATMOS_DB_PASSWORD is required"
}


# 功能：从 git.properties 中读取缩写提交号
git_commit_abbrev() {
    awk -F= '/git.commit.id.abbrev/ {print $2; exit}' "$1" 2>/dev/null
}

# 功能：判断目标路径是否位于允许操作的工作目录内
path_is_safe() {
    local path="$1"

    [ -n "${path}" ] || return 1
    case "${path}" in
        /|/data|/nasdata|/root|.) return 1 ;;
        "${INIT_PATH}"/*|"${TEST_INIT_PATH}"/*|"${BACKUP_PATH}"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# 功能：校验路径后递归删除普通用户可操作的目录
safe_rm() {
    local path="$1"
    [ -e "${path}" ] || return 0
    path_is_safe "${path}" || die "refuse to remove unexpected path: ${path}"
    rm -rf -- "${path}"
}

# 功能：校验路径后使用 sudo 递归删除目录
sudo_safe_rm() {
    local path="$1"
    [ -e "${path}" ] || return 0
    path_is_safe "${path}" || die "refuse to remove unexpected path: ${path}"
    sudo rm -rf -- "${path}"
}

# 功能：复制当前测试所需的配置、数据或运行文件
copy_if_exists() {
    local source="$1"
    local target="$2"
    local label="${3:-$1}"

    if [ ! -e "${source}" ]; then
        log "skip copy, missing ${label}: ${source}"
        return 0
    fi
    cp -rf -- "${source}" "${target}"
}

# 功能：设置当前测试使用的配置值或运行状态
set_iotdb_property() {
    local properties_file=""
    local property_name=""
    local property_value=""
    local temp_file=""

    if [ "$#" -eq 2 ]; then
        properties_file="${TEST_IOTDB_PATH}/conf/iotdb-system.properties"
        property_name="$1"
        property_value="$2"
    elif [ "$#" -eq 3 ]; then
        properties_file="$1"
        property_name="$2"
        property_value="$3"
    else
        die "set_iotdb_property expects KEY VALUE or FILE KEY VALUE"
    fi

    [ -f "${properties_file}" ] || die "missing properties file: ${properties_file}"
    temp_file="${properties_file}.tmp.$$"
    awk -F= -v key="${property_name}" -v value="${property_value}" '
        BEGIN { updated = 0 }
        $1 == key {
            if (!updated) {
                print key "=" value
                updated = 1
            }
            next
        }
        { print }
        END { if (!updated) print key "=" value }
    ' "${properties_file}" > "${temp_file}" && mv -- "${temp_file}" "${properties_file}"
}

# 功能：更新当前任务或测试的状态标记
mark_test_in_progress() {
    printf 'ontesting\n' > "${INIT_PATH}/test_type_file"
}

readonly RUNTIME_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${RUNTIME_COMMON_DIR}/process_common.sh"
source "${RUNTIME_COMMON_DIR}/result_common.sh"
source "${RUNTIME_COMMON_DIR}/file_common.sh"

# 功能：在脚本退出时恢复测试类型状态文件
restore_test_type_file() {
    printf '%s\n' "${TEST_TYPE}" > "${INIT_PATH}/test_type_file"
}
