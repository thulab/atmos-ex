#!/usr/bin/env bash

remote_target() {
    local host="$1"
    printf '%s@%s' "${REMOTE_ACCOUNT:-${ACCOUNT:?ACCOUNT is required}}" "${host}"
}

remote_path_is_safe() {
    local path="$1"
    [ -n "${path}" ] || return 1
    case "${path}" in
        /|/data|/nasdata|/root|/home) return 1 ;;
        "${TEST_INIT_PATH}"/*|"${INIT_PATH}"/*|"${BACKUP_PATH}"/*) return 0 ;;
        *) return 1 ;;
    esac
}

remote_safe_rm() {
    local host="$1"
    local path="$2"
    local quoted_path=""
    remote_path_is_safe "${path}" || die "refuse to remove unexpected remote path: ${host}:${path}"
    printf -v quoted_path '%q' "${path}"
    ssh "$(remote_target "${host}")" "rm -rf -- ${quoted_path}"
}

remote_copy() {
    local source="$1"
    local host="$2"
    local destination="$3"
    scp -r -- "${source}" "$(remote_target "${host}"):${destination}"
}
