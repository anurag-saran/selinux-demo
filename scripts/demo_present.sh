#!/usr/bin/env bash
#
# demo_present.sh — Paced workshop demo: dev → PR → canary → guardrails → enforce
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SETUP="${SCRIPT_DIR}/setup_staging_env.sh"
GEN="${PROJECT_ROOT}/cli/selinux_gen.py"
COMPILE="${SCRIPT_DIR}/compile_and_validate.sh"
FORBIDDEN="${SCRIPT_DIR}/validate_forbidden_patterns.sh"
ASSEMBLE="${SCRIPT_DIR}/assemble_pr_body.sh"
VERIFY="${SCRIPT_DIR}/verify_file_contexts.sh"
MONITOR="${SCRIPT_DIR}/monitor_avc.sh"
SOAK="${SCRIPT_DIR}/check_soak_ready.sh"
VM_HELPER="${SCRIPT_DIR}/run_on_podman_vm.sh"
ANSIBLE="${PROJECT_ROOT}/ansible"
INVENTORY="${ANSIBLE}/inventory.example.yml"
POLICY_OUT="${PROJECT_ROOT}/policy_out"
AVC_LOG="${POLICY_OUT}/avc.log"
PR_BODY="${POLICY_OUT}/pr_body.md"
APP_NAME="${POLICY_APP:-myapp}"
DOMAIN="${SELINUX_DOMAIN:-myapp_t}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/myapp}"
VAR_DIR="${VAR_DIR:-/var/lib/myapp}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/myapp}"
SOAK_MARKER="${VAR_DIR}/selinux_canary_deployed_at"
MANIFEST="${APP_MANIFEST:-${PROJECT_ROOT}/config/${APP_NAME}.manifest.yml}"
VM_PROJECT="/home/core/selinux-demo"
VM_POLICY_PP="${VM_PROJECT}/policy_out/${APP_NAME}.pp"
VM_POLICY_DIR="${VM_PROJECT}/policy_out"

AUTO=0
DEMO_MODE=0
USE_VM=0
SKIP_AI=0
PREFETCH=0
ACTS_SPEC="1-10"
ACT_MIN=1
ACT_MAX=10

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Paced presenter demo for Shift-Left SELinux Policy-as-Code (real commands, optional pauses).

Options:
  --prefetch       Build/pull Podman images (SELinux toolchain) and exit — prep night before demo
  --auto           Skip "Press Enter" pauses (rehearsal / CI)
  --demo-mode      Workshop shortcuts: pre-seed soak marker; force_enforce on enforce step
  --use-vm         Run staging/canary/enforce inside Podman Machine VM (macOS)
  --skip-ai        Offline demo: fixtures from docs/examples/fixtures/skip_ai/ (no OPENAI_API_KEY)
  --acts RANGE     Run subset of acts, e.g. 1-6 or 1,3,5 (default: 1-10)
  -h, --help       Show help

Acts:
  1  Staging setup + integration tests (permissive)
  2  Export AVC denials
  3  AI policy generation
  4  Assemble PR body for admin review
  5  CI gates (forbidden patterns + compile)
  6  Ansible canary deploy
  7  Production guardrails (verify contexts + monitor AVC)
  8  Soak period gate (7–14 days in production)
  9  Enforce production
  10 Emergency rollback (show commands)

Examples:
  export OPENAI_API_KEY="your-key"
  sudo bash scripts/demo_present.sh --demo-mode
  bash scripts/demo_present.sh --use-vm --demo-mode --auto
  bash scripts/demo_present.sh --skip-ai --acts 1-7 --demo-mode

Production vs demo:
  Production: staging soak 7–14d → prod canary → check_soak_ready.sh → enforce
  Demo:       --demo-mode bypasses soak timer only; all other steps are real
EOF
}

parse_acts() {
    if [[ "${ACTS_SPEC}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        ACT_MIN="${BASH_REMATCH[1]}"
        ACT_MAX="${BASH_REMATCH[2]}"
    elif [[ "${ACTS_SPEC}" =~ ^[0-9,]+$ ]]; then
        ACT_MIN=99
        ACT_MAX=0
        IFS=',' read -r -a _acts <<< "${ACTS_SPEC}"
        for a in "${_acts[@]}"; do
            [[ "${a}" -lt "${ACT_MIN}" ]] && ACT_MIN="${a}"
            [[ "${a}" -gt "${ACT_MAX}" ]] && ACT_MAX="${a}"
        done
    else
        log_error "Invalid --acts value: ${ACTS_SPEC}"
        exit 1
    fi
}

act_enabled() {
    local n="$1"
    if [[ "${ACTS_SPEC}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        [[ "${n}" -ge "${ACT_MIN}" && "${n}" -le "${ACT_MAX}" ]]
        return
    fi
    IFS=',' read -r -a _acts <<< "${ACTS_SPEC}"
    for a in "${_acts[@]}"; do
        [[ "${a}" == "${n}" ]] && return 0
    done
    return 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto) AUTO=1; shift ;;
        --demo-mode) DEMO_MODE=1; shift ;;
        --use-vm) USE_VM=1; shift ;;
        --skip-ai) SKIP_AI=1; shift ;;
        --prefetch) PREFETCH=1; shift ;;
        --acts) ACTS_SPEC="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

parse_acts

if [[ "${PREFETCH}" -eq 1 ]]; then
    # shellcheck source=lib/selinux_build_image.sh
    source "${SCRIPT_DIR}/lib/selinux_build_image.sh"
    log_info "Prefetch: building SELinux toolchain image (${SELINUX_BUILD_IMAGE}) …"
    ensure_selinux_build_image
    if command -v podman >/dev/null 2>&1; then
        log_info "Prefetch: ensuring base Stream image for slow-path fallback (${SELINUX_COMPILE_IMAGE}) …"
        podman pull "${SELINUX_COMPILE_IMAGE}" 2>/dev/null || true
    fi
    log_info "Prefetch complete — demo compile/validate steps can run offline."
    exit 0
fi

act_banner() {
    local num="$1" title="$2" narration="$3"
    echo ""
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  ACT ${num}: ${title}${NC}"
    echo -e "${CYAN}  ${narration}${NC}"
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

pause_step() {
    [[ "${AUTO}" -eq 1 ]] && return 0
    read -r -p "Press Enter to continue..." _
}

require_api_key() {
    [[ "${SKIP_AI}" -eq 1 ]] && return 0
    [[ -n "${OPENAI_API_KEY:-}" ]] || { log_error "Set OPENAI_API_KEY or use --skip-ai"; exit 1; }
}

require_root_if_native() {
    [[ "${USE_VM}" -eq 1 ]] && return 0
    [[ "${EUID}" -eq 0 ]] || { log_error "Run as root on native Linux: sudo $0 ..."; exit 1; }
}

VM_SYNCED=0

vm_sync() {
    bash "${VM_HELPER}" sync
    VM_SYNCED=1
}

vm_run() {
    if [[ "${1:-}" == "--sync" ]]; then
        shift
        vm_sync
    fi
    [[ $# -gt 0 ]] || { log_error "vm_run: missing remote command"; exit 1; }
    bash "${VM_HELPER}" exec "$*"
}

vm_ensure_ready() {
    # shellcheck source=lib/vm_ready.sh
    source "${SCRIPT_DIR}/lib/vm_ready.sh"
    ensure_vm_ready
}

trigger_endpoints_native() {
    for path in / /save-log /run-script /rotate-log /probe-backend /notify-socket; do
        curl -sf "http://127.0.0.1:8888${path}" || log_warn "${path} non-2xx"
        echo ""
    done
}

export_avcs_native() {
    mkdir -p "${POLICY_OUT}"
    # shellcheck source=lib/manifest_shell.sh
    source "${SCRIPT_DIR}/lib/manifest_shell.sh"
    # shellcheck source=lib/avc_query.sh
    source "${SCRIPT_DIR}/lib/avc_query.sh"
    local manifest="${APP_MANIFEST:-${PROJECT_ROOT}/config/${APP_NAME}.manifest.yml}"
    source_app_manifest_exports "${manifest}"
    export_app_avcs_to_file "${AVC_LOG}" boot "${PRIMARY_DOMAIN}" "${BACKEND_DOMAIN:-}" "${PATHS_CSV}"
    if [[ ! -s "${AVC_LOG}" ]]; then
        log_warn "No AVC lines exported to ${AVC_LOG}"
    else
        log_info "Exported $(wc -l < "${AVC_LOG}" | tr -d ' ') AVC lines"
    fi
}

ensure_pr_summary_for_assemble() {
    if [[ -f "${POLICY_OUT}/pr_summary.md" ]]; then
        return 0
    fi
    log_warn "Creating placeholder pr_summary.md for assembly demo"
    cat > "${POLICY_OUT}/pr_summary.md" <<EOF
### Network Bindings
- Port 8888 via unreserved_port_t

### File System Access
- ${APP_NAME}_var_lib_t for ${VAR_DIR}

### Process Execution
- ${APP_NAME}_exec_t entrypoint and backup script

### Explicit Denials Maintained
- No wildcard allows; no shadow_t / unconfined_t / sysadm_t
EOF
}

act_1_staging() {
    act_banner 1 "Staging" "App team runs integration tests with myapp_t in permissive mode"
    if [[ "${USE_VM}" -eq 1 ]]; then
        ensure_vm_ready || exit 1
        if podman machine ssh -- "systemctl is-active myapp.service myapp-backend.service >/dev/null 2>&1"; then
            log_info "Staging already active on VM — skipping setup (curl probes only)"
            bash "${VM_HELPER}" trigger
        else
            bash "${VM_HELPER}" setup
            sleep 2
            bash "${VM_HELPER}" trigger
        fi
    else
        bash "${SETUP}"
        sleep 2
        trigger_endpoints_native
    fi
}

act_2_export() {
    act_banner 2 "AVC Export" "Capture denials from audit log for AI policy input"
    if [[ "${SKIP_AI}" -eq 1 ]]; then
        log_info "Using recorded fixture AVC log (--skip-ai)"
        pause_step
        return 0
    fi
    if [[ "${USE_VM}" -eq 1 ]]; then
        bash "${VM_HELPER}" export-avcs "${AVC_LOG}" || true
    else
        export_avcs_native
    fi
}

act_3_generate() {
    act_banner 3 "AI Generate" "Policy-as-Code CLI merges AVCs into selinux/ module"
    if [[ "${SKIP_AI}" -eq 1 ]]; then
        bash "${SCRIPT_DIR}/lib/stage_skip_ai_fixture.sh"
        log_info "Offline generation (--skip-ai): staged fixture → policy_out/"
        log_info "Diff baseline (1.1.0) → generated (matches selinux/):"
        if command -v git >/dev/null 2>&1; then
            git -C "${PROJECT_ROOT}" diff --no-index \
                "${PROJECT_ROOT}/docs/examples/fixtures/skip_ai/baseline/${APP_NAME}.te" \
                "${POLICY_OUT}/${APP_NAME}.te" 2>/dev/null || true
        else
            diff -u "${PROJECT_ROOT}/docs/examples/fixtures/skip_ai/baseline/${APP_NAME}.te" \
                "${POLICY_OUT}/${APP_NAME}.te" 2>/dev/null || true
        fi
        pause_step
        return 0
    fi
    python3 "${GEN}" \
        --app-name "${APP_NAME}" \
        --domain "${DOMAIN}" \
        --audit-log "${AVC_LOG}" \
        --existing-te "${PROJECT_ROOT}/selinux/${APP_NAME}.te" \
        --existing-fc "${PROJECT_ROOT}/selinux/${APP_NAME}.fc" \
        --bump-version \
        --validate-compile \
        --generate-only \
        --output-dir "${POLICY_OUT}"
}

act_4_pr_handoff() {
    act_banner 4 "PR Handoff" "Assemble PR body with AI summary + AVC excerpt for admin review"
    ensure_pr_summary_for_assemble
    local assemble_args=(
        --app-name "${APP_NAME}"
        --staging-host "workshop-staging"
        --test-suite "Presenter demo integration tests"
    )
    if [[ "${SKIP_AI}" -eq 1 ]]; then
        assemble_args+=(--skip-policy-diff)
    fi
    bash "${ASSEMBLE}" "${assemble_args[@]}"
    log_info "PR body preview (first 25 lines):"
    head -n 25 "${PR_BODY}" || true
}

act_5_ci_gates() {
    act_banner 5 "CI Gates" "Forbidden-pattern checks and compile validation (mirrors GitHub Actions)"
    bash "${FORBIDDEN}" "${POLICY_OUT}"
    bash "${COMPILE}" "${POLICY_OUT}"
}

run_canary_playbook() {
    if [[ "${USE_VM}" -eq 1 ]]; then
        [[ "${VM_SYNCED}" -eq 1 ]] || vm_sync
        local cmd="sudo ansible-playbook -i ansible/inventory.example.yml ansible/deploy_canary.yml -e policy_pp_src=${VM_POLICY_PP} -e policy_artifact_dir=${VM_POLICY_DIR}"
        for arg in "$@"; do cmd+=" ${arg}"; done
        vm_run "${cmd}"
    else
        ansible-playbook -i "${INVENTORY}" "${ANSIBLE}/deploy_canary.yml" \
            -e "policy_pp_src=${POLICY_OUT}/${APP_NAME}.pp" \
            -e "policy_artifact_dir=${POLICY_OUT}" "$@"
    fi
}

run_enforce_playbook() {
    if [[ "${USE_VM}" -eq 1 ]]; then
        [[ "${VM_SYNCED}" -eq 1 ]] || vm_sync
        local cmd="sudo ansible-playbook -i ansible/inventory.example.yml ansible/enforce_production.yml -e policy_pp_src=${VM_POLICY_PP} -e policy_artifact_dir=${VM_POLICY_DIR}"
        for arg in "$@"; do cmd+=" ${arg}"; done
        vm_run "${cmd}"
    else
        ansible-playbook -i "${INVENTORY}" "${ANSIBLE}/enforce_production.yml" \
            -e "policy_pp_src=${POLICY_OUT}/${APP_NAME}.pp" \
            -e "policy_artifact_dir=${POLICY_OUT}" "$@"
    fi
}

act_6_canary() {
    act_banner 6 "Canary Deploy" "Admin installs policy with semanage permissive -a ${DOMAIN}"
    if [[ "${USE_VM}" -eq 1 ]]; then
        vm_sync
    fi
    if command -v ansible-playbook >/dev/null 2>&1 || [[ "${USE_VM}" -eq 1 ]]; then
        run_canary_playbook
    else
        log_warn "ansible-playbook not found; applying policy directly"
        bash "${SCRIPT_DIR}/apply_policy.sh" "${POLICY_OUT}"
    fi
}

act_7_guardrails() {
    act_banner 7 "Production Guardrails" "Verify file contexts and run daily AVC monitor"
    local verify_cmd="sudo bash scripts/verify_file_contexts.sh --install-root ${INSTALL_ROOT} --var-dir ${VAR_DIR} --app-name ${APP_NAME}"
    local monitor_cmd="sudo bash scripts/monitor_avc.sh --domain ${DOMAIN} --manifest ${MANIFEST} --marker-file ${SOAK_MARKER} --max-avc -1"
    if [[ "${USE_VM}" -eq 1 ]]; then
        vm_run "${verify_cmd} || ${verify_cmd} --skip-if-unavailable"
        vm_run "${monitor_cmd} --skip-if-unavailable"
    else
        bash "${VERIFY}" --install-root "${INSTALL_ROOT}" --var-dir "${VAR_DIR}" --app-name "${APP_NAME}" \
            || bash "${VERIFY}" --skip-if-unavailable
        bash "${MONITOR}" --domain "${DOMAIN}" --manifest "${MANIFEST}" --marker-file "${SOAK_MARKER}" --max-avc -1 \
            --skip-if-unavailable || true
    fi
}

act_8_soak() {
    act_banner 8 "Soak Period" "Production requires 7–14 days permissive soak before enforce"
    echo "  Marker file: ${SOAK_MARKER}"
    echo "  Production command: bash scripts/check_soak_ready.sh --domain ${DOMAIN}"
    echo ""

    if [[ "${DEMO_MODE}" -eq 1 ]]; then
        log_warn "DEMO MODE: simulating completed soak (pre-seeding marker to 8 days ago)"
        local old_epoch
        old_epoch=$(( $(date +%s) - 8 * 86400 ))
        if [[ "${USE_VM}" -eq 1 ]]; then
            vm_run "echo ${old_epoch} | sudo tee ${SOAK_MARKER} >/dev/null"
            vm_run "sudo bash scripts/check_soak_ready.sh --domain ${DOMAIN} --marker-file ${SOAK_MARKER} --min-days 7 --max-avc 9999 --skip-if-unavailable"
        else
            echo "${old_epoch}" > "${SOAK_MARKER}"
            bash "${SOAK}" --domain "${DOMAIN}" --marker-file "${SOAK_MARKER}" \
                --min-days 7 --max-avc 9999 --skip-if-unavailable
        fi
        return 0
    fi

    log_info "Running soak gate (will fail if canary was just deployed — expected in production)"
    if [[ "${USE_VM}" -eq 1 ]]; then
        vm_run "sudo bash scripts/check_soak_ready.sh --domain ${DOMAIN} --marker-file ${SOAK_MARKER} --min-days 7 --max-avc 0 --skip-if-unavailable" \
            || log_warn "Soak gate not ready yet (expected until 7+ days)"
    else
        bash "${SOAK}" --domain "${DOMAIN}" --marker-file "${SOAK_MARKER}" --min-days 7 --max-avc 0 \
            --skip-if-unavailable || log_warn "Soak gate not ready yet (expected until 7+ days)"
    fi
}

act_9_enforce() {
    act_banner 9 "Enforce" "Admin removes permissive flag after soak gate passes"
    local enforce_extra=()
    if [[ "${DEMO_MODE}" -eq 1 ]]; then
        log_warn "DEMO MODE: using force_enforce=true (break-glass — never use in real production without approval)"
        enforce_extra=(-e "force_enforce=true")
    fi
    if command -v ansible-playbook >/dev/null 2>&1 || [[ "${USE_VM}" -eq 1 ]]; then
        run_enforce_playbook "${enforce_extra[@]}"
    else
        log_warn "ansible-playbook not found; apply_policy.sh enforce path not shown"
    fi
}

act_10_rollback() {
    act_banner 10 "Emergency Rollback" "Outage escape hatch: permissive → export AVCs → AI patch"
    cat <<EOF
${YELLOW}Show-only (not executed in workshop demo):${NC}

  # Step 1: instant relief
  sudo semanage permissive -a ${DOMAIN}

  # Step 2: capture denials
  sudo ausearch -m avc -ts recent > /tmp/prod_outage_denials.log

  # Step 3: Ansible rollback + optional AI patch
  ansible-playbook -i ansible/inventory.example.yml ansible/emergency_rollback.yml

See docs/PRODUCTION_READINESS.md for the full runbook.
EOF
}

# shellcheck source=lib/ansible_collections.sh
source "${SCRIPT_DIR}/lib/ansible_collections.sh"

main() {
    echo -e "${BOLD}SELinux Policy-as-Code — Presenter Demo${NC}"
    if [[ "${DEMO_MODE}" -eq 1 ]]; then
        log_warn "Demo mode ON — soak timer bypassed for acts 8–9 only"
    fi
    echo "Acts: ${ACTS_SPEC} | use-vm=${USE_VM} | skip-ai=${SKIP_AI} | auto=${AUTO}"
    echo ""

    require_api_key
    require_root_if_native

    if [[ "${SKIP_AI}" -eq 1 ]]; then
        bash "${SCRIPT_DIR}/lib/stage_skip_ai_fixture.sh"
    fi

    if [[ "${USE_VM}" -eq 1 ]]; then
        # shellcheck disable=SC1090
        [[ -f "${HOME}/.local/share/selinux-demo/podman/env.sh" ]] && source "${HOME}/.local/share/selinux-demo/podman/env.sh"
        command -v podman >/dev/null 2>&1 || { log_error "Install Podman: bash scripts/fix_podman.sh"; exit 1; }
        vm_ensure_ready
    fi

    if demo_needs_ansible_collections; then
        ensure_ansible_collections
    fi

    for act in 1 2 3 4 5 6 7 8 9 10; do
        act_enabled "${act}" || continue
        if [[ "${DEMO_PREP:-0}" -eq 1 ]]; then
            demop_preamble "${act}"
            pause_step
        fi
        case "${act}" in
            1) act_1_staging ;;
            2) act_2_export ;;
            3) act_3_generate ;;
            4) act_4_pr_handoff ;;
            5) act_5_ci_gates ;;
            6) act_6_canary ;;
            7) act_7_guardrails ;;
            8) act_8_soak ;;
            9) act_9_enforce ;;
            10) act_10_rollback ;;
        esac
        if [[ "${DEMO_PREP:-0}" -eq 1 ]]; then
            demop_show_screen "${act}"
        fi
        pause_step
    done

    echo ""
    log_info "Presenter demo complete."
    echo "  policy_out/pr_summary.md"
    echo "  policy_out/pr_body.md"
    echo "  Demo guide: docs/DEMO_GUIDE.md"
    echo "  Runbook: docs/PRODUCTION_READINESS.md"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
