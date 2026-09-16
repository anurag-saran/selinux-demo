#!/usr/bin/env bash
#
# demo_e2e_rhel_dev.sh — Typewriter talk track for the DEV VM (192.168.64.6).
#
# Run ON rhel-dev, not on the Mac:
#   ssh ansible@192.168.64.6
#   cd ~/selinux-demo
#   bash scripts/demo_e2e_rhel_dev.sh --part app        # before Mac canary
#   bash scripts/demo_e2e_rhel_dev.sh --part generate   # after Mac canary
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib/e2e_demo.sh" ]]; then
    # shellcheck source=lib/training_lab_runner.sh
    source "${SCRIPT_DIR}/lib/training_lab_runner.sh"
    # shellcheck source=lib/e2e_demo.sh
    source "${SCRIPT_DIR}/lib/e2e_demo.sh"
elif [[ -f "${HOME}/selinux-demo/scripts/lib/e2e_demo.sh" ]]; then
    # shellcheck source=lib/training_lab_runner.sh
    source "${HOME}/selinux-demo/scripts/lib/training_lab_runner.sh"
    # shellcheck source=lib/e2e_demo.sh
    source "${HOME}/selinux-demo/scripts/lib/e2e_demo.sh"
    SCRIPT_DIR="${HOME}/selinux-demo/scripts"
else
    echo "Cannot find scripts/lib/e2e_demo.sh. On this VM: cd ~/selinux-demo && git pull" >&2
    exit 1
fi

PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TLAB_PS1='[ansible@rhel-dev selinux-demo]$'
REPO_URL="${REPO_URL:-https://github.com/anurag-saran/selinux-demo.git}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Presenter script for the DEV VM (${DEV_HOST}). Do not run this on the Mac.

  --part app       Install packages + demo website (before Mac canary)
  --part generate  sudo AVC → policy (after Mac canary)
  --part all       Both, with a pause in the middle (default)

$(e2e_usage_common)
EOF
}

e2e_parse_args "$@"
e2e_require_rhel "the DEV VM (${DEV_HOST})"

part_app() {
    e2e_banner "DEV VM — practice box (${DEV_HOST})"
    tlab_why "SELinux runs HERE. The Mac is only the remote control. If the prompt does not say rhel-dev, stop."
    e2e_run "hostname"
    e2e_run "whoami"
    tlab_pause

    tlab_print_section "Part 2 — Install the demo app"
    tlab_explain "These packages give us git, Python, and the SELinux tools: ausearch (read denials), sesearch (ask if a rule already exists), semanage (labels / permissive domain)."
    e2e_run "sudo dnf install -y git python3 policycoreutils policycoreutils-python-utils setools-console audit selinux-policy-devel"
    tlab_checkpoint "Complete! or already installed."
    tlab_pause

    if [[ ! -d "${HOME}/selinux-demo/.git" ]]; then
        tlab_explain "This is a SECOND copy of the project. The Mac still has its own tree. Ansible will look here, not under /Users/..."
        e2e_run "git clone ${REPO_URL} ${HOME}/selinux-demo"
    else
        tlab_explain "The project is already on this VM. We skip git clone (do not clone onto prod later)."
        e2e_run "ls ${HOME}/selinux-demo/config/myapp.manifest.yml"
    fi
    tlab_pause

    cd "${HOME}/selinux-demo"
    if systemctl is-active --quiet myapp.service 2>/dev/null; then
        tlab_explain "myapp.service is already running — we skip the long install so the demo stays moving."
        e2e_run "systemctl is-active myapp.service myapp-backend.service"
    else
        tlab_explain "setup_staging_env.sh installs a tiny website at /opt/myapp and starts two systemd services."
        e2e_run "sudo bash scripts/setup_staging_env.sh"
    fi
    tlab_pause

    tlab_explain "doctor checks SELinux mode plus the app paths. Then we prove the site answers."
    e2e_run "sudo bash scripts/selinux_pac_adopt.sh doctor"
    e2e_run "getenforce"
    e2e_run "systemctl is-active myapp.service myapp-backend.service"
    e2e_run "curl -sf -o /dev/null http://127.0.0.1:8888/ && echo 'HTTP 200 /'"
    tlab_checkpoint "Enforcing; both services active; curl succeeded. Go back to the Mac window for compile + canary."
}

part_generate() {
    e2e_banner "DEV VM — turn denials into rules"
    tlab_why "After canary, this box has been logging ‘SELinux said no’ without blocking. We read that log and propose allow rules."
    cd "${HOME}/selinux-demo"
    tlab_explain "sudo is required: the audit log is root-only, and policy_out/ is often owned by root from the earlier install. Do not SSH to yourself — you are already on rhel-dev."
    e2e_run "sudo bash scripts/dev_generate_policy.sh --apply"
    tlab_checkpoint "New allow lines, or nothing new. Then go back to the Mac for lab enforce (Part 5)."
}

case "${E2E_PART}" in
    app) part_app ;;
    generate) part_generate ;;
    all)
        part_app
        e2e_handoff "Leave this window open. On the Mac run compile + canary, then come back here.
Press Enter when Mac canary has failed=0."
        part_generate
        ;;
    *)
        echo "Unknown --part ${E2E_PART} (use app, generate, or all)" >&2
        exit 2
        ;;
esac

echo
echo -e "${TLAB_BOLD}End of the DEV talk track.${TLAB_NC} Do not type exit until the Mac script asks you to."
echo
