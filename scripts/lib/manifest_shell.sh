#!/usr/bin/env bash
#
# manifest_shell.sh — Source app_manifest.py shell-export into the current shell.
#
set -euo pipefail

_MANIFEST_SHELL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source_app_manifest_exports() {
    local manifest_path="$1"
    [[ -f "${manifest_path}" ]] || {
        echo "[ERROR] App manifest not found: ${manifest_path}" >&2
        return 1
    }
    # shellcheck disable=SC1090
    eval "$(python3 "${_MANIFEST_SHELL_LIB}/app_manifest.py" shell-export "${manifest_path}")"
}

resolve_app_manifest_path() {
    local explicit="${1:-}"
    if [[ -n "${explicit}" && -f "${explicit}" ]]; then
        echo "${explicit}"
        return 0
    fi
    local resolved
    resolved="$(python3 "${_MANIFEST_SHELL_LIB}/app_manifest.py" resolve 2>/dev/null || true)"
    if [[ -n "${resolved}" && -f "${resolved}" ]]; then
        echo "${resolved}"
        return 0
    fi
    return 1
}
