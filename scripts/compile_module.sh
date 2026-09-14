#!/usr/bin/env bash
#
# compile_module.sh — CLI wrapper for compile_policy_module (Python + CI friendly).
#
# Usage: compile_module.sh POLICY_DIR MODULE_NAME [OUTPUT.pp]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/compile_policy.sh
source "${SCRIPT_DIR}/lib/compile_policy.sh"

POLICY_DIR="${1:?policy dir}"
MODULE_NAME="${2:?module name}"
OUTPUT_PP="${3:-${POLICY_DIR}/${MODULE_NAME}.pp}"

if ! has_selinux_devel; then
    ensure_selinux_build_image || true
fi

compile_policy_module "${POLICY_DIR}" "${MODULE_NAME}" "${OUTPUT_PP}"
