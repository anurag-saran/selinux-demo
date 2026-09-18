#!/usr/bin/env bash
#
# setup_staging_env.sh
# Prepares staging: reference app + systemd. Default also loads the training
# stub module (labs). Customer demo: --app-only first; write_domain_seed.sh after unconfined curls.
#
set -euo pipefail

APP_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-only) APP_ONLY=1; shift ;;
        --app-root) APP_ROOT="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [--app-only] [--app-root DIR]

  (default)  Install the Flask app, load selinux/stub/ (training labs), start units
  --app-only Install the Flask app and units only — no SELinux module
  --app-root Application tree (Flask + systemd). Default: sibling/~/myapp if
             present, else this selinux-pac checkout.
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/app_root.sh
source "${SCRIPT_DIR}/lib/app_root.sh"
bind_app_tree "${PROJECT_ROOT}"
if [[ "${APP_ONLY}" -eq 0 ]]; then
    # shellcheck source=lib/compile_policy.sh
    source "${SCRIPT_DIR}/lib/compile_policy.sh"
fi
APP_SRC="${APP_ROOT}/app"
STUB_DIR="${PROJECT_ROOT}/selinux/stub"

INSTALL_ROOT="/opt/myapp"
BIN_DIR="${INSTALL_ROOT}/bin"
VAR_DIR="/var/lib/myapp"
LOG_DIR="/var/log/myapp"
SPOOL_DIR="/var/spool/myapp"
RUNTIME_DIR="/run/myapp"
SERVICE_NAME="myapp.service"
SERVICE_USER="myapp"
DOMAIN="myapp_t"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)."
        exit 1
    fi
}

require_command() {
    local cmd="$1"
    local pkg_hint="$2"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        log_error "Required command not found: ${cmd}"
        log_error "Install hint: dnf install ${pkg_hint}"
        exit 1
    fi
}

check_selinux() {
    if ! command -v getenforce >/dev/null 2>&1; then
        log_error "SELinux tools not found. Install policycoreutils."
        exit 1
    fi

    local mode
    mode="$(getenforce)"
    if [[ "${mode}" == "Disabled" ]]; then
        log_error "SELinux is disabled. Enable SELinux and reboot before running staging setup."
        exit 1
    fi
    log_info "SELinux mode: ${mode}"
}

ensure_auditd() {
    if ! command -v auditd >/dev/null 2>&1; then
        log_warn "auditd not installed; AVC logging may be unavailable."
        return 0
    fi

    mkdir -p /var/log/audit
    touch /var/log/audit/audit.log
    chmod 0600 /var/log/audit/audit.log 2>/dev/null || true

    if systemctl is-active auditd >/dev/null 2>&1; then
        log_info "auditd is running"
        return 0
    fi

    log_info "Starting auditd for AVC collection..."
    systemctl enable auditd 2>/dev/null || true
    systemctl start auditd 2>/dev/null || auditd 2>/dev/null || log_warn "Could not start auditd"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    require_command systemctl "systemd"
    if [[ "${APP_ONLY}" -eq 1 ]]; then
        check_selinux
        return 0
    fi
    ensure_auditd
    require_command getenforce "policycoreutils"
    if command -v semanage >/dev/null 2>&1; then
        log_info "semanage available"
    else
        log_warn "semanage not found; training stub uses permissive myapp_t in policy source"
    fi
    require_command restorecon "policycoreutils"
    require_command ausearch "audit"
    require_command semodule "policycoreutils"
    check_selinux
}

create_service_user() {
    if ! id "${SERVICE_USER}" >/dev/null 2>&1; then
        log_info "Creating system user: ${SERVICE_USER}"
        useradd --system --no-create-home --shell /sbin/nologin "${SERVICE_USER}"
    else
        log_info "Service user already exists: ${SERVICE_USER}"
    fi
}

install_application() {
    log_info "Installing application to ${INSTALL_ROOT}"

    mkdir -p "${INSTALL_ROOT}" "${BIN_DIR}" "${VAR_DIR}" "${LOG_DIR}" "${SPOOL_DIR}"
    install -m 0644 "${APP_SRC}/app.py" "${INSTALL_ROOT}/app.py"
    install -m 0755 "${APP_SRC}/backend_stub.py" "${INSTALL_ROOT}/backend_stub.py"
    install -m 0755 "${APP_SRC}/backup.sh" "${BIN_DIR}/backup.sh"
    chmod 0755 "${INSTALL_ROOT}/app.py"

    if [[ -f "${APP_SRC}/logrotate.d/myapp" ]]; then
        log_info "Installing logrotate config"
        install -m 0644 "${APP_SRC}/logrotate.d/myapp" "/etc/logrotate.d/myapp"
    fi

    chown -R "${SERVICE_USER}:${SERVICE_USER}" "${VAR_DIR}" "${LOG_DIR}" "${SPOOL_DIR}"
    chmod 0750 "${VAR_DIR}"
    chmod 0750 "${LOG_DIR}"
    chmod 0750 "${SPOOL_DIR}"
    chown -R root:root "${INSTALL_ROOT}"
    chmod 755 "${INSTALL_ROOT}" "${BIN_DIR}"
    mkdir -p "${INSTALL_ROOT}/__pycache__"
    chown "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_ROOT}/__pycache__"
    chmod 0750 "${INSTALL_ROOT}/__pycache__"

    # Flask runs from a venv under /opt/myapp (FCOS-friendly install path)
}

clear_staging_deploy_artifacts() {
    local removed=0
    for f in "${VAR_DIR}/selinux_canary_deployed_at" "${VAR_DIR}/selinux_deploy_report.json"; do
        if [[ -e "${f}" ]]; then
            rm -f "${f}"
            removed=1
        fi
    done
    if [[ "${removed}" -eq 1 ]]; then
        log_info "Removed prior demo/canary deploy markers under ${VAR_DIR}"
    fi
}

clear_stale_app_ports() {
    # Local seport mappings survive semodule -r. The stub has no myapp_port_t /
    # myapp_backend_port_t, so leftover tcp 8888/8889 maps make semodule -i fail.
    if ! command -v semanage >/dev/null 2>&1; then
        return 0
    fi
    log_info "Clearing leftover local port maps for tcp 8888/8889 (if any)"
    semanage port -d -t myapp_port_t -p tcp 8888 2>/dev/null || true
    semanage port -d -t myapp_backend_port_t -p tcp 8889 2>/dev/null || true
}

compile_stub_policy() {
    local work_dir pp_path
    work_dir="$(mktemp -d)"
    pp_path="${work_dir}/myapp.pp"

    clear_staging_deploy_artifacts
    log_info "Compiling stub SELinux policy module..."
    clear_stale_app_ports
    for mod in myapp_ports myapp_canary myapp; do
        semodule -r "${mod}" 2>/dev/null || true
    done
    clear_stale_app_ports
    cp "${STUB_DIR}/myapp.te" "${work_dir}/myapp.te"
    cp "${STUB_DIR}/myapp.fc" "${work_dir}/myapp.fc"

    compile_policy_module "${work_dir}" "myapp" "${pp_path}"

    semodule -i "${pp_path}"
    rm -rf "${work_dir}"
    log_info "Stub module installed via semodule -i"
}

install_python_deps() {
    local venv="${INSTALL_ROOT}/venv"
    local python_bin="${venv}/bin/python"
    local python_real

    if [[ -x "${python_bin}" ]] && [[ -s "${python_bin}" ]] && "${python_bin}" -c "import flask" >/dev/null 2>&1; then
        python_real="$(readlink -f "${python_bin}" 2>/dev/null || true)"
        if [[ -n "${python_real}" && "${python_real}" == /usr/bin/python* ]]; then
            log_warn "Recreating venv: interpreter symlinks to system python (breaks systemd/SELinux exec)"
            rm -rf "${venv}"
        else
            log_info "Python venv with flask already present"
            return 0
        fi
    elif [[ -d "${venv}" ]]; then
        log_warn "Recreating broken or incomplete venv at ${venv}"
        rm -rf "${venv}"
    fi

    log_info "Creating Python venv and installing flask..."
    if command -v python3 >/dev/null 2>&1; then
        python3 -m venv --copies "${venv}"
        "${venv}/bin/pip" install --quiet flask
    elif command -v podman >/dev/null 2>&1; then
        podman run --rm \
            --security-opt label=disable \
            -v "${INSTALL_ROOT}:${INSTALL_ROOT}" \
            docker.io/library/fedora:41 \
            bash -lc "
                set -euo pipefail
                dnf install -y -q python3
                python3 -m venv --copies ${venv}
                ${venv}/bin/pip install --quiet flask
            "
    else
        log_error "Cannot create venv: install python3 or podman"
        exit 1
    fi

    if [[ ! -s "${python_bin}" ]] || ! "${python_bin}" -c "import flask" >/dev/null 2>&1; then
        log_error "Venv creation failed: ${python_bin} is missing or flask is not installed"
        exit 1
    fi

    chown -R root:root "${venv}"
    chmod -R a+rx "${venv}"
}

install_systemd_service() {
    log_info "Installing systemd units: myapp-backend.service, ${SERVICE_NAME}"
    install -m 0644 "${APP_SRC}/myapp-backend.service" "/etc/systemd/system/myapp-backend.service"
    install -m 0644 "${APP_SRC}/myapp.service" "/etc/systemd/system/${SERVICE_NAME}"
    systemctl daemon-reload
    systemctl enable myapp-backend.service
    systemctl enable "${SERVICE_NAME}"
    systemctl stop myapp-backend.service "${SERVICE_NAME}" 2>/dev/null || true
    pkill -f 'backend_stub.py' 2>/dev/null || true
    rm -f "${RUNTIME_DIR}/notify.sock"
    systemctl restart myapp-backend.service
    systemctl restart "${SERVICE_NAME}"
}

set_permissive_domain() {
    if command -v semanage >/dev/null 2>&1; then
        if semanage permissive -l 2>/dev/null | grep -qw "${DOMAIN}"; then
            log_info "Domain ${DOMAIN} is already permissive (semanage)"
        else
            log_info "Setting ${DOMAIN} to permissive via semanage"
            semanage permissive -a "${DOMAIN}"
        fi
    else
        log_info "semanage not available; training stub uses permissive ${DOMAIN} in policy source"
    fi
}

restore_contexts() {
    log_info "Restoring SELinux contexts on ${INSTALL_ROOT}, ${VAR_DIR}, ${LOG_DIR}, and ${RUNTIME_DIR}"
    restorecon -Rv "${INSTALL_ROOT}/app.py" "${INSTALL_ROOT}/backend_stub.py" "${BIN_DIR}" "${INSTALL_ROOT}/venv" \
        "${VAR_DIR}" "${LOG_DIR}" "${RUNTIME_DIR}" 2>/dev/null || true
}

wait_for_service() {
    bash "${SCRIPT_DIR}/wait_for_endpoints.sh" --host 127.0.0.1 --retries 30 --delay 2 \
        --skip-domain-check \
        || log_warn "Services did not respond yet. Check: systemctl status myapp-backend ${SERVICE_NAME}"
}

print_next_steps() {
    printf '\n%b\n\n' "${GREEN}Setup complete.${NC}"
    cat <<EOF
Trigger SELinux AVC denials (permissive mode — requests may still succeed):

  curl -v http://127.0.0.1:8888/
  curl -v http://127.0.0.1:8888/save-log
  curl -v http://127.0.0.1:8888/run-script
  curl -v http://127.0.0.1:8888/rotate-log
  curl -v http://127.0.0.1:8888/probe-backend
  curl -v http://127.0.0.1:8888/notify-socket

Do not call /feature-spool until after the first policy is enforcing on prod (Act 2).

View recent AVC denials:

  ausearch -m avc -ts recent | grep myapp

Generate policy (Policy-as-Code CLI):

  export OPENAI_API_KEY="your-key"
  python3 ${PROJECT_ROOT}/cli/selinux_gen.py --audit-log policy_out/avc.log --bump-version --generate-only

EOF
}

main() {
    require_root
    check_prerequisites
    create_service_user
    install_application
    if [[ "${APP_ONLY}" -eq 0 ]]; then
        compile_stub_policy
        if [[ -f "${PROJECT_ROOT}/selinux/myapp_canary.te" ]]; then
            log_info "Building FCOS canary overlay (myapp_canary.pp)..."
            POLICY_MODULE=myapp_canary bash "${PROJECT_ROOT}/scripts/compile_and_validate.sh" "${PROJECT_ROOT}/selinux"
        fi
    else
        log_info "--app-only: skipping SELinux module install (customer demo / prod app ship)"
    fi
    install_python_deps
    if [[ "${APP_ONLY}" -eq 0 ]]; then
        set_permissive_domain
        restore_contexts
        if [[ -x "${PROJECT_ROOT}/scripts/verify_file_contexts.sh" ]]; then
            bash "${PROJECT_ROOT}/scripts/verify_file_contexts.sh" \
                --install-root "${INSTALL_ROOT}" \
                --var-dir "${VAR_DIR}" \
                --runtime-dir "${RUNTIME_DIR}" \
                --app-name myapp \
                --skip-if-unavailable || true
        fi
    fi
    install_systemd_service
    wait_for_service
    print_next_steps
}

main "$@"
