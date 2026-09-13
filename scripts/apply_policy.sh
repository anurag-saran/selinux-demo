#!/usr/bin/env bash
#
# apply_policy.sh
# Compile (if needed) and install an AI-generated policy module on the SELinux host.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/compile_policy.sh
source "${SCRIPT_DIR}/lib/compile_policy.sh"

CANARY_MODE=0
POSITIONAL=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [--canary] [policy_dir]

  --canary   Install policy, keep ${DOMAIN:-myapp_t} permissive, write soak marker
             (production canary path — does NOT enforce)

  default    Install and remove permissive flag (dev/FCOS fallback — NOT for prod soak bypass)

Examples:
  sudo bash scripts/apply_policy.sh --canary policy_out
  sudo bash scripts/apply_policy.sh selinux
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --canary) CANARY_MODE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

POLICY_DIR="${POSITIONAL[0]:-${PROJECT_ROOT}/policy_out}"
MODULE_NAME="${POLICY_MODULE:-myapp}"
DOMAIN="${SELINUX_DOMAIN:-myapp_t}"
INSTALL_ROOT="/opt/myapp"
VAR_DIR="/var/lib/myapp"
RUNTIME_DIR="/run/myapp"
SOAK_MARKER="${VAR_DIR}/selinux_canary_deployed_at"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "Run as root: sudo $0"
        exit 1
    fi
}

restore_contexts() {
    log_info "Restoring contexts on ${INSTALL_ROOT}, ${VAR_DIR}, and ${RUNTIME_DIR}"
    restorecon -Rv "${INSTALL_ROOT}" "${VAR_DIR}" "${RUNTIME_DIR}" 2>/dev/null || true
}

write_soak_marker() {
    mkdir -p "${VAR_DIR}"
    date +%s > "${SOAK_MARKER}"
    log_info "Soak marker written: ${SOAK_MARKER}"
}

set_permissive_domain() {
    if command -v semanage >/dev/null 2>&1; then
        if semanage permissive -l 2>/dev/null | grep -qw "${DOMAIN}"; then
            log_info "Domain ${DOMAIN} already permissive"
        else
            log_info "Setting ${DOMAIN} permissive via semanage"
            semanage permissive -a "${DOMAIN}"
        fi
    else
        log_warn "semanage unavailable; ensure policy declares permissive ${DOMAIN} or use RHEL host"
    fi
}

install_policy() {
    local pp="${POLICY_DIR}/${MODULE_NAME}.pp"
    require_command semodule policycoreutils

    log_info "Installing ${pp}"
    semodule -i "${pp}"

    if [[ "${CANARY_MODE}" -eq 1 ]]; then
        set_permissive_domain
        write_soak_marker
        return 0
    fi

    log_warn "Direct apply without --canary removes permissive and skips soak gate — dev/FCOS only"
    if command -v semanage >/dev/null 2>&1; then
        if semanage permissive -l 2>/dev/null | grep -qw "${DOMAIN}"; then
            log_info "Removing permissive flag from ${DOMAIN}"
            semanage permissive -d "${DOMAIN}" 2>/dev/null || true
        fi
    else
        log_warn "semanage unavailable; ensure generated policy does not declare permissive ${DOMAIN}"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        log_error "Missing command: $1 (dnf install $2)"
        exit 1
    }
}

main() {
    require_root
    require_command semodule policycoreutils
    require_command restorecon policycoreutils

    if [[ ! -d "${POLICY_DIR}" ]]; then
        log_error "Policy directory not found: ${POLICY_DIR}"
        exit 1
    fi

    compile_policy_module "${POLICY_DIR}" "${MODULE_NAME}"
    install_policy
    restore_contexts

    if systemctl is-active myapp-backend.service >/dev/null 2>&1; then
        log_info "Restarting myapp-backend.service"
        systemctl restart myapp-backend.service
    fi
    if systemctl is-active myapp.service >/dev/null 2>&1; then
        log_info "Restarting myapp.service"
        systemctl restart myapp.service
    fi

    if [[ "${CANARY_MODE}" -eq 1 ]]; then
        log_info "Canary policy applied from ${POLICY_DIR} (${DOMAIN} permissive; soak clock started)"
    else
        log_info "Policy applied from ${POLICY_DIR} (enforcing domain — not a production canary deploy)"
    fi
    echo "Verify:"
    echo "  curl -v http://127.0.0.1:8888/save-log"
    echo "  curl -v http://127.0.0.1:8888/run-script"
    echo "  curl -v http://127.0.0.1:8888/probe-backend"
    echo "  curl -v http://127.0.0.1:8888/notify-socket"
    echo "  ausearch -m avc -ts recent | grep myapp || echo 'No recent myapp AVCs'"
}

main "$@"
