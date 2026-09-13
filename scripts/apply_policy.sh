#!/usr/bin/env bash
#
# apply_policy.sh
# Compile (if needed) and install an AI-generated policy module on the SELinux host.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
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
BIN_DIR="${INSTALL_ROOT}/bin"
VAR_DIR="/var/myapp"
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

has_selinux_devel() {
    [[ -f /usr/share/selinux/devel/include/common.inc.sh ]]
}

compile_policy() {
    local te="${POLICY_DIR}/${MODULE_NAME}.te"
    local fc="${POLICY_DIR}/${MODULE_NAME}.fc"
    local pp="${POLICY_DIR}/${MODULE_NAME}.pp"

    if [[ ! -f "${te}" ]] || [[ ! -f "${fc}" ]]; then
        log_error "Missing ${te} or ${fc} in ${POLICY_DIR}"
        exit 1
    fi

    rm -f "${pp}" "${POLICY_DIR}/${MODULE_NAME}.mod"
    log_info "Compiling policy in ${POLICY_DIR}..."
    if has_selinux_devel; then
        checkmodule -M -m -o "${POLICY_DIR}/${MODULE_NAME}.mod" "${te}"
        semodule_package -o "${pp}" -m "${POLICY_DIR}/${MODULE_NAME}.mod" -f "${fc}"
    elif command -v podman >/dev/null 2>&1; then
        local work_dir
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
        log_error "Cannot compile policy: install selinux-policy-devel or podman"
        exit 1
    fi

    log_info "Built ${pp}"
}

restore_contexts() {
    log_info "Restoring contexts on ${INSTALL_ROOT}, ${VAR_DIR}, and /var/opt/myapp"
    restorecon -Rv "${VAR_DIR}" /var/opt/myapp 2>/dev/null || true
    if command -v chcon >/dev/null 2>&1; then
        chcon -t myapp_exec_t "${INSTALL_ROOT}/app.py" 2>/dev/null || true
        chcon -R -t myapp_exec_t "${INSTALL_ROOT}/venv" 2>/dev/null || true
        chcon -t myapp_script_exec_t "${BIN_DIR}/backup.sh" 2>/dev/null || true
        chcon -R -t myapp_var_lib_t "${VAR_DIR}" 2>/dev/null || true
    fi
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
    if semodule -l 2>/dev/null | grep -qw "${MODULE_NAME}"; then
        log_info "Removing existing ${MODULE_NAME} module before upgrade"
        semodule -r "${MODULE_NAME}" 2>/dev/null || true
    fi
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

    compile_policy
    install_policy
    restore_contexts

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
    echo "  ausearch -m avc -ts recent | grep myapp || echo 'No recent myapp AVCs'"
}

main "$@"
