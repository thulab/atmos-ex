#!/usr/bin/env bash

# 功能：从 git.properties 读取缩写提交号
git_properties_commit() {
    awk -F= '/git.commit.id.abbrev/ {print $2; exit}' "$1" 2>/dev/null
}

# 功能：读取指定仓库当前提交号
git_current_commit() {
    git -C "$1" log --pretty=format:%h -1
}

# 功能：读取指定仓库提交时间并格式化为任务时间
git_current_commit_time() {
    local repository="$1"
    local epoch=""
    epoch="$(git -C "${repository}" show -s --format=%ct HEAD)" || return 1
    date -d "@${epoch}" +%Y%m%d%H%M%S
}

# 功能：在超时保护下同步指定 Git 分支
git_sync_branch() {
    local repository="$1"
    local branch="${2:-master}"
    local timeout_seconds="${3:-100}"

    [ -d "${repository}/.git" ] || die "invalid git repository: ${repository}"
    timeout "${timeout_seconds}s" git -C "${repository}" fetch --all || return 1
    git -C "${repository}" reset --hard "origin/${branch}" || return 1
    timeout "${timeout_seconds}s" git -C "${repository}" pull --ff-only
}

# 功能：在超时保护下执行仓库快进拉取
git_pull_repository() {
    local repository="$1"
    local timeout_seconds="${2:-100}"
    [ -d "${repository}/.git" ] || die "invalid git repository: ${repository}"
    timeout "${timeout_seconds}s" git -C "${repository}" pull --ff-only
}
