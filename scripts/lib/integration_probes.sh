#!/usr/bin/env bash
# integration_probes.sh — Run demo HTTP integration probes (source only)
#
# INTEGRATION_UI=training | demo | vm
#   training — tlab_* helpers (run_training_lab.sh)
#   demo     — log_info (demo_present.sh); set USE_VM, VM_PROJECT, AUTO
#   vm       — non-interactive [INFO] lines (runs on guest via run_on_podman_vm.sh trigger)
set -euo pipefail

INTEGRATION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTEGRATION_UI="${INTEGRATION_UI:-training}"
INTEGRATION_HOST="${INTEGRATION_HOST:-127.0.0.1}"
INTEGRATION_PORT="${INTEGRATION_PORT:-8888}"
INTEGRATION_AUTO="${INTEGRATION_AUTO:-0}"
INTEGRATION_VM_PROJECT="${INTEGRATION_VM_PROJECT:-${VM_PROJECT:-/home/core/selinux-demo}}"

_integration_all_probes_body() {
    cat <<EOS
set -euo pipefail
H="${INTEGRATION_HOST}"
P="${INTEGRATION_PORT}"
paths=(/ /save-log /run-script /rotate-log /probe-backend /notify-socket)
for path in "\${paths[@]}"; do
  echo "=== GET \${path} ==="
  curl -sf "http://\${H}:\${P}\${path}" | head -c 120
  echo
done
echo "=== GET :8889/health ==="
curl -sf "http://\${H}:8889/health"; echo
EOS
}

_integration_audit_tail_body() {
    cat <<'EOS'
count=$(sudo ausearch -m avc -ts recent 2>/dev/null | grep -cE 'myapp|init_t' || true)
echo "--- Recent myapp/init_t AVC lines in audit: ${count} ---"
sudo ausearch -m avc -ts recent 2>/dev/null | grep -E 'myapp|init_t' | tail -5 \
  || echo '(no matching lines - stub/permissive may allow everything; Act 2 uses policy_out/avc.log)'
EOS
}

_integration_demo_vm_ready() {
    [[ "${USE_VM:-0}" -eq 1 ]] || return 0
    [[ "${INTEGRATION_DEMO_VM_READY:-0}" -eq 1 ]] && return 0
    # shellcheck source=lib/vm_ready.sh
    source "${INTEGRATION_LIB_DIR}/vm_ready.sh"
    ensure_vm_ready || return 1
    INTEGRATION_DEMO_VM_READY=1
}

_integration_demo_vm_run() {
    local cmd="$1"
    _integration_demo_vm_ready || return 1
    podman machine ssh -- "cd ${INTEGRATION_VM_PROJECT} && bash -lc $(printf '%q' "${cmd}")"
}

_integration_run_probes_on_host() {
    local body oneliner
    body="$(_integration_all_probes_body)"
    oneliner='for path in / /save-log /run-script /rotate-log /probe-backend /notify-socket; do echo "=== GET $path ==="; curl -sf "http://127.0.0.1:8888${path}" | head -c 120; echo; done; echo "=== GET :8889/health ==="; curl -sf http://127.0.0.1:8889/health; echo'
    case "${INTEGRATION_UI}" in
        training)
            tlab_why "Each URL exercises a different SELinux permission (files, script, network, socket)."
            tlab_question "Does the app work under SELinux and hit all HTTP probes?"
            tlab_explain "Six GETs on :8888 plus backend health — curl -sf fails if any path errors."
            tlab_run_cmd "${oneliner}"
            ;;
        demo)
            log_info "Integration tests — all HTTP paths in order (one VM session on Mac)."
            log_tool 'for path in / /save-log /run-script /rotate-log /probe-backend /notify-socket; do curl -sf "http://127.0.0.1:8888${path}"; done; curl -sf http://127.0.0.1:8889/health'
            echo -e "\033[0;32m\$\033[0m for path in / /save-log /run-script /rotate-log /probe-backend /notify-socket; do curl -sf http://${INTEGRATION_HOST}:${INTEGRATION_PORT}\${path}; done"
            if [[ "${USE_VM:-0}" -eq 1 ]]; then
                _integration_demo_vm_run "${body}" || log_warn "integration probes failed"
            else
                bash -lc "${body}" || log_warn "integration probes failed"
            fi
            ;;
        vm)
            echo "[INFO] Integration probes (all paths)"
            bash -lc "${body}" || true
            ;;
    esac
}

_integration_show_audit_tail() {
    local body
    body="$(_integration_audit_tail_body)"
    case "${INTEGRATION_UI}" in
        training)
            tlab_explain "Sample audit evidence after all probes (full export in Lab 8–10)."
            tlab_run_cmd_sudo "bash -lc $(printf '%q' "${body}")"
            tlab_checkpoint "All six paths and backend health succeeded; you can read recent AVC lines above."
            ;;
        demo|vm)
            ;;
    esac
}

# Run all integration GETs in one pass; optional audit tail for training lab.
run_integration_probes() {
    _integration_run_probes_on_host
    if [[ "${INTEGRATION_UI}" == training ]]; then
        _integration_show_audit_tail
    fi
}

# Backward-compatible alias (demo / docs).
staged_integration_probes() {
    run_integration_probes
}
