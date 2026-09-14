#!/usr/bin/env bash
#
# policy_module_diff.sh — Diff application-domain allows between two module sources.
#
# sediff(1) requires a binary kernel policy, not standalone .pp module packages
# (see: "Invalid policy ... A binary policy must be specified"). We install each
# compiled module into the container policy store (semodule -i), dump sorted
# sesearch --allow lines for app domains, then diff with comm.
#
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${LIB_DIR}/../.." && pwd)"
# shellcheck source=lib/compile_policy.sh
source "${LIB_DIR}/compile_policy.sh"

APP_NAME="${POLICY_APP:-myapp}"
DOMAINS="${SELINUX_POLICY_DIFF_DOMAINS:-myapp_t,myapp_backend_t}"
BASE_DIR=""
CAND_DIR=""
OUTPUT=""
FROM_MERGE_BASE=0
FORMAT="markdown"
work=""
run_dir=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --app-name NAME           Module name (default: myapp)
  --base-dir PATH           Directory with \${APP_NAME}.{te,fc} for merge-base side
  --cand-dir PATH           Candidate directory (default: selinux/)
  --from-merge-base         Extract base from git merge-base vs origin/main
  --domains CSV             Source domains for sesearch (default: myapp_t,myapp_backend_t)
  --output PATH             Write diff text (required)
  --format markdown|text    Output format (default: markdown)
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-name) APP_NAME="$2"; shift 2 ;;
        --base-dir) BASE_DIR="$2"; shift 2 ;;
        --cand-dir) CAND_DIR="$2"; shift 2 ;;
        --from-merge-base) FROM_MERGE_BASE=1; shift ;;
        --domains) DOMAINS="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --format) FORMAT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

[[ -n "${OUTPUT}" ]] || { echo "policy_module_diff: --output is required" >&2; exit 1; }
CAND_DIR="${CAND_DIR:-${PROJECT_ROOT}/selinux}"

resolve_merge_base_ref() {
    local ref=""
    ref="$(git -C "${PROJECT_ROOT}" merge-base HEAD origin/main 2>/dev/null || true)"
    [[ -n "${ref}" ]] || ref="$(git -C "${PROJECT_ROOT}" merge-base HEAD origin/master 2>/dev/null || true)"
    [[ -n "${ref}" ]] || ref="$(git -C "${PROJECT_ROOT}" rev-parse HEAD~1 2>/dev/null || true)"
    [[ -n "${ref}" ]] || { echo "policy_module_diff: cannot resolve merge-base ref" >&2; exit 1; }
    echo "${ref}"
}

if [[ "${FROM_MERGE_BASE}" -eq 1 ]]; then
    base_ref="$(resolve_merge_base_ref)"
    work="$(mktemp -d)"
    git -C "${PROJECT_ROOT}" show "${base_ref}:selinux/${APP_NAME}.te" > "${work}/${APP_NAME}.te"
    git -C "${PROJECT_ROOT}" show "${base_ref}:selinux/${APP_NAME}.fc" > "${work}/${APP_NAME}.fc"
    BASE_DIR="${work}"
fi

cleanup() {
    rm -rf "${work}" "${run_dir}"
}
trap cleanup EXIT

[[ -n "${BASE_DIR}" && -f "${BASE_DIR}/${APP_NAME}.te" && -f "${BASE_DIR}/${APP_NAME}.fc" ]] || {
    echo "policy_module_diff: missing base ${APP_NAME}.{te,fc} in ${BASE_DIR:-<unset>}" >&2
    exit 1
}
[[ -f "${CAND_DIR}/${APP_NAME}.te" && -f "${CAND_DIR}/${APP_NAME}.fc" ]] || {
    echo "policy_module_diff: missing candidate ${APP_NAME}.{te,fc} in ${CAND_DIR}" >&2
    exit 1
}

run_dir="$(mktemp -d)"
mkdir -p "${run_dir}/base" "${run_dir}/cand"
cp "${LIB_DIR}/policy_module_sesearch.sh" "${run_dir}/"
cp "${BASE_DIR}/${APP_NAME}.te" "${BASE_DIR}/${APP_NAME}.fc" "${run_dir}/base/"
cp "${CAND_DIR}/${APP_NAME}.te" "${CAND_DIR}/${APP_NAME}.fc" "${run_dir}/cand/"

compile_policy_module "${run_dir}/base" "${APP_NAME}" "${run_dir}/base/${APP_NAME}.pp" || {
    echo "policy_module_diff: failed to compile merge-base ${APP_NAME} module" >&2
    exit 1
}
compile_policy_module "${run_dir}/cand" "${APP_NAME}" "${run_dir}/cand/${APP_NAME}.pp" || {
    echo "policy_module_diff: failed to compile candidate ${APP_NAME} module" >&2
    exit 1
}

run_container() {
    local log="${run_dir}/podman.log"
    local pod_ec=0
    ensure_selinux_build_image || true
    if selinux_build_image_ready; then
        run_selinux_container "${run_dir}" \
            -e "APP_NAME=${APP_NAME}" \
            -e "DOMAINS=${DOMAINS}" \
            bash -lc '
set -euo pipefail
source /work/policy_module_sesearch.sh
base_rules="/work/base_rules.txt"
cand_rules="/work/cand_rules.txt"
: > "${base_rules}"
: > "${cand_rules}"
kern="/var/lib/selinux/targeted/active/policy.kern"
dump_side() {
    local pp="$1" dest="$2"
    semodule -r "${APP_NAME}" 2>/dev/null || true
    semodule -i "${pp}"
    IFS="," read -r -a doms <<< "${DOMAINS}"
    for dom in "${doms[@]}"; do
        dom="${dom// /}"
        [[ -n "${dom}" ]] || continue
        append_domain_allows "${kern}" "${dom}" "${dest}"
    done
}
dump_side "/work/base/${APP_NAME}.pp" "${base_rules}"
dump_side "/work/cand/${APP_NAME}.pp" "${cand_rules}"
semodule -r "${APP_NAME}" 2>/dev/null || true
sort -u -o "${base_rules}" "${base_rules}"
sort -u -o "${cand_rules}" "${cand_rules}"
comm -23 "${cand_rules}" "${base_rules}" > /work/added.txt
comm -13 "${cand_rules}" "${base_rules}" > /work/removed.txt
' >"${log}" 2>&1 || pod_ec=$?
    else
        podman run --rm \
            -v "${run_dir}:/work:Z" \
            -e "APP_NAME=${APP_NAME}" \
            -e "DOMAINS=${DOMAINS}" \
            "${SELINUX_COMPILE_IMAGE}" \
            bash -lc '
set -euo pipefail
source /work/policy_module_sesearch.sh
dnf install -y -q setools-console policycoreutils selinux-policy-targeted selinux-policy-devel checkpolicy
base_rules="/work/base_rules.txt"
cand_rules="/work/cand_rules.txt"
: > "${base_rules}"
: > "${cand_rules}"
kern="/var/lib/selinux/targeted/active/policy.kern"
dump_side() {
    local pp="$1" dest="$2"
    semodule -r "${APP_NAME}" 2>/dev/null || true
    semodule -i "${pp}"
    IFS="," read -r -a doms <<< "${DOMAINS}"
    for dom in "${doms[@]}"; do
        dom="${dom// /}"
        [[ -n "${dom}" ]] || continue
        append_domain_allows "${kern}" "${dom}" "${dest}"
    done
}
dump_side "/work/base/${APP_NAME}.pp" "${base_rules}"
dump_side "/work/cand/${APP_NAME}.pp" "${cand_rules}"
semodule -r "${APP_NAME}" 2>/dev/null || true
sort -u -o "${base_rules}" "${base_rules}"
sort -u -o "${cand_rules}" "${cand_rules}"
comm -23 "${cand_rules}" "${base_rules}" > /work/added.txt
comm -13 "${cand_rules}" "${base_rules}" > /work/removed.txt
' >"${log}" 2>&1 || pod_ec=$?
    fi
    if [[ -f "${run_dir}/added.txt" && -f "${run_dir}/removed.txt" ]]; then
        return 0
    fi
    tail -40 "${log}" >&2
    return "${pod_ec:-1}"
}

if has_selinux_devel && command -v sesearch >/dev/null 2>&1; then
    # shellcheck source=lib/policy_module_sesearch.sh
    source "${LIB_DIR}/policy_module_sesearch.sh"
    base_rules="${run_dir}/base_rules.txt"
    cand_rules="${run_dir}/cand_rules.txt"
    : > "${base_rules}"
    : > "${cand_rules}"
    kern="/var/lib/selinux/targeted/active/policy.kern"
    dump_side_native() {
        local pp="$1" dest="$2"
        semodule -r "${APP_NAME}" 2>/dev/null || true
        semodule -i "${pp}"
        IFS=',' read -r -a doms <<< "${DOMAINS}"
        for dom in "${doms[@]}"; do
            dom="${dom// /}"
            [[ -n "${dom}" ]] || continue
            append_domain_allows "${kern}" "${dom}" "${dest}"
        done
    }
    dump_side_native "${run_dir}/base/${APP_NAME}.pp" "${base_rules}"
    dump_side_native "${run_dir}/cand/${APP_NAME}.pp" "${cand_rules}"
    semodule -r "${APP_NAME}" 2>/dev/null || true
    sort -u -o "${base_rules}" "${base_rules}"
    sort -u -o "${cand_rules}" "${cand_rules}"
    comm -23 "${cand_rules}" "${base_rules}" > "${run_dir}/added.txt"
    comm -13 "${cand_rules}" "${base_rules}" > "${run_dir}/removed.txt"
elif command -v podman >/dev/null 2>&1; then
    run_container || {
        echo "policy_module_diff: podman sesearch diff step failed" >&2
        exit 1
    }
else
    echo "policy_module_diff: need podman or host selinux-policy-targeted + setools" >&2
    exit 1
fi

[[ -f "${run_dir}/added.txt" && -f "${run_dir}/removed.txt" ]] || {
    echo "policy_module_diff: sesearch diff step did not produce output files" >&2
    exit 1
}

added="$(cat "${run_dir}/added.txt")"
removed="$(cat "${run_dir}/removed.txt")"

if [[ "${FORMAT}" == "text" ]]; then
    {
        echo "Rules ADDED:"
        [[ -n "${added}" ]] && echo "${added}" || echo "(none)"
        echo ""
        echo "Rules REMOVED:"
        [[ -n "${removed}" ]] && echo "${removed}" || echo "(none)"
    } > "${OUTPUT}"
else
    if [[ -z "${added}" && -z "${removed}" ]]; then
        {
            echo "### Policy access delta (sesearch)"
            echo ""
            echo "No access change for application domains (${DOMAINS})."
        } > "${OUTPUT}"
    else
        {
            echo "### Policy access delta (sesearch)"
            echo ""
            echo "**Rules ADDED:**"
            echo '```'
            [[ -n "${added}" ]] && echo "${added}" || echo "(none)"
            echo '```'
            echo ""
            echo "**Rules REMOVED:**"
            echo '```'
            [[ -n "${removed}" ]] && echo "${removed}" || echo "(none)"
            echo '```'
        } > "${OUTPUT}"
    fi
fi
