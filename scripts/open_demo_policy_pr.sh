#!/usr/bin/env bash
#
# open_demo_policy_pr.sh — Optional paced-walkthrough PR (Act 4–5: admin review + CI).
#
# Frozen v1.1.1 → v1.1.2 review PR (base demo/policy-base-1.1.1).
# Current main is policy v1.1.3; do not treat this script as the live module bump.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

BASE_COMMIT="${DEMO_POLICY_BASE_COMMIT:-b97d255}"
BASE_BRANCH="${DEMO_POLICY_BASE_BRANCH:-demo/policy-base-1.1.1}"
HEAD_BRANCH="${DEMO_POLICY_HEAD_BRANCH:-policy/myapp-update}"
STAGING_HOST="${STAGING_HOST:-Podman FCOS VM (selinux-demo)}"
TEST_SUITE="${TEST_SUITE:-Integration tests — six HTTP probes on :8888/:8889}"

# Files that represent the myapp module submission (Act 4 checklist).
POLICY_PATHS=(
    selinux/myapp.te
    selinux/myapp.fc
    selinux/policy_version.txt
    selinux/myapp_ports.cil
)

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

Create/update branches and open a GitHub PR for SELinux policy admin review (demo Act 4).

Options:
  --push-only     Push branches only; do not run gh pr create
  --reuse-pr-body Use docs/examples/pr_body.example.md (skip assemble)
  -h, --help      Show help

Requires: git, network push access, GitHub CLI (gh) for --push-only off.

After open:
  https://github.com/$(git remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/](.+)(\.git)?#\1#')/pulls

EOF
}

PUSH_ONLY=0
REUSE_EXAMPLE_BODY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --push-only) PUSH_ONLY=1; shift ;;
        --reuse-pr-body) REUSE_EXAMPLE_BODY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

if ! git rev-parse --verify "${BASE_COMMIT}^{commit}" >/dev/null 2>&1; then
    log_error "Base commit not found: ${BASE_COMMIT}"
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    log_error "Working tree not clean — commit or stash changes first"
    exit 1
fi

MAIN_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || echo main)"
git fetch origin "${MAIN_BRANCH}" 2>/dev/null || true

log_info "Publishing base branch ${BASE_BRANCH} @ ${BASE_COMMIT} (policy v1.1.1 snapshot)"
git push -u origin "${BASE_COMMIT}:refs/heads/${BASE_BRANCH}"

log_info "Building head branch ${HEAD_BRANCH} with myapp policy from origin/${MAIN_BRANCH}"
git checkout -B "${HEAD_BRANCH}" "${BASE_COMMIT}"
git checkout "origin/${MAIN_BRANCH}" -- "${POLICY_PATHS[@]}"

if git diff --cached --quiet; then
    log_error "No policy changes vs base — nothing to commit"
    exit 1
fi

git commit -m "$(cat <<EOF
security(selinux): Update policy module for myapp

Workshop submission: v1.1.1 → v1.1.2 (FCOS init_t, ports CIL, log/exec types).
Generated path: deterministic policy + staging AVC export (see policy_out in demo).
EOF
)"

git push -u origin "${HEAD_BRANCH}"

PR_BODY="${PROJECT_ROOT}/policy_out/pr_body.md"
if [[ "${REUSE_EXAMPLE_BODY}" -eq 1 ]]; then
    PR_BODY="${PROJECT_ROOT}/docs/examples/pr_body.example.md"
    log_info "Using example PR body: ${PR_BODY}"
else
    mkdir -p "${PROJECT_ROOT}/policy_out"
    cp "${PROJECT_ROOT}/docs/examples/fixtures/skip_ai/avc.log" "${PROJECT_ROOT}/policy_out/avc.log"
    if [[ -f "${PROJECT_ROOT}/policy_out/pr_summary.md" ]]; then
        :
    elif [[ -f "${PROJECT_ROOT}/docs/examples/pr_summary.example.md" ]]; then
        awk 'BEGIN {delim=0} /^---$/ { delim++; next } delim >= 2' \
            "${PROJECT_ROOT}/docs/examples/pr_summary.example.md" > "${PROJECT_ROOT}/policy_out/pr_summary.md"
    else
        log_error "Missing pr_summary — run demo Act 3 or use --reuse-pr-body"
        exit 1
    fi
    export SELINUX_POLICY_DIFF_DOMAINS="myapp_t,myapp_backend_t"
    if ! bash "${SCRIPT_DIR}/assemble_pr_body.sh" \
        --staging-host "${STAGING_HOST}" \
        --test-suite "${TEST_SUITE}" \
        --candidate-dir "${PROJECT_ROOT}/selinux"; then
        log_warn "assemble_pr_body failed (Podman/sesearch?) — retry with --reuse-pr-body"
        exit 1
    fi
fi

if [[ "${PUSH_ONLY}" -eq 1 ]]; then
    log_info "Branches pushed. Open PR manually:"
    cat <<EOF

  gh pr create \\
    --base "${BASE_BRANCH}" \\
    --head "${HEAD_BRANCH}" \\
    --title "security(selinux): Update policy module for myapp" \\
    --body-file "${PR_BODY}" \\
    --label security --label selinux --label pending-admin-review

EOF
    exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
    log_error "GitHub CLI (gh) not found. Re-run with --push-only and create the PR in the browser:"
    echo "  Base: ${BASE_BRANCH}  ←  Head: ${HEAD_BRANCH}"
    exit 1
fi

EXISTING="$(gh pr list --head "${HEAD_BRANCH}" --base "${BASE_BRANCH}" --state open --json number -q '.[0].number' 2>/dev/null || true)"
if [[ -n "${EXISTING}" && "${EXISTING}" != "null" ]]; then
    log_info "Open PR already exists: #${EXISTING}"
    gh pr view "${EXISTING}" --web 2>/dev/null || gh pr view "${EXISTING}"
    exit 0
fi

gh pr create \
    --base "${BASE_BRANCH}" \
    --head "${HEAD_BRANCH}" \
    --title "security(selinux): Update policy module for myapp" \
    --body-file "${PR_BODY}" \
    --label security \
    --label selinux \
    --label pending-admin-review

log_info "PR opened — show in Act 4–5 (Checks tab = CI gates from selinux-policy-ci.yml)"
