#!/usr/bin/env bash
#
# run_e2e_tests.sh — Local end-to-end checks (macOS/Linux; Podman optional for compile).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
fail=0

log_ok() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; fail=1; }

# Optional Podman (policy compile on macOS)
if [[ -f "${HOME}/.local/share/selinux-demo/podman/env.sh" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.local/share/selinux-demo/podman/env.sh"
    podman machine start 2>/dev/null || true
    sleep 2
fi

log_ok "smoke_test.py"
SMOKE_SKIP_FLASK=1 python3 scripts/smoke_test.py --no-require-backend || log_fail "smoke_test.py"

log_ok "validate_rpm_ops_parity"
bash scripts/validate_rpm_ops_parity.sh || log_fail "rpm parity"

log_ok "stage_skip_ai_fixture"
bash scripts/lib/stage_skip_ai_fixture.sh || log_fail "skip_ai fixture"

mkdir -p policy_out
cp docs/examples/fixtures/skip_ai/avc.log policy_out/avc.log

log_ok "dev_generate_policy (--engine deterministic --skip-export)"
if bash scripts/dev_generate_policy.sh --skip-export --engine deterministic; then
    log_ok "dev_generate deterministic pipeline"
else
    log_fail "dev_generate_policy deterministic"
fi

if [[ -f policy_out/myapp.pp ]]; then
    log_ok "policy_out/myapp.pp built"
else
    log_fail "compile did not produce policy_out/myapp.pp (start Podman: podman machine start)"
fi

if bash scripts/validate_forbidden_patterns.sh selinux; then
    log_ok "selinux forbidden patterns"
else
    log_fail "selinux forbidden patterns"
fi

echo ""
if [[ "${fail}" -eq 0 ]]; then
    echo -e "${GREEN}All local E2E checks passed.${NC}"
    exit 0
fi
echo -e "${RED}One or more E2E checks failed.${NC}"
exit 1
