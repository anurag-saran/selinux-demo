#!/usr/bin/env bash
#
# assemble_pr_body.sh — Merge PR template + pr_summary + AVC excerpt into pr_body.md
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE="${PROJECT_ROOT}/.github/PULL_REQUEST_TEMPLATE/selinux_policy_review.md"
PR_SUMMARY="${PROJECT_ROOT}/policy_out/pr_summary.md"
AVC_LOG="${PROJECT_ROOT}/policy_out/avc.log"
OUTPUT="${PROJECT_ROOT}/policy_out/pr_body.md"
APP_NAME="${POLICY_APP:-myapp}"
STAGING_HOST="${STAGING_HOST:-<!-- fill in staging host -->}"
TEST_SUITE="${TEST_SUITE:-Integration tests (curl endpoints)}"
AVC_SAMPLE_LINES="${AVC_SAMPLE_LINES:-8}"
VERSION_FILE="${PROJECT_ROOT}/selinux/policy_version.txt"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Assemble policy_out/pr_body.md from PR template, pr_summary.md, and avc.log.

Options:
  --app-name NAME       Module name (default: myapp)
  --template PATH       PR template file
  --pr-summary PATH     AI summary file
  --avc-log PATH        AVC export file
  --output PATH         Output file
  --staging-host TEXT   Staging environment label
  --test-suite TEXT     Test suite description
  -h, --help            Show help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-name) APP_NAME="$2"; shift 2 ;;
        --template) TEMPLATE="$2"; shift 2 ;;
        --pr-summary) PR_SUMMARY="$2"; shift 2 ;;
        --avc-log) AVC_LOG="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --staging-host) STAGING_HOST="$2"; shift 2 ;;
        --test-suite) TEST_SUITE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

[[ -f "${TEMPLATE}" ]] || { echo "Missing template: ${TEMPLATE}" >&2; exit 1; }
[[ -f "${PR_SUMMARY}" ]] || { echo "Missing pr_summary: ${PR_SUMMARY}" >&2; exit 1; }

policy_version="unknown"
if [[ -f "${VERSION_FILE}" ]]; then
    policy_version="$(tr -d '[:space:]' < "${VERSION_FILE}")"
fi

avc_line_count=0
avc_excerpt="(no AVC log found — run export before assemble)"
if [[ -f "${AVC_LOG}" ]] && [[ -s "${AVC_LOG}" ]]; then
    avc_line_count="$(wc -l < "${AVC_LOG}" | tr -d ' ')"
    avc_excerpt="$(grep -E '^type=AVC|avc: denied' "${AVC_LOG}" | head -n "${AVC_SAMPLE_LINES}" || true)"
    [[ -n "${avc_excerpt}" ]] || avc_excerpt="(AVC log present but no matching lines)"
fi

BASE_PP="${PROJECT_ROOT}/selinux/myapp.pp"
NEW_PP="${PROJECT_ROOT}/policy_out/${APP_NAME}.pp"

sediff_file="$(mktemp)"
if [[ -f "${BASE_PP}" && -f "${NEW_PP}" ]] && command -v sediff >/dev/null 2>&1; then
    sediff "${BASE_PP}" "${NEW_PP}" > "${sediff_file}" 2>/dev/null || echo "(sediff produced no output)" > "${sediff_file}"
else
    echo "(sediff unavailable — install setools-console and provide base/new .pp)" > "${sediff_file}"
fi

tmp="$(mktemp)"
# Strip YAML frontmatter (--- ... ---) for body-file usage
awk 'BEGIN {delim=0} /^---$/ { delim++; next } delim >= 2' "${TEMPLATE}" > "${tmp}"

python3 - "${tmp}" "${OUTPUT}" "${policy_version}" "${STAGING_HOST}" "${TEST_SUITE}" "${avc_line_count}" "${PR_SUMMARY}" "${AVC_LOG}" "${sediff_file}" <<'PY'
import pathlib
import sys

template_path, output_path, policy_version, staging_host, test_suite, avc_count, pr_summary_path, avc_log_path, sediff_path = sys.argv[1:10]
sediff_section = pathlib.Path(sediff_path).read_text(encoding="utf-8", errors="replace").strip()
body = pathlib.Path(template_path).read_text(encoding="utf-8")
pr_summary = pathlib.Path(pr_summary_path).read_text(encoding="utf-8").strip()
avc_log = pathlib.Path(avc_log_path)
if avc_log.is_file() and avc_log.stat().st_size:
    lines = [
        ln for ln in avc_log.read_text(encoding="utf-8", errors="replace").splitlines()
        if ln.startswith("type=AVC") or "avc: denied" in ln
    ]
    avc_excerpt = "\n".join(lines[:8]) or "(AVC log present but no matching lines)"
else:
    avc_excerpt = "(no AVC log found — run export before assemble)"

replacements = {
    "<!-- AUTO:POLICY_VERSION -->": policy_version,
    "<!-- AUTO:STAGING_HOST -->": staging_host,
    "<!-- AUTO:TEST_SUITE -->": test_suite,
    "<!-- AUTO:AVC_LINE_COUNT -->": str(avc_count),
    "<!-- AUTO:PR_SUMMARY -->": pr_summary + "\n",
    "<!-- AUTO:AVC_EXCERPT -->": avc_excerpt,
    "<!-- AUTO:SEDIFF -->": "### Policy diff (sediff)\n\n```\n" + sediff_section + "\n```\n",
}
for marker, value in replacements.items():
    body = body.replace(marker, value)

pathlib.Path(output_path).write_text(body.rstrip() + "\n", encoding="utf-8")
PY

rm -f "${tmp}" "${sediff_file}"
echo "Wrote ${OUTPUT}"
