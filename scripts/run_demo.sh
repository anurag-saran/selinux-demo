#!/usr/bin/env bash
#
# run_demo.sh — End-to-end Shift-Left PaC simulation (native Linux / VM)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SETUP="${SCRIPT_DIR}/setup_staging_env.sh"
GEN="${PROJECT_ROOT}/cli/selinux_gen.py"
COMPILE="${SCRIPT_DIR}/compile_and_validate.sh"
VERIFY="${SCRIPT_DIR}/verify_file_contexts.sh"
ANSIBLE="${PROJECT_ROOT}/ansible"
POLICY_OUT="${PROJECT_ROOT}/policy_out"
AVC_LOG="${POLICY_OUT}/avc.log"
APP_NAME="${POLICY_APP:-myapp}"
DOMAIN="${SELINUX_DOMAIN:-myapp_t}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/myapp}"
VAR_DIR="${VAR_DIR:-/var/myapp}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

require_root() {
    [[ "${EUID}" -eq 0 ]] || { log_error "Run as root: sudo $0"; exit 1; }
}

require_api_key() {
    [[ -n "${OPENAI_API_KEY:-}" ]] || { log_error "Set OPENAI_API_KEY"; exit 1; }
}

trigger_endpoints() {
    log_info "Triggering application endpoints..."
    for path in / /save-log /run-script /rotate-log; do
        curl -sf "http://127.0.0.1:8888${path}" || log_warn "${path} non-2xx"
        echo ""
    done
}

export_avcs() {
    mkdir -p "${POLICY_OUT}"
    if command -v ausearch >/dev/null 2>&1; then
        ausearch -m avc -ts boot --raw 2>/dev/null \
            | grep -E "myapp|/opt/myapp|/var/myapp|/var/opt/myapp" > "${AVC_LOG}" || true
    else
        grep '^type=AVC' /var/log/audit/audit.log 2>/dev/null \
            | grep -E "myapp|/opt/myapp|/var/myapp" > "${AVC_LOG}" || true
    fi
    if [[ ! -s "${AVC_LOG}" ]]; then
        log_warn "No AVC lines exported to ${AVC_LOG}"
    else
        log_info "Exported $(wc -l < "${AVC_LOG}") AVC lines"
    fi
}

main() {
    require_root
    require_api_key

    log_info "Step 1: Staging environment setup"
    bash "${SETUP}"

    log_info "Step 2: Trigger denials (permissive domain)"
    trigger_endpoints
    sleep 2
    export_avcs

    log_info "Step 3: AI policy generation (bump version)"
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

    log_info "Step 4: Compile validation"
    bash "${COMPILE}" "${POLICY_OUT}"

    if command -v ansible-playbook >/dev/null 2>&1; then
        log_info "Step 5: Ansible canary deploy"
        ansible-playbook -i "${ANSIBLE}/inventory.example.yml" \
            "${ANSIBLE}/deploy_canary.yml" \
            -e "policy_pp_path=${POLICY_OUT}/${APP_NAME}.pp"

        log_info "Step 5b: Verify file contexts after canary"
        bash "${VERIFY}" --install-root "${INSTALL_ROOT}" --var-dir "${VAR_DIR}" --app-name "${APP_NAME}" \
            || bash "${VERIFY}" --skip-if-unavailable

        log_warn "Step 6: Enforce (demo only — force_enforce bypasses production soak gate)"
        ansible-playbook -i "${ANSIBLE}/inventory.example.yml" \
            "${ANSIBLE}/enforce_production.yml" \
            -e "policy_pp_path=${POLICY_OUT}/${APP_NAME}.pp" \
            -e "force_enforce=true"
    else
        log_warn "ansible-playbook not found; applying policy directly"
        bash "${SCRIPT_DIR}/apply_policy.sh" "${POLICY_OUT}"
    fi

    log_info "Demo complete. Review:"
    echo "  selinux/policy_version.txt"
    echo "  policy_out/pr_summary.md"
    echo "  policy_out/${APP_NAME}.te"
    echo "  For paced workshops: sudo bash scripts/demo_present.sh --demo-mode"
    if command -v git >/dev/null 2>&1 && git -C "${PROJECT_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "${PROJECT_ROOT}" diff -- selinux/ policy_out/ || true
    fi
}

main "$@"
