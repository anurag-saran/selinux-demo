#!/usr/bin/env bash
#
# container_entrypoint.sh
# Prepares the Podman container (auditd, optional SELinux check) then execs CMD.
#
set -euo pipefail

log_info() { echo "[entrypoint] $*"; }
log_warn() { echo "[entrypoint][WARN] $*" >&2; }

start_auditd() {
    if ! command -v auditd >/dev/null 2>&1; then
        log_warn "auditd not installed; AVC collection may not work."
        return 0
    fi

    mkdir -p /var/log/audit
    touch /var/log/audit/audit.log
    chmod 0600 /var/log/audit/audit.log

    if systemctl is-active auditd >/dev/null 2>&1; then
        log_info "auditd already running"
        return 0
    fi

    log_info "Starting auditd..."
    systemctl enable auditd 2>/dev/null || true
    systemctl start auditd 2>/dev/null || auditd 2>/dev/null || log_warn "Could not start auditd"
}

check_selinux_for_poc() {
    if ! command -v getenforce >/dev/null 2>&1; then
        log_warn "getenforce not found."
        return 0
    fi

    local mode
    mode="$(getenforce 2>/dev/null || echo "Unknown")"
    log_info "SELinux mode inside container: ${mode}"

    if [[ "${mode}" == "Disabled" ]]; then
        log_warn "SELinux is disabled inside the container."
        log_warn "Run via scripts/podman_run.sh so /sys/fs/selinux is mounted."
        log_warn "On macOS: ensure podman machine is running (podman machine start)."
    fi
}

# systemd as PID 1 when --systemd=always is used; otherwise start critical services manually.
if [[ "${1:-}" == "/sbin/init" ]] || [[ "${1:-}" == "/usr/lib/systemd/systemd" ]]; then
    exec "$@"
fi

start_auditd
check_selinux_for_poc

if [[ $# -eq 0 ]]; then
    set -- /bin/bash
fi

exec "$@"
