#!/usr/bin/env bash

prepare_benchmark_runtime() {
    safe_rm "${BM_PATH}/logs"
    safe_rm "${BM_PATH}/data"
}

start_benchmark() {
    prepare_benchmark_runtime
    (
        cd "${BM_PATH}" || exit 1
        ./benchmark.sh >/dev/null 2>&1 &
    )
}

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
