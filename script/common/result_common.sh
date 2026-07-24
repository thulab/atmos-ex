#!/usr/bin/env bash

# 功能：执行结果数据库访问操作
mysql_exec() {
    local sql="$1"
    MYSQL_PWD="${MYSQL_PASSWORD}" mysql -N -B \
        -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USERNAME}" \
        "${DBNAME}" -e "${sql}"
}

# 功能：处理或执行 SQL 相关值和命令
sql_quote() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="$(printf '%s' "${value}" | sed "s/'/''/g")"
    printf "'%s'" "${value}"
}

# 功能：更新当前提交在任务表中的测试状态
update_task_status() {
    local status="$1"
    mysql_exec "update ${TASK_TABLENAME} set ${TEST_TYPE} = $(sql_quote "${status}") where commit_id = $(sql_quote "${commit_id}")"
}

# 功能：更新当前任务或测试的状态标记
mark_older_commits_skip() {
    local author_filter="${TASK_AUTHOR_FILTER_SQL:-}"
    local extra_filter=""

    [ -z "${author_filter}" ] || extra_filter=" and ${author_filter}"
    mysql_exec "update ${TASK_TABLENAME} set ${TEST_TYPE} = 'skip' where ${TEST_TYPE} is NULL${extra_filter} and commit_date_time < $(sql_quote "${commit_date_time}")"
}

# 功能：查询并返回当前场景需要的数据或状态
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

# 功能：优先获取重测任务，否则获取最新待测试提交
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

# 功能：领取下一个任务并立即标记为执行中
claim_next_task() {
    fetch_next_commit || return 1
    update_task_status "ontesting"
}

# 功能：完成当前任务并按配置跳过更旧提交
finish_task_success() {
    update_task_status "done"
    [ "${TASK_SKIP_OLDER_COMMITS:-1}" -eq 0 ] || mark_older_commits_skip
}

# 功能：将当前任务标记为失败状态
finish_task_failure() {
    update_task_status "${1:-${TASK_FAILURE_STATUS:-RError}}"
}

# 功能：执行一次领取、运行和状态收尾流程
run_task_lifecycle() {
    local task_function="$1"
    shift

    claim_next_task || return 2
    if "${task_function}" "$@"; then
        finish_task_success
        return 0
    fi
    finish_task_failure
    return 1
}

# 功能：持续领取并执行任务，无任务时按配置间隔轮询
run_task_loop() {
    local task_function="$1"
    local poll_seconds="${TASK_POLL_INTERVAL_SECONDS:-60}"
    shift

    while true; do
        run_task_lifecycle "${task_function}" "$@"
        case "$?" in
            0|1) [ "${TASK_RUN_ONCE:-0}" -eq 0 ] || return ;;
            2) [ "${TASK_RUN_ONCE:-0}" -eq 0 ] || return 2 ;;
        esac
        sleep "${poll_seconds}"
    done
}
