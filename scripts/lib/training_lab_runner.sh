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
TLAB_VM_PROJECT="${VM_PROJECT:-/home/core/selinux-pac}"

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
    local ps1="${TLAB_PS1:-\$}"
    if [[ "${TLAB_NO_TYPE}" -eq 1 ]]; then
        echo -e "${TLAB_GREEN}${ps1}${TLAB_NC} ${prompt}"
        return 0
    fi
    echo -n -e "${TLAB_GREEN}${ps1}${TLAB_NC} "
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
        echo -e "${TLAB_YELLOW}FCOS / minimal image:${TLAB_NC} no semanage — permissive domains are declared inside the loaded module (stub uses permissive myapp_t in policy source)."
        echo "The host stays Enforcing; only that domain logs denials instead of blocking (when the process runs as myapp_t)."
        tlab_run_shell "semodule -l 2>/dev/null | grep -E '^myapp' || echo '(myapp module loaded — see semodule -l | grep myapp)'"
    fi
}

tlab_lab3_show_process_labels() {
    local script
    script='found=0
if out=$(ps -eZ 2>/dev/null | grep -E "app\.py|backend_stub|/opt/myapp" | head -5); then
  printf "%s\n" "$out"
  found=1
fi
if [[ "$found" -eq 0 ]]; then
  for u in myapp.service myapp-backend.service; do
    pid=$(systemctl show -p MainPID --value "$u" 2>/dev/null || true)
    if [[ -n "$pid" && "$pid" != "0" ]]; then
      echo "=== ${u} MainPID=${pid} ==="
      ps -o label=,pid=,args= -p "$pid" 2>/dev/null || true
      found=1
    fi
  done
fi
if [[ "$found" -eq 0 ]]; then
  echo "WARNING: no myapp process lines found — check: systemctl status myapp.service myapp-backend.service"
  exit 0
fi'
    tlab_type_line "ps / systemctl MainPID (fallback when cmdline does not match app.py)"
    local out
    out="$(tlab_run_shell "${script}" 2>&1)" || true
    echo "${out}"
    if grep -q '^WARNING:' <<<"${out}"; then
        echo -e "${TLAB_YELLOW}Could not show process labels automatically — fix systemd units before Lab 7.${TLAB_NC}"
    fi
}

tlab_lab8_show_sample_avc_if_needed() {
    local count_script count sample_file line
    count_script='sudo ausearch -m avc -ts recent 2>/dev/null | grep -cE "myapp|init_t" || true'
    count="$(tlab_run_shell "${count_script}" 2>/dev/null | tr -d "[:space:]")"
    [[ -n "${count}" && "${count}" != "0" ]] && return 0

    echo -e "${TLAB_YELLOW}No live myapp/init_t AVCs (normal on stub/permissive after Lab 7). Sample line to decode:${TLAB_NC}"
    sample_file="${TLAB_VM_PROJECT}/docs/examples/fixtures/skip_ai/avc.log"
    if tlab_run_shell "test -s $(printf '%q' "${sample_file}")"; then
        line="$(tlab_run_shell "grep -E 'avc:  denied' $(printf '%q' "${sample_file}") | head -1")"
    else
        line='type=AVC msg=audit(1710000000.000:100): avc:  denied  { write } for  pid=1234 comm="python3" name="data.log" scontext=system_u:system_r:myapp_t:s0 tcontext=system_u:object_r:myapp_var_lib_t:s0 tclass=file permissive=1'
    fi
    echo "${line}"
    echo -e "${TLAB_DIM}Read: scontext = source domain (who), tcontext = target type (what), denied { … } = missing permission.${TLAB_NC}"
}
