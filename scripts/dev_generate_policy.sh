#!/usr/bin/env bash
#
# dev_generate_policy.sh — One-command developer self-service policy generation
#
# Exports AVC logs, runs cli/selinux_gen.py, diffs against selinux/, optionally
# promotes generated policy into selinux/ for PR commit.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GEN="${PROJECT_ROOT}/cli/selinux_gen.py"
DETERMINISTIC="${PROJECT_ROOT}/cli/deterministic_gen.py"
VERIFY_AVC="${PROJECT_ROOT}/cli/verify_avc_coverage.py"
SELINUX_DIR="${PROJECT_ROOT}/selinux"
POLICY_OUT="${PROJECT_ROOT}/policy_out"
AVC_LOG="${POLICY_OUT}/avc.log"
APP_NAME="${POLICY_APP:-myapp}"
DOMAIN="${SELINUX_DOMAIN:-myapp_t}"
ENGINE="${POLICY_ENGINE:-deterministic}"
MANIFEST="${PROJECT_ROOT}/config/${APP_NAME}.manifest.yml"
[[ -f "${MANIFEST}" ]] || MANIFEST="${PROJECT_ROOT}/config/myapp.manifest.yml"
USE_VM=0
APPLY=0
ENFORCE_CHECK=0
SKIP_EXPORT=0
OPEN_PR=0
STAGING_HOST="${STAGING_HOST:-Podman VM / native staging host}"
TEST_SUITE="${TEST_SUITE:-Integration tests (curl endpoints)}"
ASSEMBLE="${SCRIPT_DIR}/assemble_pr_body.sh"
# shellcheck source=lib/version.sh
source "${SCRIPT_DIR}/lib/version.sh"
# shellcheck source=lib/manifest_shell.sh
source "${SCRIPT_DIR}/lib/manifest_shell.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Developer self-service: export AVCs → generate policy → diff → optional promote to selinux/

Options:
  --engine MODE    deterministic (default) or llm (requires OPENAI_API_KEY)
  --apply          Copy policy_out/{app}.te/.fc into selinux/ after generation
  --enforce-check  Load candidate policy enforcing and run endpoint + domain checks
  --open-pr        Run gh pr create with assembled pr_body.md (requires gh CLI + git branch)
  --use-vm         Export AVCs via scripts/run_on_podman_vm.sh (macOS Podman VM)
  --skip-export    Use existing policy_out/avc.log (must be non-empty)
  --app-name NAME  Module name (default: myapp)
  --staging-host   Staging environment label for PR body
  --test-suite     Test suite description for PR body
  -h, --help       Show this help

Environment:
  OPENAI_API_KEY   Required for --engine llm
  POLICY_ENGINE    Default engine if --engine omitted (deterministic|llm)
  POLICY_ALLOW_DEGRADED  Pass --allow-degraded to deterministic_gen when sepolgen missing
  SELINUX_BUILD_IMAGE  Prebuilt compile image (default: docker.io/asaran/…:stream9; override for internal registry)
  SELINUX_BUILD_IMAGE_PULL  Pull from registry before local build (default: 1; set 0 for air-gapped local build only)
  SELINUX_BUILD_IMAGE_AUTO  Build image locally when pull fails (default: 1)
  OPENAI_BASE_URL  Optional LiteLLM endpoint
  OPENAI_API_MODEL Optional model override

Example:
  export OPENAI_API_KEY="your-key"
  bash scripts/dev_generate_policy.sh --use-vm --apply
  git checkout -b policy/update && git add selinux/ && gh pr create --body-file policy_out/pr_summary.md
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --enforce-check) ENFORCE_CHECK=1; shift ;;
        --open-pr) OPEN_PR=1; APPLY=1; shift ;;
        --use-vm) USE_VM=1; shift ;;
        --skip-export) SKIP_EXPORT=1; shift ;;
        --engine) ENGINE="$2"; shift 2 ;;
        --app-name) APP_NAME="$2"; DOMAIN="${APP_NAME}_t"; shift 2 ;;
        --staging-host) STAGING_HOST="$2"; shift 2 ;;
        --test-suite) TEST_SUITE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

sync_identity_from_manifest() {
    [[ -f "${MANIFEST}" ]] || {
        log_error "App manifest not found: ${MANIFEST} (set POLICY_APP or APP_MANIFEST)"
        exit 1
    }
    source_app_manifest_exports "${MANIFEST}"
    APP_NAME="${APP_NAME}"
    DOMAIN="${PRIMARY_DOMAIN}"
}

require_api_key() {
    [[ "${ENGINE}" == deterministic ]] && return 0
    [[ -n "${OPENAI_API_KEY:-}" ]] || {
        log_error "Set OPENAI_API_KEY or use --engine deterministic"
        exit 1
    }
}

resolve_manifest_policy_paths() {
    python3 - "${MANIFEST}" "${PROJECT_ROOT}" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[2]) / "scripts" / "lib"))
from app_manifest import load_manifest, policy_source_paths

root = Path(sys.argv[2])
manifest = load_manifest(Path(sys.argv[1]))
paths = policy_source_paths(root, manifest)
print(paths["te"])
print(paths["fc"])
print(paths["version_file"])
print(paths["module_dir"])
PY
}

load_policy_paths_from_manifest() {
    local idx=0
    while IFS= read -r line; do
        case "${idx}" in
            0) POLICY_TE="${line}" ;;
            1) POLICY_FC="${line}" ;;
            2) POLICY_VERSION_FILE="${line}" ;;
            3) POLICY_MODULE_DIR="${line}" ;;
        esac
        idx=$((idx + 1))
    done < <(resolve_manifest_policy_paths)
}

require_existing_policy() {
    load_policy_paths_from_manifest
    [[ -f "${POLICY_TE}" ]] || {
        log_error "Missing ${POLICY_TE}"
        exit 1
    }
    [[ -f "${POLICY_FC}" ]] || {
        log_error "Missing ${POLICY_FC}"
        exit 1
    }
}

export_avcs() {
    sync_identity_from_manifest
    mkdir -p "${POLICY_OUT}"
    if [[ "${USE_VM}" -eq 1 ]]; then
        log_info "Exporting AVCs from Podman VM..."
        bash "${SCRIPT_DIR}/run_on_podman_vm.sh" export-avcs "${AVC_LOG}" "${MANIFEST}"
    else
        # shellcheck source=lib/avc_query.sh
        source "${SCRIPT_DIR}/lib/avc_query.sh"
        if ! command -v ausearch >/dev/null 2>&1 && [[ ! -f /var/log/audit/audit.log ]]; then
            log_error "No ausearch on host; use --use-vm or run on a SELinux Linux host"
            exit 1
        fi
        log_info "Exporting AVCs from local audit log (avc_query pipeline)..."
        export_app_avcs_to_file "${AVC_LOG}" boot "${PRIMARY_DOMAIN}" "${BACKEND_DOMAIN:-}" "${PATHS_CSV}"
    fi
    [[ -s "${AVC_LOG}" ]] || {
        log_error "No AVC lines in ${AVC_LOG}. Run staging tests first:"
        echo "  sudo bash scripts/setup_staging_env.sh"
        echo "  curl http://127.0.0.1:8888/save-log"
        exit 1
    }
    log_info "Exported $(wc -l < "${AVC_LOG}" | tr -d ' ') AVC lines to ${AVC_LOG}"
}

generate_policy() {
    if [[ "${ENGINE}" == deterministic ]]; then
        log_info "Running cli/deterministic_gen.py (offline)..."
        mkdir -p "${POLICY_OUT}"
        cp "${POLICY_VERSION_FILE}" "${POLICY_OUT}/policy_version.txt"
        python3 "${DETERMINISTIC}" \
            --avc-log "${AVC_LOG}" \
            --manifest "${MANIFEST}" \
            --existing-te "${POLICY_TE}" \
            --existing-fc "${POLICY_FC}" \
            --out-dir "${POLICY_OUT}" \
            --version-file "${POLICY_OUT}/policy_version.txt" \
            --bump-version \
            $( [[ "${POLICY_ALLOW_DEGRADED:-0}" == "1" ]] && echo --allow-degraded )
        bash "${SCRIPT_DIR}/validate_forbidden_patterns.sh" "${POLICY_OUT}"
        bash "${SCRIPT_DIR}/compile_and_validate.sh" "${POLICY_OUT}"
        return 0
    fi
    log_info "Running cli/selinux_gen.py..."
    python3 "${GEN}" \
        --app-name "${APP_NAME}" \
        --domain "${DOMAIN}" \
        --audit-log "${AVC_LOG}" \
        --existing-te "${POLICY_TE}" \
        --existing-fc "${POLICY_FC}" \
        --bump-version \
        --validate-compile \
        --generate-only \
        --output-dir "${POLICY_OUT}"
}

show_diff() {
    load_policy_paths_from_manifest
    log_info "Diff: ${POLICY_MODULE_DIR}/ vs policy_out/"
    if command -v git >/dev/null 2>&1 && git -C "${PROJECT_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "${PROJECT_ROOT}" diff --no-index \
            "${POLICY_TE}" "${POLICY_OUT}/${APP_NAME}.te" 2>/dev/null || true
        git -C "${PROJECT_ROOT}" diff --no-index \
            "${POLICY_FC}" "${POLICY_OUT}/${APP_NAME}.fc" 2>/dev/null || true
    else
        diff -u "${POLICY_TE}" "${POLICY_OUT}/${APP_NAME}.te" 2>/dev/null || true
        diff -u "${POLICY_FC}" "${POLICY_OUT}/${APP_NAME}.fc" 2>/dev/null || true
    fi
}

promote_to_selinux() {
    load_policy_paths_from_manifest
    log_info "Promoting policy_out → ${POLICY_MODULE_DIR}/"
    cp "${POLICY_OUT}/${APP_NAME}.te" "${POLICY_TE}"
    cp "${POLICY_OUT}/${APP_NAME}.fc" "${POLICY_FC}"
    if [[ -f "${POLICY_OUT}/policy_version.txt" ]]; then
        cp "${POLICY_OUT}/policy_version.txt" "${POLICY_VERSION_FILE}"
    else
        match="$(policy_module_version_from_te "${POLICY_OUT}/${APP_NAME}.te" "${APP_NAME}")" || {
            log_error "promote_to_selinux: cannot extract SemVer from policy_module() in ${POLICY_OUT}/${APP_NAME}.te"
            exit 1
        }
        echo "${match}" > "${POLICY_VERSION_FILE}"
    fi
    log_info "Updated ${POLICY_TE}, ${POLICY_FC}, and ${POLICY_VERSION_FILE}"
}

verify_avc_coverage() {
    log_info "Verifying AVC log coverage in policy_out/${APP_NAME}.te..."
    python3 "${VERIFY_AVC}" \
        --avc-log "${AVC_LOG}" \
        --te "${POLICY_OUT}/${APP_NAME}.te" \
        --manifest "${MANIFEST}"
}

assemble_pr_body() {
    log_info "Assembling PR body..."
    local common_args=(
        --app-name "${APP_NAME}"
        --staging-host "${STAGING_HOST}"
        --test-suite "${TEST_SUITE}"
        --output "${POLICY_OUT}/pr_body.md"
    )
    if [[ "${ASSEMBLE_SKIP_POLICY_DIFF:-0}" == "1" ]]; then
        bash "${ASSEMBLE}" "${common_args[@]}" --skip-policy-diff
        return
    fi
    if ! bash "${ASSEMBLE}" "${common_args[@]}"; then
        log_warn "Policy access diff failed (sesearch/Podman) — PR body without delta section"
        bash "${ASSEMBLE}" "${common_args[@]}" --skip-policy-diff
    fi
}

open_pr() {
    if ! command -v gh >/dev/null 2>&1; then
        log_error "gh CLI not found; install GitHub CLI or open PR manually"
        return 1
    fi
    local branch="policy/${APP_NAME}-update"
    log_info "Creating branch ${branch}, committing, pushing, and opening PR..."
    git -C "${PROJECT_ROOT}" checkout -b "${branch}" 2>/dev/null || \
        git -C "${PROJECT_ROOT}" checkout "${branch}"
    git -C "${PROJECT_ROOT}" add \
        "selinux/${APP_NAME}.te" \
        "selinux/${APP_NAME}.fc" \
        "selinux/policy_version.txt"
    if git -C "${PROJECT_ROOT}" diff --cached --quiet; then
        log_error "Nothing to commit — run with --apply after generation"
        return 1
    fi
    git -C "${PROJECT_ROOT}" commit -m "$(cat <<EOF
security(selinux): Update policy module for ${APP_NAME}

Generated via dev_generate_policy.sh
EOF
)"
    git -C "${PROJECT_ROOT}" push -u origin "${branch}"
    gh pr create \
        --title "security(selinux): Update policy module for ${APP_NAME}" \
        --body-file "${POLICY_OUT}/pr_body.md" \
        --label security \
        --label selinux \
        --label pending-admin-review
}

run_enforce_check() {
    local te_src fc_src pp_path
    te_src="${POLICY_OUT}/${APP_NAME}.te"
    fc_src="${POLICY_OUT}/${APP_NAME}.fc"

    pp_path="${POLICY_OUT}/${APP_NAME}.pp"
    log_info "Compiling candidate policy for enforce-check..."
    # shellcheck source=lib/compile_policy.sh
    source "${SCRIPT_DIR}/lib/compile_policy.sh"
    compile_policy_module "$(dirname "${te_src}")" "${APP_NAME}" "${pp_path}"

    if [[ "${USE_VM}" -eq 1 ]]; then
        log_info "Running enforce-check on Podman VM..."
        bash "${SCRIPT_DIR}/run_on_podman_vm.sh" enforce-check "${pp_path}"
        return $?
    fi

    if [[ "${EUID}" -ne 0 ]]; then
        log_error "enforce-check requires root on host (or use --use-vm)"
        return 1
    fi

    semodule -i "${pp_path}"
    semanage permissive -d "${DOMAIN}" 2>/dev/null || true
    restorecon -Rv /opt/myapp /var/lib/myapp /var/log/myapp /run/myapp 2>/dev/null || true
    systemctl restart myapp-backend.service myapp.service
    if bash "${SCRIPT_DIR}/wait_for_endpoints.sh" --host 127.0.0.1 --retries 10 --delay 2; then
        log_info "enforce-check passed under enforcing ${DOMAIN}"
        return 0
    fi

    log_error "enforce-check failed — recent AVCs:"
    bash "${SCRIPT_DIR}/monitor_avc.sh" --domain "${DOMAIN}" --manifest "${MANIFEST}" --since recent --max-avc -1 --show-lines 5 || true
    semanage permissive -a "${DOMAIN}" 2>/dev/null || true
    return 1
}

print_pr_steps() {
    cat <<EOF

--- Next steps (Git PR handoff) ---

1. Review assembled PR body:
   cat policy_out/pr_body.md

2. Validate locally (matches CI):
   bash scripts/compile_and_validate.sh selinux
   bash scripts/validate_forbidden_patterns.sh selinux
   python3 scripts/smoke_test.py

3. Commit, push, and open PR:
   git checkout -b policy/${APP_NAME}-update
   git add selinux/${APP_NAME}.te selinux/${APP_NAME}.fc selinux/policy_version.txt
   git commit -m "security(selinux): Update policy module for ${APP_NAME}"
   git push -u origin policy/${APP_NAME}-update
   gh pr create \\
     --title "security(selinux): Update policy module for ${APP_NAME}" \\
     --body-file policy_out/pr_body.md \\
     --label security --label selinux --label pending-admin-review

Admin team: review PR table + summary; merge triggers staging canary; enforce via deploy workflow.

EOF
}

main() {
    require_api_key
    sync_identity_from_manifest
    require_existing_policy

    # shellcheck source=lib/compile_policy.sh
    source "${SCRIPT_DIR}/lib/compile_policy.sh"
    if ! has_selinux_devel && command -v podman >/dev/null 2>&1; then
        ensure_selinux_build_image || log_warn "Policy compile may be slow until: bash scripts/build_selinux_compile_image.sh"
    fi

    if [[ "${SKIP_EXPORT}" -eq 0 ]]; then
        export_avcs
    else
        [[ -s "${AVC_LOG}" ]] || { log_error "--skip-export but ${AVC_LOG} is empty"; exit 1; }
    fi

    generate_policy
    show_diff
    verify_avc_coverage || exit 1

    if [[ "${ENFORCE_CHECK}" -eq 1 ]]; then
        run_enforce_check || exit 1
    fi

    if [[ "${APPLY}" -eq 1 ]]; then
        promote_to_selinux
    else
        log_warn "Generated files in policy_out/ only. Re-run with --apply to copy into selinux/"
    fi

    assemble_pr_body

    if [[ "${OPEN_PR}" -eq 1 ]]; then
        open_pr
    else
        print_pr_steps
    fi
}

main "$@"
