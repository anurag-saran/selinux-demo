#!/usr/bin/env bash
# ansible_collections.sh — Install galaxy deps for admin acts (source only)
set -euo pipefail

demo_needs_ansible_collections() {
    local n
    for n in 6 7 8 9 10; do
        if act_enabled "${n}"; then
            return 0
        fi
    done
    return 1
}

ensure_ansible_collections() {
    local reqs="${PROJECT_ROOT}/ansible/requirements.yml"
    [[ -f "${reqs}" ]] || {
        log_warn "Missing ${reqs} — skipping Ansible collection install"
        return 0
    }

    if [[ "${USE_VM:-0}" -eq 1 ]]; then
        log_info "Ensuring Ansible collections on Podman VM (required for acts 6–10)…"
        local vproj="${VM_PROJECT:-/home/core/selinux-pac}"
        if ! podman machine ssh -- "cd ${vproj} && ansible-galaxy collection install -r ansible/requirements.yml"; then
            log_error "Could not install collections in the VM."
            echo "  podman machine ssh -- \"cd ${vproj} && ansible-galaxy collection install -r ansible/requirements.yml\"" >&2
            exit 1
        fi
        return 0
    fi

    if ! command -v ansible-galaxy >/dev/null 2>&1; then
        log_error "ansible-galaxy not found — install ansible before acts 6–10"
        exit 1
    fi
    log_info "Ensuring Ansible collections (acts 6–10)…"
    ansible-galaxy collection install -r "${reqs}"
}
