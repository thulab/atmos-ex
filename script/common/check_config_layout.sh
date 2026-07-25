#!/usr/bin/env bash

set -u
set -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
error_count=0

report_error() {
    printf 'config layout error: %s\n' "$*" >&2
    error_count=$((error_count + 1))
}

while IFS= read -r config_file; do
    case "${config_file}" in
        */benchmark/cases/*.properties) ;;
        *) report_error "Benchmark case is outside benchmark/cases or lacks .properties: ${config_file}" ;;
    esac
done < <(find "${repo_root}/conf" -type f \( -path '*/benchmark/*' -o -name 'config.properties' \) | sort)

while IFS= read -r config_file; do
    if [[ "${config_file}" =~ /[0-9]{1,3}(\.[0-9]{1,3}){3}(/|$) ]]; then
        report_error "IP address must not be part of a config path: ${config_file}"
    fi
done < <(find "${repo_root}/conf" -type f | sort)

mapfile -d '' properties_files < <(find "${repo_root}/conf" -type f -name '*.properties' -print0)
if [ "${#properties_files[@]}" -gt 0 ]; then
    while IFS= read -r duplicate; do
        [ -z "${duplicate}" ] || report_error "duplicate properties key: ${duplicate}"
    done < <(awk '
        FNR == 1 { delete seen }
        /^[[:space:]]*[#!]/ || !/=/{ next }
        {
            key = $0
            sub(/^[[:space:]]*/, "", key)
            sub(/[[:space:]]*=.*/, "", key)
            if (seen[key]++) print FILENAME ":" key
        }
    ' "${properties_files[@]}")
fi

if grep -R -n --include='*.sh' --exclude='check_config_layout.sh' 'mv_config_file' "${repo_root}/script" >/dev/null; then
    report_error 'obsolete mv_config_file reference exists under script/'
fi

if [ "${error_count}" -ne 0 ]; then
    printf 'config layout check failed with %s error(s)\n' "${error_count}" >&2
    exit 1
fi

printf 'config layout check passed\n'
