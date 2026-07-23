#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    printf '[ERROR] runtime_common.sh requires bash\n' >&2
    return 1 2>/dev/null || exit 1
fi

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

trim() {
    local value="${1:-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

current_datetime() {
    date '+%Y-%m-%d %H:%M:%S'
}

datetime_to_epoch() {
    date -d "$1" +%s
}

normalize_datetime() {
    printf '%s' "$1" | tr -cd '0-9'
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

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

check_password() {
    [ -n "${MYSQL_PASSWORD:-}" ] || die "ATMOS_DB_PASSWORD is required"
}


git_commit_abbrev() {
    awk -F= '/git.commit.id.abbrev/ {print $2; exit}' "$1" 2>/dev/null
}

path_is_safe() {
    local path="$1"

    [ -n "${path}" ] || return 1
    case "${path}" in
        /|/data|/nasdata|/root|.) return 1 ;;
        "${INIT_PATH}"/*|"${TEST_INIT_PATH}"/*|"${BACKUP_PATH}"/*) return 0 ;;
        *) return 1 ;;
    esac
}

safe_rm() {
    local path="$1"
    [ -e "${path}" ] || return 0
    path_is_safe "${path}" || die "refuse to remove unexpected path: ${path}"
    rm -rf -- "${path}"
}

sudo_safe_rm() {
    local path="$1"
    [ -e "${path}" ] || return 0
    path_is_safe "${path}" || die "refuse to remove unexpected path: ${path}"
    sudo rm -rf -- "${path}"
}

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

mark_test_in_progress() {
    printf 'ontesting\n' > "${INIT_PATH}/test_type_file"
}

readonly RUNTIME_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${RUNTIME_COMMON_DIR}/process_common.sh"
source "${RUNTIME_COMMON_DIR}/result_common.sh"

restore_test_type_file() {
    printf '%s\n' "${TEST_TYPE}" > "${INIT_PATH}/test_type_file"
}
