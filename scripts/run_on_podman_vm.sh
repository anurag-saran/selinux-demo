#!/usr/bin/env bash
#
# run_on_podman_vm.sh — Podman Machine VM workflow for SELinux PaC
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PODMAN_ENV="${HOME}/.local/share/selinux-demo/podman/env.sh"
VM_PROJECT="/home/core/selinux-demo"
POLICY_OUT="${PROJECT_ROOT}/policy_out"
SELINUX_DIR="${PROJECT_ROOT}/selinux"
AVC_EXPORT="${POLICY_OUT}/avc.log"
DOMAIN="${SELINUX_DOMAIN:-myapp_t}"
APP_NAME="${POLICY_APP:-myapp}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") <command>

VM: sync, setup, trigger, avcs, export-avcs, apply-policy, demo, shell
Mac: generate-policy (cli/selinux_gen.py)
Legacy: ai
EOF
}

ensure_podman() {
    if [[ -f "${PODMAN_ENV}" ]]; then
        # shellcheck disable=SC1090
        source "${PODMAN_ENV}"
    fi
    command -v podman >/dev/null 2>&1 || { log_error "Run: bash scripts/fix_podman.sh"; exit 1; }
    podman machine start 2>/dev/null || true
    podman machine ssh -- getenforce >/dev/null 2>&1 || { log_error "Podman VM unreachable"; exit 1; }
}

sync_project() {
    log_info "Syncing ${PROJECT_ROOT} -> VM:${VM_PROJECT}"
    podman machine ssh -- mkdir -p "${VM_PROJECT}"
    COPYFILE_DISABLE=1 tar czf - -C "${PROJECT_ROOT}" . 2>/dev/null \
        | podman machine ssh -- tar xzf - -C "${VM_PROJECT}" 2>/dev/null
    podman machine ssh -- test -f "${VM_PROJECT}/scripts/setup_staging_env.sh"
    log_info "Sync complete"
}

vm_exec() { podman machine ssh -- "cd ${VM_PROJECT} && $1"; }

export_avcs() {
    local output="${1:-${AVC_EXPORT}}"
    mkdir -p "$(dirname "${output}")"
    log_info "Exporting AVC logs to ${output}"
    podman machine ssh -- \
        "sudo ausearch -m avc -ts boot --raw 2>/dev/null || sudo grep '^type=AVC' /var/log/audit/audit.log" \
        | grep -E "myapp|/opt/myapp|/var/myapp|/var/opt/myapp" > "${output}" || true
    [[ -s "${output}" ]] || { log_warn "No AVC lines exported"; return 1; }
    log_info "Exported $(wc -l < "${output}" | tr -d ' ') lines"
}

generate_policy() {
    [[ -n "${OPENAI_API_KEY:-}" ]] || { log_error "OPENAI_API_KEY not set"; exit 1; }
    [[ -s "${AVC_EXPORT}" ]] || { log_error "Run export-avcs first"; exit 1; }
    ensure_podman
    log_info "Generating policy via cli/selinux_gen.py..."
    python3 "${PROJECT_ROOT}/cli/selinux_gen.py" \
        --app-name "${APP_NAME}" \
        --domain "${DOMAIN}" \
        --audit-log "${AVC_EXPORT}" \
        --existing-te "${SELINUX_DIR}/${APP_NAME}.te" \
        --existing-fc "${SELINUX_DIR}/${APP_NAME}.fc" \
        --bump-version \
        --validate-compile \
        --generate-only \
        --output-dir "${POLICY_OUT}" \
        --api-model "${OPENAI_API_MODEL:-gpt-4o-mini}"
}

apply_policy_on_vm() {
    [[ -f "${POLICY_OUT}/${APP_NAME}.te" ]] || { log_error "Run generate-policy first"; exit 1; }
    sync_project
    vm_exec "sudo bash scripts/apply_policy.sh ${VM_PROJECT}/policy_out"
    sleep 2
    vm_exec "curl -sf http://127.0.0.1:8888/save-log; echo; curl -sf http://127.0.0.1:8888/run-script; echo; curl -sf http://127.0.0.1:8888/rotate-log; echo"
}

trigger_curls() {
    vm_exec "curl -sf http://127.0.0.1:8888/; echo; curl -sf http://127.0.0.1:8888/save-log; echo; curl -sf http://127.0.0.1:8888/run-script; echo; curl -sf http://127.0.0.1:8888/rotate-log; echo"
}

cmd="${1:-}"
shift || true

case "${cmd}" in
    sync) ensure_podman; sync_project ;;
    setup) ensure_podman; sync_project; vm_exec "sudo bash scripts/setup_staging_env.sh" ;;
    trigger) ensure_podman; trigger_curls ;;
    avcs) ensure_podman; vm_exec "sudo ausearch -m avc -ts recent 2>/dev/null | grep myapp | head -20 || echo '(none)'" ;;
    export-avcs) ensure_podman; export_avcs "${1:-${AVC_EXPORT}}" ;;
    generate-policy) generate_policy ;;
    apply-policy) ensure_podman; apply_policy_on_vm ;;
    demo)
        ensure_podman; sync_project
        vm_exec "sudo bash scripts/setup_staging_env.sh"
        sleep 3; trigger_curls; sleep 2
        vm_exec "sudo ausearch -m avc -ts recent 2>/dev/null | grep myapp | head -15 || true"
        ;;
    ai)
        ensure_podman; sync_project
        vm_exec "sudo -E env OPENAI_API_KEY='${OPENAI_API_KEY}' python3 cli/selinux_gen.py --apply --domain ${DOMAIN} --output-dir ${VM_PROJECT}/policy_out"
        ;;
    shell) ensure_podman; podman machine ssh ;;
    -h|--help|help|"") usage ;;
    *) log_error "Unknown: ${cmd}"; usage; exit 1 ;;
esac
