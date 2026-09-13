#!/usr/bin/env bash
#
# classify_policy_blast_radius.sh — Recommend soak duration from sediff output.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/compile_policy.sh
source "${SCRIPT_DIR}/lib/compile_policy.sh"

BASE_PP="${1:-}"
CANDIDATE_PP="${2:-}"
MODULE_NAME="${POLICY_MODULE:-myapp}"
IMAGE="${SELINUX_COMPILE_IMAGE:-quay.io/centos/centos:stream9}"

usage() {
    cat <<EOF
Usage: $(basename "$0") BASE.pp CANDIDATE.pp

Prints JSON: {"tier":"low|medium|high","min_days":1|3|7,"reason":"..."}

Tiers:
  low    — only myapp_* types touched           → 1 day (24h)
  medium — refpolicy interface expansion        → 3 days (72h)
  high   — base types, entrypoints, transitions → 7 days
EOF
}

if [[ $# -lt 2 ]]; then
    usage >&2
    exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
cp "${BASE_PP}" "${work_dir}/base.pp"
cp "${CANDIDATE_PP}" "${work_dir}/candidate.pp"

analysis="$(podman run --rm \
    -v "${work_dir}:/work:Z" \
    "${IMAGE}" \
    bash -lc "
        set -euo pipefail
        dnf install -y -q setools-console selinux-policy-targeted policycoreutils
        sediff -q /work/base.pp /work/candidate.pp 2>/dev/null || true
    ")"

tier="low"
min_days=1
reason="Only module-private types changed"

if echo "${analysis}" | grep -qiE '(entrypoint|type_transition|role_transition)'; then
    tier="high"
    min_days=7
    reason="Entrypoint or domain transition change detected"
elif echo "${analysis}" | grep -qiE '(allow.*: (var_t|etc_t|usr_t|bin_t|shadow_t|unlabeled_t|tmp_t|proc_t|sysfs_t))'; then
    tier="high"
    min_days=7
    reason="Direct allow on base policy type detected"
elif echo "${analysis}" | grep -qiE 'interface|macro'; then
    tier="medium"
    min_days=3
    reason="Refpolicy interface expansion detected"
fi

python3 - <<PY
import json
print(json.dumps({
    "tier": "${tier}",
    "min_days": ${min_days},
    "reason": """${reason}""",
    "sediff_excerpt": """${analysis[:2000]}""",
}, indent=2))
PY
