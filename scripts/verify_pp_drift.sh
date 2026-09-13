#!/usr/bin/env bash
#
# verify_pp_drift.sh — Fail if committed .pp differs from .te/.fc rebuild.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_DIR="${1:-${SCRIPT_DIR}/../selinux}"
MODULE_NAME="${POLICY_MODULE:-myapp}"

# shellcheck source=lib/compile_policy.sh
source "${SCRIPT_DIR}/lib/compile_policy.sh"

verify_pp_matches_sources "${POLICY_DIR}" "${MODULE_NAME}"
