#!/usr/bin/env bash
#
# setup_staging_env.sh
# Prepares staging environment: app install, permissive stub policy, systemd.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_SRC="${PROJECT_ROOT}/app"
STUB_DIR="${PROJECT_ROOT}/selinux/stub"

INSTALL_ROOT="/opt/myapp"
BIN_DIR="${INSTALL_ROOT}/bin"
VAR_DIR="/var/myapp"
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
        log_error "SELinux is disabled. Enable SELinux and reboot before running this PoC."
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
    ensure_auditd
    require_command getenforce "policycoreutils"
    if command -v semanage >/dev/null 2>&1; then
        log_info "semanage available"
    else
        log_warn "semanage not found; using permissive domain in stub policy module"
    fi
    require_command restorecon "policycoreutils"
    require_command ausearch "audit"
    require_command checkmodule "checkpolicy"
    require_command semodule_package "checkpolicy"
    require_command semodule "policycoreutils"
    require_command systemctl "systemd"
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

    mkdir -p "${INSTALL_ROOT}" "${BIN_DIR}" "${VAR_DIR}"
    install -m 0644 "${APP_SRC}/app.py" "${INSTALL_ROOT}/app.py"
    install -m 0755 "${APP_SRC}/backup.sh" "${BIN_DIR}/backup.sh"
    chmod 0755 "${INSTALL_ROOT}/app.py"

    if [[ -f "${APP_SRC}/logrotate.d/myapp" ]]; then
        log_info "Installing logrotate config"
        install -m 0644 "${APP_SRC}/logrotate.d/myapp" "/etc/logrotate.d/myapp"
    fi

    chown -R "${SERVICE_USER}:${SERVICE_USER}" "${VAR_DIR}"
    chmod 0750 "${VAR_DIR}"
    chown -R root:root "${INSTALL_ROOT}"
    chown "${SERVICE_USER}:${SERVICE_USER}" "${VAR_DIR}"

    # Flask runs from a venv under /opt/myapp (FCOS-friendly install path)
}

has_selinux_devel() {
    [[ -f /usr/share/selinux/devel/include/common.inc.sh ]]
}

compile_stub_policy() {
    local work_dir pp_path
    work_dir="$(mktemp -d)"
    pp_path="${work_dir}/myapp.pp"

    log_info "Compiling stub SELinux policy module..."
    cp "${STUB_DIR}/myapp.te" "${work_dir}/myapp.te"
    cp "${STUB_DIR}/myapp.fc" "${work_dir}/myapp.fc"

    if has_selinux_devel; then
        checkmodule -M -m -o "${work_dir}/myapp.mod" "${work_dir}/myapp.te"
        semodule_package -o "${pp_path}" -m "${work_dir}/myapp.mod" -f "${work_dir}/myapp.fc"
    elif command -v podman >/dev/null 2>&1; then
        log_info "selinux-policy-devel not on host; compiling stub in Fedora container..."
        podman run --rm \
            -v "${STUB_DIR}:/stub:Z" \
            -v "${work_dir}:/out:Z" \
            docker.io/library/fedora:41 \
            bash -lc '
                set -euo pipefail
                dnf install -y -q selinux-policy-devel checkpolicy policycoreutils
                mkdir -p /build
                cp /stub/myapp.te /stub/myapp.fc /build/
                make -C /build -f /usr/share/selinux/devel/Makefile myapp.pp
                cp /build/myapp.pp /out/myapp.pp
            '
    else
        log_error "Cannot compile SELinux policy: install selinux-policy-devel or podman."
        rm -rf "${work_dir}"
        exit 1
    fi

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
    log_info "Installing systemd unit: ${SERVICE_NAME}"
    install -m 0644 "${APP_SRC}/myapp.service" "/etc/systemd/system/${SERVICE_NAME}"
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
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
        log_info "semanage not available; stub module uses permissive ${DOMAIN}"
    fi
}

restore_contexts() {
    log_info "Restoring SELinux contexts on ${INSTALL_ROOT} and ${VAR_DIR}"
    restorecon -Rv "${VAR_DIR}" 2>/dev/null || true
    # FCOS may leave default var_t on /opt paths; enforce PoC labels explicitly.
    if command -v chcon >/dev/null 2>&1; then
        chcon -t myapp_exec_t "${INSTALL_ROOT}/app.py" 2>/dev/null || true
        chcon -R -t myapp_exec_t "${INSTALL_ROOT}/venv" 2>/dev/null || true
        chcon -t myapp_script_exec_t "${BIN_DIR}/backup.sh" 2>/dev/null || true
        chcon -R -t myapp_var_lib_t "${VAR_DIR}" 2>/dev/null || true
    fi
}

wait_for_service() {
    local retries=15
    local i
    for ((i = 1; i <= retries; i++)); do
        if curl -sf "http://127.0.0.1:8888/" >/dev/null 2>&1; then
            log_info "Service is responding on port 8888"
            return 0
        fi
        sleep 1
    done
    log_warn "Service did not respond on port 8888 yet. Check: systemctl status ${SERVICE_NAME}"
    return 0
}

print_next_steps() {
    cat <<EOF

${GREEN}Setup complete.${NC}

Trigger SELinux AVC denials (permissive mode — requests may still succeed):

  curl -v http://127.0.0.1:8888/
  curl -v http://127.0.0.1:8888/save-log
  curl -v http://127.0.0.1:8888/run-script
  curl -v http://127.0.0.1:8888/rotate-log

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
    compile_stub_policy
    install_python_deps
    set_permissive_domain
    restore_contexts
    if [[ -x "${PROJECT_ROOT}/scripts/verify_file_contexts.sh" ]]; then
        bash "${PROJECT_ROOT}/scripts/verify_file_contexts.sh" \
            --install-root "${INSTALL_ROOT}" \
            --var-dir "${VAR_DIR}" \
            --app-name myapp \
            --skip-if-unavailable || true
    fi
    install_systemd_service
    wait_for_service
    print_next_steps
}

main "$@"
