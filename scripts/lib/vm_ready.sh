#!/usr/bin/env bash
#
# vm_ready.sh — Shared Podman Machine readiness helpers (macOS dev/workshop).
#
# Source from other scripts:
#   # shellcheck source=scripts/lib/vm_ready.sh
#   source "${SCRIPT_DIR}/lib/vm_ready.sh"
#
set -euo pipefail

VM_PODMAN_ENV="${HOME}/.local/share/selinux-demo/podman/env.sh"
VM_SSH_TIMEOUT_SEC="${VM_SSH_TIMEOUT_SEC:-90}"
VM_SERVICE_TIMEOUT_SEC="${VM_SERVICE_TIMEOUT_SEC:-60}"
VM_SSH_POLL_SEC="${VM_SSH_POLL_SEC:-2}"
VM_PROJECT="${VM_PROJECT:-/home/core/selinux-demo}"

_vm_log_info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
_vm_log_warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
_vm_log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

source_podman_env() {
    if [[ -f "${VM_PODMAN_ENV}" ]]; then
        # shellcheck disable=SC1090
        source "${VM_PODMAN_ENV}"
    fi
}

print_vm_recovery_card() {
    cat <<EOF
Podman VM recovery:
  source "${VM_PODMAN_ENV}"
  podman machine inspect podman-machine-default
  podman machine stop; podman machine start
  bash scripts/fix_podman.sh
  bash scripts/run_on_podman_vm.sh shell
EOF
}

wait_for_vm_ssh() {
    local timeout="${1:-${VM_SSH_TIMEOUT_SEC}}"
    local elapsed=0

    while [[ "${elapsed}" -lt "${timeout}" ]]; do
        if podman machine ssh -- true >/dev/null 2>&1; then
            return 0
        fi
        sleep "${VM_SSH_POLL_SEC}"
        elapsed=$((elapsed + VM_SSH_POLL_SEC))
    done

    _vm_log_error "Podman VM SSH not ready after ${timeout}s"
    podman machine ls 2>/dev/null || true
    print_vm_recovery_card
    return 1
}

# Start default machine if needed; never stop/restart when SSH already works.
ensure_vm_ready() {
    source_podman_env
    if ! command -v podman >/dev/null 2>&1; then
        _vm_log_error "podman not found. Run: bash scripts/fix_podman.sh"
        return 1
    fi

    local state=""
    state="$(podman machine inspect --format '{{.State}}' 2>/dev/null || true)"
    if [[ "${state}" == "running" ]] && podman machine ssh -- true >/dev/null 2>&1; then
        return 0
    fi

    if [[ "${state}" != "running" ]]; then
        if ! podman machine start >/dev/null 2>&1; then
            _vm_log_warn "podman machine start failed; retrying after stop"
            podman machine stop 2>/dev/null || true
            podman machine start || {
                _vm_log_error "podman machine start failed after retry"
                print_vm_recovery_card
                return 1
            }
        fi
    fi

    wait_for_vm_ssh "${VM_SSH_TIMEOUT_SEC}"
}

# Host-side poll of app services inside the VM via SSH.
wait_for_vm_services() {
    local timeout="${1:-${VM_SERVICE_TIMEOUT_SEC}}"
    local elapsed=0

    ensure_vm_ready || return 1

    while [[ "${elapsed}" -lt "${timeout}" ]]; do
        if podman machine ssh -- bash -lc "
            curl -sf http://127.0.0.1:8888/ >/dev/null 2>&1 &&
            curl -sf http://127.0.0.1:8889/health >/dev/null 2>&1
        " >/dev/null 2>&1; then
            _vm_log_info "VM services responding on ports 8888 and 8889"
            return 0
        fi
        sleep "${VM_SSH_POLL_SEC}"
        elapsed=$((elapsed + VM_SSH_POLL_SEC))
    done

    _vm_log_error "VM services did not become ready within ${timeout}s"
    podman machine ssh -- systemctl is-active myapp myapp-backend 2>/dev/null || true
    print_vm_recovery_card
    return 1
}

# Backward-compatible alias used by older scripts.
ensure_podman() {
    ensure_vm_ready
}
