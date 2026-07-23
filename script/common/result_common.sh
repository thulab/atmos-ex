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
    mysql_exec "update ${TASK_TABLENAME} set ${TEST_TYPE} = 'skip' where ${TEST_TYPE} is NULL and commit_date_time < $(sql_quote "${commit_date_time}")"
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
