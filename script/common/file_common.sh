#!/usr/bin/env bash

# 功能：计算指定目录大小并转换为 GiB
dir_size_gb() {
    local target_dir="$1"

    if [ ! -d "${target_dir}" ]; then
        printf '0\n'
    else
        du -sk "${target_dir}" 2>/dev/null | awk '{printf "%.2f\n", $1 / 1048576}'
    fi
}

# 功能：按可选文件名模式统计指定目录下的 TsFile 数量
count_tsfiles() {
    local target_dir="$1"
    local name_pattern="${2:-*.tsfile}"

    if [ ! -d "${target_dir}" ]; then
        printf '0\n'
    else
        find "${target_dir}" -name "${name_pattern}" | wc -l | tr -d '[:space:]'
    fi
}

# 功能：删除超过指定保留天数的历史目录
clear_expired_directories() {
    local root_dir="$1"
    local retention_days="${2:-7}"
    [ -d "${root_dir}" ] || return 0
    find "${root_dir}" -mindepth 1 -type d -mtime "+${retention_days}" -exec rm -rf -- {} +
}
