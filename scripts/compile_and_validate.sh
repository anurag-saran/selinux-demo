#!/usr/bin/env bash
#
# compile_and_validate.sh — CI gate: syntax-check and build .pp from selinux/ or policy_out/
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
POLICY_DIR="${1:-${PROJECT_ROOT}/selinux}"
MODULE_NAME="${POLICY_MODULE:-myapp}"
DOMAIN="${SELINUX_DOMAIN:-myapp_t}"

# shellcheck source=lib/compile_policy.sh
source "${SCRIPT_DIR}/lib/compile_policy.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

te="${POLICY_DIR}/${MODULE_NAME}.te"
fc="${POLICY_DIR}/${MODULE_NAME}.fc"
pp="${POLICY_DIR}/${MODULE_NAME}.pp"

if [[ ! -f "${te}" ]] || [[ ! -f "${fc}" ]]; then
    log_error "Missing ${te} or ${fc}"
    exit 1
fi

bash "${SCRIPT_DIR}/validate_forbidden_patterns.sh" "${POLICY_DIR}"

if ! has_selinux_devel && command -v podman >/dev/null 2>&1; then
    ensure_selinux_build_image || true
fi

log_info "Static checks on ${te}"
log_info "Compiling ${MODULE_NAME} in ${POLICY_DIR} via refpolicy Makefile"
compile_policy_module "${POLICY_DIR}" "${MODULE_NAME}" "${pp}"
log_info "Built ${pp}"
log_info "Validation passed for ${MODULE_NAME} (domain ${DOMAIN})"
