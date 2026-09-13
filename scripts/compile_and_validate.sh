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

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

te="${POLICY_DIR}/${MODULE_NAME}.te"
fc="${POLICY_DIR}/${MODULE_NAME}.fc"
pp="${POLICY_DIR}/${MODULE_NAME}.pp"
mod="${POLICY_DIR}/${MODULE_NAME}.mod"

if [[ ! -f "${te}" ]] || [[ ! -f "${fc}" ]]; then
    log_error "Missing ${te} or ${fc}"
    exit 1
fi

bash "${SCRIPT_DIR}/validate_forbidden_patterns.sh" "${POLICY_DIR}"

log_info "Static checks on ${te}"
rm -f "${pp}" "${mod}"
log_info "Compiling ${MODULE_NAME} in ${POLICY_DIR}"

if [[ -f /usr/share/selinux/devel/include/common.inc.sh ]]; then
    checkmodule -M -m -o "${mod}" "${te}"
    semodule_package -o "${pp}" -m "${mod}" -f "${fc}"
elif command -v podman >/dev/null 2>&1; then
    # shellcheck source=lib/vm_ready.sh
    source "${SCRIPT_DIR}/lib/vm_ready.sh"
    ensure_vm_ready || {
        log_error "Podman machine not ready for compile"
        exit 1
    }
    work_dir="$(mktemp -d)"
    cp "${te}" "${fc}" "${work_dir}/"
    podman run --rm \
        -v "${work_dir}:/build:Z" \
        docker.io/library/fedora:41 \
        bash -lc "
            set -euo pipefail
            dnf install -y -q selinux-policy-devel checkpolicy policycoreutils
            make -C /build -f /usr/share/selinux/devel/Makefile ${MODULE_NAME}.pp
        "
    cp "${work_dir}/${MODULE_NAME}.pp" "${pp}"
    rm -rf "${work_dir}"
else
    log_error "Install selinux-policy-devel or podman for compile"
    exit 1
fi

log_info "Built ${pp}"
log_info "Validation passed for ${MODULE_NAME} (domain ${DOMAIN})"
