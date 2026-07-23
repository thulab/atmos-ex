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

# 功能：创建并清空单轮测试归档目录
prepare_archive_directory() {
    local archive_dir="$1"
    path_is_safe "${archive_dir}" || die "unsafe archive path: ${archive_dir}"
    sudo rm -rf -- "${archive_dir}"
    sudo mkdir -p "${archive_dir}"
}

# 功能：将存在的文件或目录复制到归档目录
archive_if_exists() {
    local source_path="$1"
    local archive_dir="$2"
    [ -e "${source_path}" ] || return 0
    sudo cp -rf -- "${source_path}" "${archive_dir}/"
}

# 功能：归档 Benchmark CSV、日志和配置
archive_benchmark_runtime() {
    local benchmark_path="$1"
    local archive_dir="$2"
    archive_if_exists "${benchmark_path}/data/csvOutput" "${archive_dir}"
    archive_if_exists "${benchmark_path}/logs" "${archive_dir}"
    archive_if_exists "${benchmark_path}/conf/config.properties" "${archive_dir}"
}

# 功能：统计指定模式的文件数量
count_files_by_pattern() {
    local root_path="$1"
    local pattern="$2"
    [ -d "${root_path}" ] || { printf '0\n'; return; }
    find "${root_path}" -type f -name "${pattern}" | wc -l
}

# 功能：统计指定层级的 TsFile 数量
count_tsfiles_by_level() {
    local root_path="$1"
    local level="$2"
    [ -d "${root_path}" ] || { printf '0\n'; return; }
    find "${root_path}" -type f -name "*.tsfile" -path "*/${level}/*" | wc -l
}
