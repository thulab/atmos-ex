#!/usr/bin/env bash

run_api_test_step() {
    local label="$1"
    local test_function="$2"

    init_items
    log "starting ${label}"
    if "${test_function}"; then
        log "${label} finished"
        return 0
    fi

    log "${label} failed"
    sleep "${API_FAILURE_WAIT_SECONDS:-60}"
    return 1
}

run_api_test_suite() {
    local entry=""
    local label=""
    local test_function=""
    local failed=0

    for entry in "$@"; do
        label="${entry%%:*}"
        test_function="${entry#*:}"
        run_api_test_step "${label}" "${test_function}" || failed=1
    done
    return "${failed}"
}
