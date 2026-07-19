#!/usr/bin/env bash

setup_platform_env() {
    case "${TEST_PLATFORM:-linux}" in
        linux) setup_env_linux "$@" ;;
        windows) setup_env_windows "$@" ;;
        *) die "unsupported TEST_PLATFORM: ${TEST_PLATFORM}" ;;
    esac
}
