#!/usr/bin/env bash

set -u
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0

report_matches() {
    local description="$1"
    local pattern="$2"
    local matches=""

    matches="$(grep -RInE --include='*.sh' "${pattern}" "${SCRIPT_DIR}" || true)"
    if [ -n "${matches}" ]; then
        printf '[ERROR] %s\n%s\n' "${description}" "${matches}" >&2
        status=1
    fi
}

while IFS= read -r -d '' script_file; do
    if [ "$(head -n 1 "${script_file}")" != '#!/usr/bin/env bash' ]; then
        printf '[ERROR] invalid shebang: %s\n' "${script_file}" >&2
        status=1
    fi
    if grep -q $'\r' "${script_file}"; then
        printf '[ERROR] CRLF line ending: %s\n' "${script_file}" >&2
        status=1
    fi
    if ! bash -n "${script_file}"; then
        status=1
    fi
done < <(find "${SCRIPT_DIR}" -type f -name '*.sh' -print0)

report_matches 'do not use the function keyword' '^[[:space:]]*function[[:space:]]+'
report_matches 'do not invoke repository scripts with sh' '(^|[;&][[:space:]]*)sh[[:space:]]+.*script/'
report_matches 'quote destructive paths and pass -- to rm' '^[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+-rf[[:space:]]+[^-" ]'
report_matches 'do not send SIGKILL without a graceful stop attempt' 'kill[[:space:]]+-9'

exit "${status}"
