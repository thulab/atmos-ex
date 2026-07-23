#!/usr/bin/env bash

# 功能：比较本地与仓库版本并同步标准 Benchmark 目录
check_benchmark_version() {
    local benchmark_repo="${BM_REPOS_PATH:-/nasdata/repository/iot-benchmark}"
    local source_version=""
    local target_version=""

    source_version="$(git_commit_abbrev "${benchmark_repo}/git.properties")"
    target_version="$(git_commit_abbrev "${BM_PATH}/git.properties")"
    if [ -n "${source_version}" ] && { [ ! -d "${BM_PATH}" ] || [ "${target_version}" != "${source_version}" ]; }; then
        safe_rm "${BM_PATH}"
        cp -rf -- "${benchmark_repo}" "${BM_PATH}"
    fi
}

# 功能：定位标准 Benchmark 输出目录中的首个结果 CSV
find_result_csv() {
    find "${BM_PATH}/data/csvOutput" -type f -name "*result.csv" -print -quit 2>/dev/null
}

# 功能：为标准 Benchmark 超时场景生成失败占位结果
create_stuck_result_csv() {
    local result_label="${1:-${BENCHMARK_DEFAULT_RESULT_LABEL:-INGESTION}}"
    local csv_file="${BM_PATH}/data/csvOutput/Stuck_result.csv"
    local index=0

    result_label="${result_label%,}"
    mkdir -p "${csv_file%/*}"
    : > "${csv_file}"
    for ((index = 0; index < 100; index++)); do
        echo "${result_label}, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1" >> "${csv_file}"
    done
}

# 功能：将标准 Benchmark 指标统一设置为指定失败值
set_negative_benchmark_metrics() {
    local value="$1"
    okPoint="${value}"
    okOperation="${value}"
    failPoint="${value}"
    failOperation="${value}"
    throughput="${value}"
    Latency="${value}"
    MIN="${value}"
    P10="${value}"
    P25="${value}"
    MEDIAN="${value}"
    P75="${value}"
    P90="${value}"
    P95="${value}"
    P99="${value}"
    P999="${value}"
    MAX="${value}"
}

# 功能：解析标准 Benchmark 的吞吐量行和延迟行
parse_benchmark_result() {
    local csv_file="$1"
    local result_label="${2:-${BENCHMARK_DEFAULT_RESULT_LABEL:-INGESTION}}"
    local throughput_line=""
    local latency_line=""

    [ -f "${csv_file}" ] || return 1
    result_label="${result_label%,}"
    throughput_line="$(awk -F, -v label="${result_label}" '
        { name = $1; gsub(/^[ \t]+|[ \t]+$/, "", name) }
        name == label {
            for (i = 2; i <= 6; i++) {
                gsub(/^[ \t]+|[ \t]+$/, "", $i)
                printf "%s%s", $i, (i == 6 ? ORS : OFS)
            }
            exit
        }
    ' OFS=$'\t' "${csv_file}")"
    latency_line="$(awk -F, -v label="${result_label}" '
        { name = $1; gsub(/^[ \t]+|[ \t]+$/, "", name) }
        name == label {
            count++
            if (count == 2) {
                for (i = 2; i <= 12; i++) {
                    gsub(/^[ \t]+|[ \t]+$/, "", $i)
                    printf "%s%s", $i, (i == 12 ? ORS : OFS)
                }
                exit
            }
        }
    ' OFS=$'\t' "${csv_file}")"

    [ -n "${throughput_line}" ] || return 1
    [ -n "${latency_line}" ] || return 1
    IFS=$'\t' read -r okOperation okPoint failOperation failPoint throughput <<< "${throughput_line}"
    IFS=$'\t' read -r Latency MIN P10 P25 MEDIAN P75 P90 P95 P99 P999 MAX <<< "${latency_line}"
}
