#!/usr/bin/env bash
#
# validate_policy_semantics.sh — sesearch assertions on compiled policy module.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
POLICY_DIR="${1:-${PROJECT_ROOT}/selinux}"
MODULE_NAME="${POLICY_MODULE:-myapp}"
DOMAIN="${SELINUX_DOMAIN:-myapp_t}"

# shellcheck source=lib/compile_policy.sh
source "${SCRIPT_DIR}/lib/compile_policy.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

pp="${POLICY_DIR}/${MODULE_NAME}.pp"
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

compile_policy_module "${POLICY_DIR}" "${MODULE_NAME}" "${pp}"
cp "${pp}" "${work_dir}/${MODULE_NAME}.pp"

if ! command -v podman >/dev/null 2>&1; then
    log_error "podman required — semantic checks must not load policy on the host runner"
    exit 1
fi

run_selinux_container "${work_dir}" bash -lc "
    set -euo pipefail
    semodule -i /work/${MODULE_NAME}.pp
    fail=0
    if sesearch --direct -A -s ${DOMAIN} -t shadow_t -p read 2>/dev/null | grep -q .; then fail=1; fi
    if sesearch --direct -A -s ${DOMAIN} -t unlabeled_t 2>/dev/null | grep -q .; then fail=1; fi
    if sesearch --direct -A -s ${DOMAIN} -c file -p entrypoint 2>/dev/null \
        | awk '{print \$3}' | cut -d: -f1 | grep -qv '^${MODULE_NAME}_'; then fail=1; fi
    semodule -r ${MODULE_NAME} 2>/dev/null || true
    if [[ \"\${fail}\" -ne 0 ]]; then
        echo 'Semantic policy check failed' >&2
        exit 1
    fi
"

log_info "Semantic policy checks passed for ${DOMAIN}"
