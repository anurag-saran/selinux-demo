#!/usr/bin/env bash
#
# demo_open_generated_pr.sh — Open a GitHub PR from live generated selinux/ sources.
#
# Run on the Mac after scp of myapp.te / myapp.fc / policy_version.txt (and
# optional policy_out/pr_body.md) from rhel-dev. Unlike open_demo_policy_pr.sh,
# this is not a frozen 1.1.1 → 1.1.2 snapshot.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

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

Open a GitHub PR from live generated selinux/myapp.te, myapp.fc, and
policy_version.txt (copied from rhel-dev). Not the frozen open_demo_policy_pr.sh.

Options:
  -h, --help     Show this help
  --push-only    Commit and push the branch; do not run gh pr create

Environment:
  DEMO_POLICY_BRANCH     Branch name (default: policy/myapp-from-avc-<timestamp>)
  DEMO_POLICY_BASE       PR base (default: main)
  DEMO_POLICY_PR_TITLE   PR title
  DEMO_POLICY_PUSH       Set to 0 to commit locally only
EOF
}

PUSH_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --push-only) PUSH_ONLY=1; shift ;;
        *) log_error "Unknown option: $1"; usage; exit 2 ;;
    esac
done

VERSION="$(tr -d '[:space:]' < selinux/policy_version.txt 2>/dev/null || echo unknown)"
STAMP="$(date +%Y%m%d%H%M%S)"
BRANCH="${DEMO_POLICY_BRANCH:-policy/myapp-from-avc-${STAMP}}"
BASE_BRANCH="${DEMO_POLICY_BASE:-main}"
TITLE="${DEMO_POLICY_PR_TITLE:-security(selinux): myapp ${VERSION} from rhel-dev AVCs}"
PR_BODY="${PROJECT_ROOT}/policy_out/pr_body.md"

if [[ ! -f selinux/myapp.te || ! -f selinux/myapp.fc || ! -f selinux/policy_version.txt ]]; then
    log_error "Missing selinux/myapp.te, myapp.fc, or policy_version.txt — scp them from rhel-dev first"
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    log_error "git not found"
    exit 1
fi

if [[ ! -f "${PR_BODY}" ]]; then
    mkdir -p "${PROJECT_ROOT}/policy_out"
    cat >"${PR_BODY}" <<EOF
## Summary

Generated \`myapp\` SELinux policy on **rhel-dev** from AVC denials (types-only domain seed → deterministic generator).

- Module version: **${VERSION}**
- Sources: \`selinux/myapp.te\`, \`selinux/myapp.fc\`, \`selinux/policy_version.txt\`

## Admin checklist

- [ ] CODEOWNERS review
- [ ] CI \`forbidden-patterns\` (generator already ran the same check — should pass)
- [ ] Canary on staging, then soak / enforce with a change ticket

Label: \`pending-admin-review\`
EOF
    log_info "Wrote ${PR_BODY} (no assembled body was copied from rhel-dev)"
fi

log_info "Creating branch ${BRANCH} from HEAD (base ${BASE_BRANCH})"
git checkout -B "${BRANCH}"

git add selinux/myapp.te selinux/myapp.fc selinux/policy_version.txt
if git diff --cached --quiet; then
    log_warn "No policy diff vs HEAD — nothing to commit. If the PR should exist already, show it in the browser."
    if command -v gh >/dev/null 2>&1; then
        gh pr list --head "${BRANCH}" --state open || true
    fi
    exit 0
fi

git commit -m "$(cat <<EOF
security(selinux): generate myapp ${VERSION} from rhel-dev AVCs

Types-only domain seed plus ausearch → deterministic_gen --apply on rhel-dev.
EOF
)"

if [[ "${DEMO_POLICY_PUSH:-1}" != "1" ]]; then
    log_info "DEMO_POLICY_PUSH=0 — commit is local only"
    exit 0
fi

git push -u origin "HEAD:refs/heads/${BRANCH}"

if [[ "${PUSH_ONLY}" -eq 1 ]]; then
    log_info "Branch pushed. Open a PR with:"
    echo "  gh pr create --base ${BASE_BRANCH} --head ${BRANCH} --title $(printf '%q' "${TITLE}") --body-file ${PR_BODY}"
    exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
    log_warn "GitHub CLI (gh) not found. Open a PR in the browser:"
    echo "  Base: ${BASE_BRANCH}  Head: ${BRANCH}"
    echo "  gh pr create --base ${BASE_BRANCH} --head ${BRANCH} --title $(printf '%q' "${TITLE}") --body-file ${PR_BODY}"
    exit 0
fi

EXISTING="$(gh pr list --head "${BRANCH}" --base "${BASE_BRANCH}" --state open --json number -q '.[0].number' 2>/dev/null || true)"
if [[ -n "${EXISTING}" && "${EXISTING}" != "null" ]]; then
    log_info "Open PR already exists: #${EXISTING}"
    gh pr view "${EXISTING}" || true
    exit 0
fi

if gh pr create \
    --base "${BASE_BRANCH}" \
    --head "${BRANCH}" \
    --title "${TITLE}" \
    --body-file "${PR_BODY}" \
    --label security \
    --label selinux \
    --label pending-admin-review; then
    log_info "PR opened for admin review (CODEOWNERS + pending-admin-review)"
    exit 0
fi

log_warn "Create with labels failed (labels may be missing). Retrying without labels."
gh pr create \
    --base "${BASE_BRANCH}" \
    --head "${BRANCH}" \
    --title "${TITLE}" \
    --body-file "${PR_BODY}"
log_info "PR opened (no labels)"
