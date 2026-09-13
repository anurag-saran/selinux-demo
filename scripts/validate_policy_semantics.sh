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

if [[ ! -f "${pp}" ]]; then
    compile_policy_module "${POLICY_DIR}" "${MODULE_NAME}" "${pp}"
fi

cp "${pp}" "${work_dir}/${MODULE_NAME}.pp"

run_semantic_checks() {
    local image="${SELINUX_COMPILE_IMAGE:-quay.io/centos/centos:stream9}"
    podman run --rm \
        -v "${work_dir}:/work:Z" \
        "${image}" \
        bash -lc "
            set -euo pipefail
            dnf install -y -q policycoreutils setools-console selinux-policy-targeted
            semodule -i /work/${MODULE_NAME}.pp
            fail=0
            sesearch -A -s ${DOMAIN} -t shadow_t -p read >/dev/null 2>&1 && fail=1
            sesearch -A -s ${DOMAIN} -t unlabeled_t >/dev/null 2>&1 && fail=1
            sesearch -A -s ${DOMAIN} -c file -p entrypoint 2>/dev/null | grep -v '${MODULE_NAME}_' | grep -q . && fail=1
            if [[ \"\${fail}\" -ne 0 ]]; then
                echo 'Semantic policy check failed' >&2
                exit 1
            fi
            semodule -r ${MODULE_NAME} 2>/dev/null || true
        "
}

if command -v sesearch >/dev/null 2>&1 && command -v semodule >/dev/null 2>&1; then
    semodule -i "${pp}"
    fail=0
    sesearch -A -s "${DOMAIN}" -t shadow_t -p read >/dev/null 2>&1 && fail=1
    sesearch -A -s "${DOMAIN}" -t unlabeled_t >/dev/null 2>&1 && fail=1
    if sesearch -A -s "${DOMAIN}" -c file -p entrypoint 2>/dev/null | grep -v "${MODULE_NAME}_" | grep -q .; then
        fail=1
    fi
    semodule -r "${MODULE_NAME}" 2>/dev/null || true
    [[ "${fail}" -eq 0 ]] || { log_error "Semantic policy checks failed on host"; exit 1; }
elif command -v podman >/dev/null 2>&1; then
    run_semantic_checks
else
    log_error "Need sesearch+semodule on host or podman for semantic validation"
    exit 1
fi

log_info "Semantic policy checks passed for ${DOMAIN}"
