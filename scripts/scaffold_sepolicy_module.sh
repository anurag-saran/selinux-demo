#!/usr/bin/env bash
#
# scaffold_sepolicy_module.sh — Run sepolicy-generate for a new app module (.te/.if/.fc).
#
# Usage: bash scripts/scaffold_sepolicy_module.sh <module_name> <domain_type>
# Example: bash scripts/scaffold_sepolicy_module.sh payments payments_t
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODULE="${1:?module name (e.g. payments)}"
DOMAIN="${2:?domain type (e.g. payments_t)}"
OUT_DIR="${PROJECT_ROOT}/selinux/${MODULE}"

if ! command -v sepolicy-generate >/dev/null 2>&1; then
    echo "[ERROR] sepolicy-generate not found. Install policycoreutils-devel on RHEL/CentOS Stream." >&2
    exit 1
fi

mkdir -p "${OUT_DIR}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

(
    cd "${work}"
    sepolicy-generate -a "${DOMAIN}" -t unconfined_t
    for ext in te if fc; do
        dest="${OUT_DIR}/${MODULE}.${ext}"
        if [[ -f "${dest}" ]]; then
            echo "[INFO] Skipping ${dest} (already exists — remove manually to replace)" >&2
            continue
        fi
        found=""
        for base in "${MODULE}" "${DOMAIN%_t}" "${DOMAIN}"; do
            src="${work}/${base}.${ext}"
            if [[ -f "${src}" ]]; then
                found="${src}"
                break
            fi
        done
        if [[ -n "${found}" ]]; then
            cp "${found}" "${dest}"
            echo "[INFO] Wrote ${dest}" >&2
        else
            echo "[WARN] No ${ext} from sepolicy-generate in ${work}" >&2
        fi
    done
)

echo "[INFO] Review ${OUT_DIR}/${MODULE}.{te,if,fc} then compile:" >&2
echo "  POLICY_MODULE=${MODULE} SELINUX_DOMAIN=${DOMAIN} bash scripts/compile_and_validate.sh ${OUT_DIR}" >&2
