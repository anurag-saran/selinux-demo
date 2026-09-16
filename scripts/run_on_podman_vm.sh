#!/usr/bin/env bash
#
# run_on_podman_vm.sh — Podman Machine VM workflow for SELinux PaC
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/vm_ready.sh
source "${SCRIPT_DIR}/lib/vm_ready.sh"

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

VM: sync, setup, trigger (all integration curls on guest), avcs, export-avcs, apply-policy, demo, shell, exec
Mac: generate-policy (deterministic_gen; optional POLICY_SUMMARY_LLM=1)
Legacy: ai
EOF
}

sync_project() {
    log_info "Syncing ${PROJECT_ROOT} -> VM:${VM_PROJECT}"
    podman machine ssh -- mkdir -p "${VM_PROJECT}"
    # COPYFILE_DISABLE avoids AppleDouble; guest tar may warn on xattr keywords — filter noise.
    if ! COPYFILE_DISABLE=1 tar czf - -C "${PROJECT_ROOT}" . \
        | podman machine ssh -- "tar --warning=no-unknown-keyword -xzf - -C ${VM_PROJECT} 2>/dev/null \
            || tar xzf - -C ${VM_PROJECT} 2>/dev/null"; then
        log_error "Project sync to VM failed"
        print_vm_recovery_card
        exit 1
    fi
    podman machine ssh -- test -f "${VM_PROJECT}/scripts/setup_staging_env.sh"
    log_info "Sync complete"
}

vm_exec() { podman machine ssh -- "cd ${VM_PROJECT} && $1"; }

export_avcs() {
    local output="${1:-${AVC_EXPORT}}"
    local manifest="${2:-${APP_MANIFEST:-${PROJECT_ROOT}/config/${APP_NAME}.manifest.yml}}"
    [[ -f "${manifest}" ]] || {
        log_error "App manifest required for export-avcs: ${manifest}"
        exit 1
    }
    # shellcheck source=lib/manifest_shell.sh
    source "${SCRIPT_DIR}/lib/manifest_shell.sh"
    # shellcheck source=lib/avc_query.sh
    source "${SCRIPT_DIR}/lib/avc_query.sh"
    source_app_manifest_exports "${manifest}"
    mkdir -p "$(dirname "${output}")"
    log_info "Exporting AVC logs to ${output} (domain=${PRIMARY_DOMAIN})"
    local raw=""
    raw="$(podman machine ssh -- \
        "sudo ausearch --input-logs -m AVC,USER_AVC,SELINUX_ERR,USER_SELINUX_ERR -ts boot --subject ${PRIMARY_DOMAIN} --format raw 2>/dev/null || true")"
    if [[ -n "${BACKEND_DOMAIN}" ]]; then
        raw+=$'\n'
        raw+="$(podman machine ssh -- \
            "sudo ausearch --input-logs -m AVC,USER_AVC,SELINUX_ERR,USER_SELINUX_ERR -ts boot --subject ${BACKEND_DOMAIN} --format raw 2>/dev/null || true")"
    fi
    if [[ -z "${raw//[$'\n']/}" ]]; then
        log_warn "No AVC lines exported"
        : > "${output}"
        return 1
    fi
    printf '%s\n' "${raw}" | avc_filter_lines_by_paths "${PATHS_CSV}" > "${output}" || true
    [[ -s "${output}" ]] || { log_warn "No AVC lines matched manifest paths"; return 1; }
    log_info "Exported $(wc -l < "${output}" | tr -d ' ') lines"
}

generate_policy() {
    [[ -s "${AVC_EXPORT}" ]] || { log_error "Run export-avcs first"; exit 1; }
    ensure_vm_ready || exit 1
    log_info "Generating policy via cli/deterministic_gen.py..."
    # shellcheck source=lib/policy_generation.sh
    source "${SCRIPT_DIR}/lib/policy_generation.sh"
    local policy_te="${SELINUX_DIR}/${APP_NAME}.te"
    local policy_fc="${SELINUX_DIR}/${APP_NAME}.fc"
    local policy_version="${SELINUX_DIR}/policy_version.txt"
    local manifest="${APP_MANIFEST:-${PROJECT_ROOT}/config/${APP_NAME}.manifest.yml}"
    run_deterministic_policy_gen \
        "${AVC_EXPORT}" \
        "${manifest}" \
        "${policy_te}" \
        "${policy_fc}" \
        "${policy_version}" \
        "${POLICY_OUT}" \
        "${APP_NAME}"
    if [[ "${POLICY_SUMMARY_LLM:-0}" == "1" ]] && [[ -n "${OPENAI_API_KEY:-}" ]]; then
        LLM_SUMMARY=1
        run_llm_pr_summary_if_requested "${POLICY_OUT}" "${APP_NAME}"
    fi
}

apply_policy_on_vm() {
    [[ -f "${POLICY_OUT}/${APP_NAME}.te" ]] || { log_error "Run generate-policy first"; exit 1; }
    sync_project
    vm_exec "sudo bash scripts/apply_policy.sh ${VM_PROJECT}/policy_out"
    vm_exec "sudo bash scripts/wait_for_endpoints.sh --host 127.0.0.1 --retries 15 --delay 2"
}

trigger_curls() {
    sync_project
    vm_exec "bash -lc 'source ${VM_PROJECT}/scripts/lib/integration_probes.sh && INTEGRATION_UI=vm INTEGRATION_AUTO=1 run_integration_probes'"
}

cmd="${1:-}"
shift || true

case "${cmd}" in
    sync) ensure_vm_ready || exit 1; sync_project ;;
    setup) ensure_vm_ready || exit 1; sync_project; vm_exec "sudo bash scripts/setup_staging_env.sh" ;;
    trigger) ensure_vm_ready || exit 1; trigger_curls ;;
    avcs) ensure_vm_ready || exit 1; vm_exec "sudo ausearch -m avc -ts recent 2>/dev/null | grep myapp | head -20 || echo '(none)'" ;;
    export-avcs) ensure_vm_ready || exit 1; export_avcs "${1:-${AVC_EXPORT}}" ;;
    generate-policy) generate_policy ;;
    apply-policy) ensure_vm_ready || exit 1; apply_policy_on_vm ;;
    demo)
        ensure_vm_ready || exit 1
        sync_project
        vm_exec "sudo bash scripts/setup_staging_env.sh"
        trigger_curls
        vm_exec "sudo ausearch -m avc -ts recent 2>/dev/null | grep myapp | head -15 || true"
        ;;
    exec)
        ensure_vm_ready || exit 1
        [[ $# -gt 0 ]] || { log_error "Usage: $(basename "$0") exec 'command'"; exit 1; }
        vm_exec "$*"
        ;;
    ai)
        log_error "Legacy 'ai' command removed. Use:"
        log_error "  bash scripts/run_on_podman_vm.sh export-avcs"
        log_error "  bash scripts/run_on_podman_vm.sh generate-policy"
        log_error "  bash scripts/dev_generate_policy.sh --use-vm --apply"
        exit 1
        ;;
    shell) ensure_vm_ready || exit 1; podman machine ssh ;;
    -h|--help|help|"") usage ;;
    *) log_error "Unknown: ${cmd}"; usage; exit 1 ;;
esac
