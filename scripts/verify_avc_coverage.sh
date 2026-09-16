#!/usr/bin/env bash
#
# verify_avc_coverage.sh — Wrapper for cli/verify_avc_coverage.py
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="${POLICY_APP:-myapp}"
AVC_LOG="${1:-${PROJECT_ROOT}/policy_out/avc.log}"
TE="${2:-${PROJECT_ROOT}/policy_out/${APP_NAME}.te}"
MANIFEST="${3:-${PROJECT_ROOT}/config/${APP_NAME}.manifest.yml}"

exec python3 "${PROJECT_ROOT}/cli/verify_avc_coverage.py" \
    --avc-log "${AVC_LOG}" \
    --te "${TE}" \
    --manifest "${MANIFEST}"
