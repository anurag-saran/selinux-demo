#!/usr/bin/env bash
# training_lab_runner.sh — helpers for run_training_lab.sh (source only)
set -euo pipefail

TLAB_RED='\033[0;31m'
TLAB_GREEN='\033[0;32m'
TLAB_YELLOW='\033[1;33m'
TLAB_CYAN='\033[0;36m'
TLAB_BOLD='\033[1m'
TLAB_DIM='\033[2m'
TLAB_NC='\033[0m'

TLAB_TYPE_DELAY="${TLAB_TYPE_DELAY:-0.02}"
TLAB_NO_TYPE=0
TLAB_AUTO=0
TLAB_USE_VM=0
TLAB_VM_PROJECT="${VM_PROJECT:-/home/core/selinux-demo}"

tlab_print_section() {
    echo
    echo -e "${TLAB_BOLD}${TLAB_CYAN}════════════════════════════════════════════════════════════${TLAB_NC}"
    echo -e "${TLAB_BOLD}${TLAB_CYAN}  $*${TLAB_NC}"
    echo -e "${TLAB_BOLD}${TLAB_CYAN}════════════════════════════════════════════════════════════${TLAB_NC}"
    echo
}

tlab_why() {
    echo -e "${TLAB_YELLOW}Why:${TLAB_NC} $*"
    echo
}

tlab_question() {
    echo -e "${TLAB_DIM}Question:${TLAB_NC} $*"
    echo
}

tlab_explain() {
    echo -e "${TLAB_DIM}What this does:${TLAB_NC} $*"
    echo
}

tlab_checkpoint() {
    echo -e "${TLAB_GREEN}Checkpoint:${TLAB_NC} $*"
    echo
}

tlab_pause() {
    if [[ "${TLAB_AUTO}" -eq 1 ]]; then
        return 0
    fi
    read -r -p "$(echo -e "${TLAB_DIM}Press Enter for the next step…${TLAB_NC} ")" _
}

tlab_pause_lab() {
    if [[ "${TLAB_AUTO}" -eq 1 ]]; then
        return 0
    fi
    echo
    read -r -p "$(echo -e "${TLAB_BOLD}Press Enter to start the next lab…${TLAB_NC} ")" _
}

tlab_type_line() {
    local prompt="$1"
    if [[ "${TLAB_NO_TYPE}" -eq 1 ]]; then
        echo -e "${TLAB_GREEN}\$${TLAB_NC} ${prompt}"
        return 0
    fi
    echo -n -e "${TLAB_GREEN}\$${TLAB_NC} "
    local i c
    for ((i = 0; i < ${#prompt}; i++)); do
        c="${prompt:i:1}"
        echo -n "${c}"
        sleep "${TLAB_TYPE_DELAY}"
    done
    echo
}

tlab_run_shell() {
    local script="$1"
    if [[ "${TLAB_USE_VM}" -eq 1 ]]; then
        podman machine ssh -- "bash -lc $(printf '%q' "${script}")"
    else
        bash -lc "${script}"
    fi
}

tlab_run_cmd() {
    local cmd="$1"
    tlab_type_line "${cmd}"
    tlab_run_shell "${cmd}"
}

tlab_run_cmd_sudo() {
    local cmd="$1"
    tlab_type_line "sudo ${cmd#sudo }"
    if [[ "${TLAB_USE_VM}" -eq 1 ]]; then
        podman machine ssh -- "sudo bash -lc $(printf '%q' "${cmd}")"
    else
        sudo bash -lc "${cmd}"
    fi
}

tlab_detect_vm() {
    if [[ "${TLAB_USE_VM}" -eq 1 ]]; then
        return 0
    fi
    if ! command -v getenforce >/dev/null 2>&1; then
        return 1
    fi
    local mode
    mode="$(getenforce 2>/dev/null || true)"
    [[ "${mode}" != "Disabled" ]]
}

tlab_ensure_staging_hint() {
    if ! tlab_run_shell "systemctl is-active myapp.service >/dev/null 2>&1"; then
        echo -e "${TLAB_RED}myapp.service is not active.${TLAB_NC}"
        echo "On macOS (repo root): bash scripts/run_on_podman_vm.sh setup"
        echo "On Linux (repo root): sudo bash scripts/setup_staging_env.sh"
        exit 1
    fi
}

tlab_semanage_permissive_list() {
    if tlab_run_shell "command -v semanage >/dev/null 2>&1"; then
        tlab_run_cmd_sudo "semanage permissive -l" || true
    else
        echo -e "${TLAB_YELLOW}(semanage not installed on this VM — stub module declares permissive myapp_t in policy.)${TLAB_NC}"
        tlab_run_shell "grep -E '^permissive myapp_t|^allow init_t' ${TLAB_VM_PROJECT}/selinux/stub/myapp.te 2>/dev/null | head -5 || true"
    fi
}
