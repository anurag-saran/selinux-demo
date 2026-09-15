#!/usr/bin/env bash
#
# policy_module_diff.sh — Diff application-domain allows between two module sources.
#
# sediff(1) requires a binary kernel policy, not standalone .pp module packages
# (see: "Invalid policy ... A binary policy must be specified"). We compile each
# side from .te/.fc, install with semodule -i in a fresh container run per side,
# dump sorted sesearch --allow lines for app domains, then comm (option b).
#
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${LIB_DIR}/../.." && pwd)"
# shellcheck source=compile_policy.sh
source "${LIB_DIR}/compile_policy.sh"

APP_NAME="${POLICY_APP:-myapp}"
DOMAINS="${SELINUX_POLICY_DIFF_DOMAINS:-}"
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
  --domains CSV             Source domains for sesearch (default: \${APP_NAME}_t,...)
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

if [[ -z "${DOMAINS}" && -f "${PROJECT_ROOT}/config/${APP_NAME}.manifest.yml" ]]; then
    DOMAINS="$(python3 - "${PROJECT_ROOT}/config/${APP_NAME}.manifest.yml" <<'PY'
import sys, yaml
m = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
doms = {m["domain"]}
for svc in (m.get("services") or {}).values():
    if isinstance(svc, dict) and svc.get("domain"):
        doms.add(svc["domain"])
print(",".join(sorted(doms)))
PY
)"
fi
DOMAINS="${DOMAINS:-${APP_NAME}_t,${APP_NAME}_backend_t}"

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
    if ! git -C "${PROJECT_ROOT}" show "${base_ref}:selinux/${APP_NAME}.te" > "${work}/${APP_NAME}.te" 2>/dev/null; then
        echo "policy_module_diff: no selinux/${APP_NAME}.te at merge-base ${base_ref}" >&2
        exit 1
    fi
    if ! git -C "${PROJECT_ROOT}" show "${base_ref}:selinux/${APP_NAME}.fc" > "${work}/${APP_NAME}.fc" 2>/dev/null; then
        echo "policy_module_diff: no selinux/${APP_NAME}.fc at merge-base ${base_ref}" >&2
        exit 1
    fi
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
cp "${LIB_DIR}/policy_module_sesearch.sh" "${LIB_DIR}/policy_module_diff_side.sh" "${run_dir}/"
cp "${BASE_DIR}/${APP_NAME}.te" "${BASE_DIR}/${APP_NAME}.fc" "${run_dir}/base/"
cp "${CAND_DIR}/${APP_NAME}.te" "${CAND_DIR}/${APP_NAME}.fc" "${run_dir}/cand/"
if [[ -f "${BASE_DIR}/${APP_NAME}.if" ]]; then
    cp "${BASE_DIR}/${APP_NAME}.if" "${run_dir}/base/"
fi
if [[ -f "${CAND_DIR}/${APP_NAME}.if" ]]; then
    cp "${CAND_DIR}/${APP_NAME}.if" "${run_dir}/cand/"
fi

compile_policy_module "${run_dir}/base" "${APP_NAME}" "${run_dir}/base/${APP_NAME}.pp" || {
    echo "policy_module_diff: failed to compile merge-base ${APP_NAME} module" >&2
    exit 1
}
compile_policy_module "${run_dir}/cand" "${APP_NAME}" "${run_dir}/cand/${APP_NAME}.pp" || {
    echo "policy_module_diff: failed to compile candidate ${APP_NAME} module" >&2
    exit 1
}

collect_side_container() {
    local label="$1"
    local pp_path="$2"
    local out_name="${label}_rules.txt"
    local log="${run_dir}/${label}.log"
    if ! run_selinux_container "${run_dir}" \
        -e "DIFF_DOMAINS=${DOMAINS}" \
        -e "DIFF_APP=${APP_NAME}" \
        bash -lc "bash /work/policy_module_diff_side.sh ${pp_path} /work/${out_name} \"\${DIFF_DOMAINS}\" \"\${DIFF_APP}\"" \
        >"${log}" 2>&1; then
        echo "policy_module_diff: ${label} sesearch collect failed" >&2
        tail -30 "${log}" >&2
        return 1
    fi
    [[ -f "${run_dir}/${out_name}" ]] || {
        echo "policy_module_diff: missing ${run_dir}/${out_name}" >&2
        return 1
    }
}

collect_side_native() {
    local label="$1"
    local pp="$2"
    local out="${run_dir}/${label}_rules.txt"
    # shellcheck source=policy_module_diff_side.sh
    bash "${LIB_DIR}/policy_module_diff_side.sh" "${pp}" "${out}" "${DOMAINS}" "${APP_NAME}"
}

if has_selinux_devel && command -v sesearch >/dev/null 2>&1; then
    collect_side_native base "${run_dir}/base/${APP_NAME}.pp"
    collect_side_native cand "${run_dir}/cand/${APP_NAME}.pp"
elif command -v podman >/dev/null 2>&1; then
    collect_side_container base "/work/base/${APP_NAME}.pp"
    collect_side_container cand "/work/cand/${APP_NAME}.pp"
else
    echo "policy_module_diff: need podman or host selinux-policy-targeted + setools" >&2
    exit 1
fi

comm -23 "${run_dir}/cand_rules.txt" "${run_dir}/base_rules.txt" > "${run_dir}/added.txt"
comm -13 "${run_dir}/cand_rules.txt" "${run_dir}/base_rules.txt" > "${run_dir}/removed.txt"

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
