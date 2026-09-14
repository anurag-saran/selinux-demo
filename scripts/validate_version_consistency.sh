#!/usr/bin/env bash
#
# validate_version_consistency.sh — Fail if policy version sources disagree.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="${POLICY_APP:-myapp}"
# shellcheck source=lib/version.sh
source "${SCRIPT_DIR}/lib/version.sh"

VERSION_FILE="${PROJECT_ROOT}/selinux/policy_version.txt"
TE_FILE="${PROJECT_ROOT}/selinux/${APP_NAME}.te"
SPEC_FILE="${PROJECT_ROOT}/packaging/myapp-selinux.spec"

canonical="$(policy_version "${VERSION_FILE}")"
from_te="$(policy_module_version_from_te "${TE_FILE}" "${APP_NAME}")"

if [[ "${canonical}" != "${from_te}" ]]; then
    echo "validate_version_consistency: policy_version.txt (${canonical}) != policy_module in ${TE_FILE} (${from_te})" >&2
    exit 1
fi

if ! grep -qE '^Version:[[:space:]]*%{modver}[[:space:]]*$' "${SPEC_FILE}"; then
    echo "validate_version_consistency: ${SPEC_FILE} must use 'Version: %{modver}' (set via packaging/build_rpms.sh)" >&2
    exit 1
fi

if ! grep -qF 'modver ${VERSION}' "${PROJECT_ROOT}/packaging/build_rpms.sh"; then
    echo "validate_version_consistency: packaging/build_rpms.sh must pass --define modver from policy_version.txt" >&2
    exit 1
fi

echo "validate_version_consistency: OK (${canonical})"
