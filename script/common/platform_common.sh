#!/usr/bin/env bash

# 功能：部署并初始化当前测试运行环境
setup_platform_env() {
    case "${TEST_PLATFORM:-linux}" in
        linux) setup_env_linux "$@" ;;
        windows) setup_env_windows "$@" ;;
        *) die "unsupported TEST_PLATFORM: ${TEST_PLATFORM}" ;;
    esac
}
