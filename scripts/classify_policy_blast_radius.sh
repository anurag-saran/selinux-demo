#!/usr/bin/env bash
#
# classify_policy_blast_radius.sh — Recommend soak duration from policy module delta.
#
# sediff(1) does not accept standalone .pp module packages on EL9 (same as
# policy_module_diff.sh). We install each module with semodule -i, diff sorted
# sesearch --allow and sesearch -T output, and classify added rule lines.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/compile_policy.sh
source "${SCRIPT_DIR}/lib/compile_policy.sh"

BASE_INPUT="${1:-}"
CANDIDATE_INPUT="${2:-}"
MODULE_NAME="${POLICY_MODULE:-myapp}"
IMAGE="${SELINUX_BUILD_IMAGE:-selinux-demo/selinux-build:stream9}"
FALLBACK_IMAGE="${SELINUX_COMPILE_IMAGE:-quay.io/centos/centos:stream9}"
CLASSIFY_PY="${SCRIPT_DIR}/lib/blast_radius_classify.py"
COLLECT_SH="${SCRIPT_DIR}/lib/blast_radius_collect.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") BASE.{pp,te} CANDIDATE.{pp,te}

Prints JSON: {"tier":"low|medium|high","min_days":1|3|7,"reason":"...","sediff_excerpt":"..."}

Tiers:
  low    — added allows only on myapp_* types           → 1 day
  medium — refpolicy expansion (non-myapp, non-base)    → 3 days
  high   — base types, entrypoint, transitions          → 7 days

On analysis failure, returns tier high / min_days 7 (fail-closed).
EOF
}

fail_closed_json() {
    local reason="$1"
    local excerpt="${2:-}"
    BLAST_FAIL_REASON="${reason}" BLAST_FAIL_EXCERPT="${excerpt}" python3 - <<'PY'
import json, os
print(json.dumps({
    "tier": "high",
    "min_days": 7,
    "reason": os.environ["BLAST_FAIL_REASON"],
    "sediff_excerpt": os.environ.get("BLAST_FAIL_EXCERPT", ""),
    "fail_closed": True,
}, indent=2))
PY
}

if [[ $# -lt 2 ]]; then
    usage >&2
    exit 1
fi

[[ -f "${BASE_INPUT}" && -f "${CANDIDATE_INPUT}" ]] || {
    echo "classify_policy_blast_radius: missing input file(s)" >&2
    fail_closed_json "Base or candidate policy input not found"
    exit 0
}

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
cp "${COLLECT_SH}" "${work_dir}/blast_radius_collect.sh"

resolve_pp() {
    local input="$1"
    local out_pp="$2"
    if [[ "${input}" == *.te ]]; then
        local dir base
        dir="$(cd "$(dirname "${input}")" && pwd)"
        base="$(basename "${input}" .te)"
        [[ -f "${dir}/${base}.fc" ]] || {
            echo "classify_policy_blast_radius: missing ${dir}/${base}.fc for ${input}" >&2
            return 1
        }
        compile_policy_module "${dir}" "${base}" "${out_pp}"
    else
        cp "${input}" "${out_pp}"
    fi
}

compile_log="${work_dir}/compile.log"
: > "${compile_log}"

if ! resolve_pp "${BASE_INPUT}" "${work_dir}/base.pp" >>"${compile_log}" 2>&1; then
    fail_closed_json "Failed to compile or read base policy"
    exit 0
fi
if ! resolve_pp "${CANDIDATE_INPUT}" "${work_dir}/candidate.pp" >>"${compile_log}" 2>&1; then
    fail_closed_json "Failed to compile or read candidate policy"
    exit 0
fi

if [[ "${CLASSIFY_SKIP_PODMAN:-0}" == "1" ]]; then
    fail_closed_json "Classification skipped (CLASSIFY_SKIP_PODMAN) — conservative soak"
    exit 0
fi

if ! command -v podman >/dev/null 2>&1; then
    fail_closed_json "podman required for blast-radius classification"
    exit 0
fi

collect_log="${work_dir}/collect.log"
ensure_selinux_build_image || true
if selinux_build_image_ready; then
    if ! run_selinux_container "${work_dir}" \
        -e "BLAST_RADIUS_MODULE=${MODULE_NAME}" \
        bash -lc 'set -euo pipefail; bash /work/blast_radius_collect.sh /work/base.pp /work/candidate.pp /work/out' \
        >"${collect_log}" 2>&1; then
        excerpt="$(tail -40 "${collect_log}")"
        fail_closed_json "Policy rule diff failed — conservative soak" "${excerpt}"
        exit 0
    fi
elif ! podman run --rm \
    -v "${work_dir}:/work:Z" \
    -e "BLAST_RADIUS_MODULE=${MODULE_NAME}" \
    "${FALLBACK_IMAGE}" \
    bash -lc '
        set -euo pipefail
        dnf install -y -q setools-console selinux-policy-targeted policycoreutils
        bash /work/blast_radius_collect.sh /work/base.pp /work/candidate.pp /work/out
    ' >"${collect_log}" 2>&1; then
    excerpt="$(tail -40 "${collect_log}")"
    fail_closed_json "Policy rule diff failed — conservative soak" "${excerpt}"
    exit 0
fi

[[ -f "${work_dir}/out/added_all.txt" ]] || {
    fail_closed_json "Missing added rule set after collection"
    exit 0
}

python3 "${CLASSIFY_PY}" "${work_dir}/out/added_all.txt"
