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
