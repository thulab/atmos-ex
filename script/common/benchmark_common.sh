#!/usr/bin/env bash

# 功能：准备当前步骤所需的目录、配置或测试数据
prepare_benchmark_runtime() {
    safe_rm "${BM_PATH}/logs"
    safe_rm "${BM_PATH}/data"
}

# 功能：清理运行目录并启动 IoT-Benchmark
start_benchmark() {
    prepare_benchmark_runtime
    (
        cd "${BM_PATH}" || exit 1
        ./benchmark.sh >/dev/null 2>&1 &
    )
}

# 功能：定位 Benchmark 生成的结果 CSV 文件
find_result_csv() {
    local output_dir="${1:-${BM_PATH}/data/csvOutput}"
    local had_nullglob=0
    local files=()

    if shopt -q nullglob; then
        had_nullglob=1
    else
        shopt -s nullglob
    fi
    files=("${output_dir}/"*result.csv)
    if [ "${had_nullglob}" -eq 0 ]; then
        shopt -u nullglob
    fi
    [ "${#files[@]}" -eq 0 ] || printf '%s\n' "${files[0]}"
}

# 功能：同步指定 IoT-Benchmark 安装目录到仓库版本
sync_benchmark_distribution() {
    local source_path="${1:-${BM_REPOS_PATH:-/nasdata/repository/iot-benchmark}}"
    local target_path="${2:-${BM_PATH}}"
    local source_version=""
    local target_version=""

    [ -f "${source_path}/git.properties" ] || {
        log "skip benchmark sync, missing ${source_path}/git.properties"
        return 0
    }
    source_version="$(git_properties_commit "${source_path}/git.properties")"
    target_version="$(git_properties_commit "${target_path}/git.properties")"
    [ -n "${source_version}" ] || return 0
    if [ ! -d "${target_path}" ] || [ "${source_version}" != "${target_version}" ]; then
        log "sync benchmark ${target_version:-missing} -> ${source_version}: ${target_path}"
        safe_rm "${target_path}"
        cp -rf -- "${source_path}" "${target_path}"
    fi
}

# 功能：轮询 Benchmark 结果，超时时调用可选回调
wait_for_benchmark_result() {
    local timeout_seconds="${1:-${MONITOR_TIMEOUT_SECONDS:-7200}}"
    local interval_seconds="${2:-${MONITOR_POLL_INTERVAL_SECONDS:-10}}"
    local timeout_callback="${3:-}"
    local start_epoch="${4:-$(date +%s)}"
    local csv_file=""

    while true; do
        declare -F refresh_max_process_metrics >/dev/null 2>&1 && refresh_max_process_metrics
        csv_file="$(find_result_csv || true)"
        if [ -n "${csv_file}" ]; then
            BENCHMARK_RESULT_CSV="${csv_file}"
            end_time="$(current_datetime)"
            return 0
        fi
        if [ $(( $(date +%s) - start_epoch )) -ge "${timeout_seconds}" ]; then
            end_time="$(current_datetime)"
            [ -z "${timeout_callback}" ] || "${timeout_callback}"
            return 1
        fi
        sleep "${interval_seconds}"
    done
}

# 功能：安装配置、启动 Benchmark 并等待结果
run_benchmark_lifecycle() {
    local config_file="$1"
    local timeout_callback="${2:-}"
    local warmup_seconds="${3:-${BENCHMARK_WARMUP_SECONDS:-0}}"
    local parser_callback="${4:-}"
    local result_callback="${5:-}"

    install_benchmark_config "${config_file}"
    start_benchmark
    start_time="$(current_datetime)"
    begin_monitor_window
    [ "${warmup_seconds}" -le 0 ] || sleep "${warmup_seconds}"
    wait_for_benchmark_result \
        "${MONITOR_TIMEOUT_SECONDS:-7200}" \
        "${MONITOR_POLL_INTERVAL_SECONDS:-10}" \
        "${timeout_callback}" "${m_start_time}" || return 1
    [ -z "${parser_callback}" ] || "${parser_callback}" "${BENCHMARK_RESULT_CSV}"
    [ -z "${result_callback}" ] || "${result_callback}" "${BENCHMARK_RESULT_CSV}"
}

# 功能：同步使用标准目录布局的 IoT-Benchmark
check_standard_benchmark_version() {
    sync_benchmark_distribution "${BM_REPOS_PATH:-/nasdata/repository/iot-benchmark}" "${BM_PATH}"
}

# 功能：为标准 Benchmark 超时场景生成失败占位 CSV
create_standard_stuck_result_csv() {
    local result_label="${1:-${BENCHMARK_DEFAULT_RESULT_LABEL:-INGESTION}}"
    local csv_file="${BM_PATH}/data/csvOutput/Stuck_result.csv"
    local index=0

    result_label="${result_label%,}"
    mkdir -p "${csv_file%/*}"
    : > "${csv_file}"
    for ((index = 0; index < 100; index++)); do
        printf '%s\n' "${result_label}, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1" >> "${csv_file}"
    done
}

# 功能：将标准 Benchmark 指标统一设置为失败值
set_standard_negative_benchmark_metrics() {
    local value="$1"
    okPoint="${value}"; okOperation="${value}"
    failPoint="${value}"; failOperation="${value}"
    throughput="${value}"; Latency="${value}"
    MIN="${value}"; P10="${value}"; P25="${value}"; MEDIAN="${value}"
    P75="${value}"; P90="${value}"; P95="${value}"; P99="${value}"
    P999="${value}"; MAX="${value}"
}

# 功能：解析标准 Benchmark 吞吐量和延迟指标
parse_standard_benchmark_result() {
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

    [ -n "${throughput_line}" ] && [ -n "${latency_line}" ] || return 1
    IFS=$'\t' read -r okOperation okPoint failOperation failPoint throughput <<< "${throughput_line}"
    IFS=$'\t' read -r Latency MIN P10 P25 MEDIAN P75 P90 P95 P99 P999 MAX <<< "${latency_line}"
}
