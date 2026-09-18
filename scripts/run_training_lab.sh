#!/usr/bin/env bash
#
# run_training_lab.sh — Guided SELinux training lab (typewriter + explanations)
#
# Runs labs 1 → 6 verify → 2–5 → 7–9 from docs/training/SELINUX_TRAINING_LAB.md
# with Why/What text and simulated typing. Commands execute for real.
#
# Usage (from repo root on a SELinux Linux host, typically rhel-qa / rhel-dev):
#   bash scripts/run_training_lab.sh
#   bash scripts/run_training_lab.sh --auto       # no pauses between steps
#   bash scripts/run_training_lab.sh --no-type    # skip typewriter effect
#   bash scripts/run_training_lab.sh --short      # labs 1, 6, 7 only
#   bash scripts/run_training_lab.sh --lab4-demo  # Lab 4 chcon + restorecon exercise
#   bash scripts/run_training_lab.sh --include-lab10
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/training_lab_runner.sh
source "${SCRIPT_DIR}/lib/training_lab_runner.sh"
# shellcheck source=lib/integration_probes.sh
source "${SCRIPT_DIR}/lib/integration_probes.sh"

TLAB_SHORT=0
TLAB_LAB4_DEMO=0
TLAB_LAB10=0
TLAB_VM_PROJECT="${PROJECT_ROOT}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Runs the hands-on training lab with explanations and typed commands.
See docs/training/SELINUX_TRAINING_LAB.md for the full course.

Must run on a SELinux Linux host (rhel-qa). macOS has no SELinux —
see docs/admin/RHEL_TWO_HOST.md.

Options:
  --auto            No pauses (demo / recording)
  --no-type         Print commands instantly (no typewriter)
  --short           Labs 1, 6 verify, 7 only
  --lab4-demo       Lab 4: run chcon + restorecon exercise
  --include-lab10   Run optional Lab 10 (manifest export)
  -h, --help        Show help

Staging must be installed first: sudo bash scripts/setup_staging_env.sh
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto) TLAB_AUTO=1; shift ;;
        --no-type) TLAB_NO_TYPE=1; shift ;;
        --short) TLAB_SHORT=1; shift ;;
        --lab4-demo) TLAB_LAB4_DEMO=1; shift ;;
        --include-lab10) TLAB_LAB10=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ "$(uname -s)" == Darwin ]]; then
    echo "This lab needs a SELinux Linux host. On a Mac, follow docs/admin/RHEL_TWO_HOST.md, then SSH to rhel-qa (192.168.64.6) and run this script there." >&2
    exit 1
fi

if ! tlab_detect_vm; then
    echo "SELinux is not available on this host. Run on rhel-qa (see docs/admin/RHEL_TWO_HOST.md)." >&2
    exit 1
fi

tlab_ensure_staging_hint

echo -e "${TLAB_BOLD}SELinux PaC lab runner${TLAB_NC}"
echo -e "${TLAB_DIM}Commands run on this Linux host${TLAB_NC}"
tlab_pause

lab_1() {
    tlab_print_section "Lab 1 — Is SELinux on?"
    tlab_why "Every other step assumes the kernel is enforcing SELinux. If SELinux is off, labels and AVC logs mislead you."
    tlab_question "Is this machine actually running SELinux right now?"
    tlab_explain "getenforce asks the kernel for whole-system mode (Enforcing / Permissive / Disabled)."
    tlab_run_cmd "getenforce"
    tlab_pause
    tlab_explain "sestatus confirms SELinux is enabled in config, not just for this boot."
    tlab_run_cmd "sestatus | head -5"
    tlab_checkpoint "You should see Enforcing (or Permissive) — not Disabled."
    tlab_pause_lab
}

lab_6_verify() {
    tlab_print_section "Lab 6 — Verify demo staging"
    tlab_why "SELinux PaC needs Flask + backend under /opt/myapp, stub policy, and permissive myapp_t (or equivalent on FCOS)."
    tlab_question "Is the reference app running with the staging setup?"
    tlab_explain "Both systemd units must be active before Tier 6 curls."
    tlab_run_cmd "systemctl is-active myapp.service myapp-backend.service"
    tlab_pause
    tlab_explain "Health check on port 8888 inside this Linux environment (not your Mac)."
    tlab_run_cmd "curl -s http://127.0.0.1:8888/ | head -c 200; echo"
    echo -e "${TLAB_DIM}Note:${TLAB_NC} JSON may show process_context init_t while selinux.domain stays myapp_t until full policy transition; null bytes are stripped in app output."
    tlab_pause
    tlab_explain "Host should stay Enforcing; myapp_t should be permissive when semanage is available."
    tlab_run_cmd "getenforce"
    tlab_semanage_permissive_list
    tlab_checkpoint "Both services active; getenforce Enforcing; staging ready for label/curl labs."
    tlab_pause_lab
}

lab_2() {
    tlab_print_section "Lab 2 — Read file labels"
    tlab_why "Policy rules talk about types on files (myapp_exec_t, myapp_log_t), not Unix usernames."
    tlab_question "What type does policy assign to each path?"
    tlab_explain "ls -Z shows the SELinux context; focus on the third field (the type)."
    tlab_explain "Create the log file with save-log; on stub staging the log may stay var_log_t until full selinux/myapp.fc is installed (Lab 9 shows myapp_log_t in Git)."
    tlab_run_cmd "curl -sf -o /dev/null http://127.0.0.1:8888/save-log || true"
    tlab_run_cmd "ls -Z /opt/myapp/app.py"
    tlab_run_cmd "ls -Z /var/lib/myapp"
    tlab_run_cmd "ls -Z /var/log/myapp/data.log 2>/dev/null || ls -Z /var/log/myapp/"
    tlab_pause
    tlab_explain "matchpathcon shows what loaded policy expects for a path (from .fc rules)."
    tlab_run_cmd "matchpathcon /var/log/myapp/data.log 2>/dev/null || matchpathcon /var/log/myapp"
    tlab_checkpoint "App binary uses myapp_exec_t; stub log may be var_log_t — full policy + restorecon targets myapp_log_t (Lab 9)."
    tlab_pause_lab
}

lab_3() {
    tlab_print_section "Lab 3 — Read process labels"
    tlab_why "Running processes have a domain (type). Rules allow myapp_t to touch files — not the myapp user account."
    tlab_question "What domain is the Flask (and backend) process running in?"
    tlab_explain "On stub staging you may see init_t instead of myapp_t — stub policy still allows the demo."
    tlab_lab3_show_process_labels
    tlab_checkpoint "Process domain is not the same as file types on disk."
    tlab_pause_lab
}

lab_4() {
    tlab_print_section "Lab 4 — Policy on disk vs reality"
    tlab_why "Wrong on-disk labels cause denials even when .te in Git looks correct."
    tlab_question "Does the label on disk match what policy expects?"
    tlab_run_cmd "matchpathcon /var/log/myapp/data.log 2>/dev/null || true"
    tlab_run_cmd "ls -Z /var/log/myapp/data.log 2>/dev/null || true"
    if [[ "${TLAB_LAB4_DEMO}" -eq 1 ]]; then
        tlab_explain "chcon simulates a mislabel; restorecon fixes from policy without editing .te."
        tlab_run_cmd_sudo "chcon -t var_log_t /var/log/myapp/data.log"
        tlab_run_cmd "ls -Z /var/log/myapp/data.log"
        tlab_run_cmd_sudo "restorecon -v /var/log/myapp/data.log"
        tlab_run_cmd "ls -Z /var/log/myapp/data.log"
    else
        echo -e "${TLAB_DIM}(Skip chcon demo — re-run with --lab4-demo to break/fix a label.)${TLAB_NC}"
    fi
    tlab_checkpoint ".fc defines labels; restorecon applies them to disk."
    tlab_pause_lab
}

lab_5() {
    tlab_print_section "Lab 5 — Two-layer permissive (demo model)"
    tlab_why "Production keeps the OS Enforcing and only puts the app domain in log-only mode during soak."
    tlab_question "Is the host protected while the app can still run and log denials?"
    tlab_explain "getenforce is whole-system; semanage permissive -l is per-domain (when installed)."
    tlab_run_cmd "getenforce"
    tlab_semanage_permissive_list
    tlab_checkpoint "Enforcing globally; app domain permissive for evidence gathering."
    tlab_pause_lab
}

lab_7() {
    tlab_print_section "Lab 7 — Hit HTTP endpoints"
    INTEGRATION_UI=training
    INTEGRATION_AUTO="${TLAB_AUTO}"
    run_integration_probes
    tlab_pause_lab
}

lab_8() {
    tlab_print_section "Lab 8 — Find and read an AVC"
    tlab_why "AVC lines are the evidence policy authors use when adding allows."
    tlab_question "Who tried to do what to whom?"
    tlab_explain "auditd must be running for ausearch to show denials."
    tlab_run_cmd_sudo "systemctl status auditd --no-pager | head -3"
    tlab_run_cmd_sudo "ausearch -m avc -ts recent 2>/dev/null | tail -5 || echo '(no recent AVC lines — often normal after Lab 7)'"
    tlab_run_cmd_sudo "ausearch -m avc -ts recent 2>/dev/null | grep -E 'myapp|init_t' | tail -3 || true"
    tlab_lab8_show_sample_avc_if_needed
    tlab_checkpoint "You can read scontext, tcontext, and denied { … } on an AVC line (live or sample above)."
    tlab_pause_lab
}

lab_9() {
    tlab_print_section "Lab 9 — Map AVC to .te rule"
    tlab_why "Git selinux/myapp.te is what reviewers approve — connect logs to allow rules."
    tlab_question "Which rule in Git explains log access?"
    tlab_explain "grep the Type Enforcement file and file contexts for myapp_log (full module in Git; stub may still use var_log_t on disk)."
    tlab_run_cmd "cd ${TLAB_VM_PROJECT} && grep -n myapp_log_t selinux/myapp.te | head -10"
    tlab_run_cmd "cd ${TLAB_VM_PROJECT} && grep myapp_log selinux/myapp.fc"
    tlab_checkpoint "Given a write to myapp_log_t, you can point at an allow or macro in .te."
    tlab_pause_lab
}

lab_10() {
    tlab_print_section "Lab 10 — Export app AVCs (manifest) [optional]"
    tlab_why "This repo filters AVCs by manifest paths/domains before generation."
    tlab_question "How does policy_out/avc.log get built safely?"
    tlab_run_cmd "cd ${TLAB_VM_PROJECT} && python3 scripts/lib/app_manifest.py validate config/myapp.manifest.yml"
    tlab_run_cmd "cd ${TLAB_VM_PROJECT} && python3 scripts/lib/app_manifest.py paths-csv config/myapp.manifest.yml"
    tlab_checkpoint "Manifest drives path filters — not silent myapp defaults."
    tlab_pause_lab
}

lab_1
lab_6_verify

if [[ "${TLAB_SHORT}" -eq 1 ]]; then
    lab_7
    echo -e "${TLAB_GREEN}${TLAB_BOLD}Short path complete (Labs 1, 6, 7).${TLAB_NC}"
    echo "Next: docs/training/DEMO_GUIDE.md or re-run without --short for Labs 2–5, 8–9."
    echo "Presenter demo: bash scripts/demo_e2e_rhel_dev.sh"
    exit 0
fi

lab_2
lab_3
lab_4
lab_5
lab_7
lab_8
lab_9

if [[ "${TLAB_LAB10}" -eq 1 ]]; then
    lab_10
fi

echo
echo -e "${TLAB_GREEN}${TLAB_BOLD}Full training lab run complete.${TLAB_NC}"
echo "Finish checklist: docs/training/SELINUX_TRAINING_LAB.md"
echo "Next (optional paced walkthrough): bash scripts/demo_e2e_rhel_dev.sh"
echo "Policy PR from live generate: bash scripts/demo_open_generated_pr.sh  (Mac, after scp; needs gh auth login)"
echo
