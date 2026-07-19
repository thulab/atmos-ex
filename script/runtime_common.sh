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

mysql_exec() {
    local sql="$1"
    MYSQL_PWD="${MYSQL_PASSWORD}" mysql -N -B \
        -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USERNAME}" \
        "${DBNAME}" -e "${sql}"
}

sql_quote() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="$(printf '%s' "${value}" | sed "s/'/''/g")"
    printf "'%s'" "${value}"
}

update_task_status() {
    local status="$1"
    mysql_exec "update ${TASK_TABLENAME} set ${TEST_TYPE} = $(sql_quote "${status}") where commit_id = $(sql_quote "${commit_id}")"
}

mark_older_commits_skip() {
    mysql_exec "update ${TASK_TABLENAME} set ${TEST_TYPE} = 'skip' where ${TEST_TYPE} is NULL and commit_date_time < $(sql_quote "${commit_date_time}")"
}

query_next_commit() {
    local status_filter="$1"
    local author_filter="${TASK_AUTHOR_FILTER_SQL:-}"
    local extra_filter=""

    [ -z "${author_filter}" ] || extra_filter=" and ${author_filter}"
    if [ "${status_filter}" = "retest" ]; then
        mysql_exec "SELECT commit_id, author, commit_date_time FROM ${TASK_TABLENAME} WHERE ${TEST_TYPE} = 'retest'${extra_filter} ORDER BY commit_date_time desc LIMIT 1"
    else
        mysql_exec "SELECT commit_id, author, commit_date_time FROM ${TASK_TABLENAME} WHERE ${TEST_TYPE} is NULL${extra_filter} ORDER BY commit_date_time desc LIMIT 1"
    fi
}

fetch_next_commit() {
    local row=""
    local raw_commit_date_time=""

    row="$(query_next_commit retest)"
    [ -n "${row}" ] || row="$(query_next_commit pending)"
    [ -n "${row}" ] || return 1

    IFS=$'\t' read -r commit_id author raw_commit_date_time <<< "${row}"
    author="$(trim "${author}")"
    commit_date_time="$(normalize_datetime "${raw_commit_date_time}")"
    [ -n "${commit_id}" ] && [ -n "${commit_date_time}" ]
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

check_pid_and_kill() {
    local process_name="$1"
    local description="${2:-$1}"
    local pid=""
    local pids=""

    pids="$(jps | awk -v name="${process_name}" '$2 == name {print $1}')"
    if [ -z "${pids}" ]; then
        log "no ${description} process found"
        return 0
    fi

    while IFS= read -r pid; do
        [ -n "${pid}" ] || continue
        kill -TERM "${pid}" 2>/dev/null || true
    done <<< "${pids}"
    sleep "${PROCESS_STOP_WAIT_SECONDS:-2}"
    while IFS= read -r pid; do
        [ -n "${pid}" ] || continue
        kill -KILL "${pid}" 2>/dev/null || true
    done <<< "${pids}"
    log "${description} stopped"
}

mark_test_in_progress() {
    printf 'ontesting\n' > "${INIT_PATH}/test_type_file"
}

restore_test_type_file() {
    printf '%s\n' "${TEST_TYPE}" > "${INIT_PATH}/test_type_file"
}
