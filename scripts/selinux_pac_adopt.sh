#!/usr/bin/env bash
#
# selinux_pac_adopt.sh — Onboard an app (doctor, manifest hint, Ansible next steps).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME=""
MANIFEST=""

usage() {
    cat <<EOF
Usage: $(basename "$0") <subcommand> [args]

Subcommands:
  doctor              Check host prerequisites (SELinux, audit, tools)
  init APP_NAME       Print manifest + Ansible onboarding steps

Options (init):
  --manifest PATH     Manifest path (default: config/APP.manifest.yml)
EOF
}

doctor() {
    echo "=== selinux-pac doctor ==="
    getenforce 2>/dev/null || echo "WARN: getenforce unavailable"
    command -v ausearch >/dev/null && echo "OK ausearch" || echo "WARN: ausearch missing"
    command -v sesearch >/dev/null && echo "OK sesearch" || echo "WARN: sesearch missing (install setools-console for net-new soak)"
    command -v ansible-playbook >/dev/null && echo "OK ansible-playbook" || echo "INFO: ansible-playbook on controller only"
    [[ -x "${SCRIPT_DIR}/monitor_avc.sh" ]] && echo "OK ops scripts in repo" || true
}

init_app() {
    MANIFEST="${MANIFEST:-${PROJECT_ROOT}/config/${APP_NAME}.manifest.yml}"
    echo "=== selinux-pac init: ${APP_NAME} ==="
    echo "1. Copy manifest: cp config/payments.manifest.example.yml ${MANIFEST}"
    echo "2. Scaffold policy: bash scripts/scaffold_sepolicy_module.sh ${APP_NAME} ${APP_NAME}_t"
    echo "3. Validate: bash scripts/validate_app_manifest.sh ${MANIFEST}"
    echo "4. Compile: POLICY_MODULE=${APP_NAME} bash scripts/compile_and_validate.sh selinux/${APP_NAME}"
    echo "5. Canary (controller):"
    cat <<EOF
ansible-playbook -i ansible/inventory.example.yml ansible/deploy_canary.yml \\
  -e app_name=${APP_NAME} \\
  -e "policy_pp_src=\$(pwd)/selinux/${APP_NAME}/${APP_NAME}.pp" \\
  -e "policy_artifact_dir=\$(pwd)" \\
  -e "app_manifest_path=\$(pwd)/${MANIFEST#${PROJECT_ROOT}/}" \\
  -e selinux_ops_from_package=false \\
  -e selinux_ops_dir=\$(pwd)/scripts \\
  -e selinux_pac_install_demo_units=false
EOF
    echo "6. Soak: ansible-playbook -i ansible/inventory.example.yml ansible/soak_monitor.yml"
    echo "7. Enforce: ansible-playbook -i ansible/inventory.example.yml ansible/enforce_production.yml"
    echo "Docs: docs/ANSIBLE_OPERATIONS.md docs/ADOPTION_CHECKLIST.md"
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

SUB="$1"
shift

case "${SUB}" in
    doctor) doctor ;;
    init)
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --manifest) MANIFEST="$2"; shift 2 ;;
                -h|--help) usage; exit 0 ;;
                *)
                    if [[ -z "${APP_NAME}" ]]; then
                        APP_NAME="$1"
                        shift
                    else
                        echo "Unexpected arg: $1" >&2
                        exit 1
                    fi
                    ;;
            esac
        done
        [[ -n "${APP_NAME}" ]] || { echo "init requires APP_NAME" >&2; exit 1; }
        init_app
        ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown subcommand: ${SUB}" >&2; usage; exit 1 ;;
esac
