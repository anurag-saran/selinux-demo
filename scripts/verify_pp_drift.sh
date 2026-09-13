#!/usr/bin/env bash
#
# verify_pp_drift.sh — Deprecated: compiled .pp is a CI artifact, not tracked in git.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_DIR="${1:-${SCRIPT_DIR}/../selinux}"
MODULE_NAME="${POLICY_MODULE:-myapp}"

echo "[INFO] ${MODULE_NAME}.pp is built in CI (compile-policy job) and not committed."
echo "[INFO] Run: bash scripts/compile_and_validate.sh ${POLICY_DIR}"
