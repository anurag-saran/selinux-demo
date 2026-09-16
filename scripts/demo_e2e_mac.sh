#!/usr/bin/env bash
#
# demo_e2e_mac.sh — Typewriter talk track for the Mac (Ansible controller).
#
# Run in a Mac Terminal at repo root. Pause when it says “Switch windows”
# and run the matching script on rhel-dev / rhel-prod.
#
#   bash scripts/demo_e2e_mac.sh
#   bash scripts/demo_e2e_mac.sh --dry-run
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/training_lab_runner.sh
source "${SCRIPT_DIR}/lib/training_lab_runner.sh"
# shellcheck source=lib/e2e_demo.sh
source "${SCRIPT_DIR}/lib/e2e_demo.sh"

TLAB_PS1='asaran@mac selinux-pac %'

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Presenter script for THIS Mac. It types explanations and the controller
commands from docs/admin/RHEL_TWO_HOST.md (ping, compile, canary, enforce, RPMs).

$(e2e_usage_common)

Other windows (do not run those scripts here):
  ssh ansible@${DEV_HOST}   →  bash ~/selinux-pac/scripts/demo_e2e_rhel_dev.sh
  ssh ansible@${PROD_HOST}  →  bash ~/e2e-demo/demo_e2e_rhel_prod.sh
EOF
}

e2e_parse_args "$@"
e2e_require_mac
cd "${PROJECT_ROOT}"

e2e_banner "MAC — the remote control (no SELinux on this laptop)"
tlab_why "macOS cannot enforce SELinux. This window talks to two RHEL VMs over SSH: dev ${DEV_HOST} and prod ${PROD_HOST}."
tlab_explain "Look at the prompt. If it says rhel-dev or rhel-prod, you are in the wrong window."
tlab_pause

tlab_print_section "Part 1 — Can the Mac reach the VMs?"
tlab_explain "write saves the two IP addresses into gitignored inventory files on this laptop."
e2e_run "bash scripts/setup_rhel_hosts.sh write --dev-host ${DEV_HOST} --prod-host ${PROD_HOST} --user ansible"
tlab_checkpoint "You should see Wrote …inventory.dev.yml and …inventory.production.yml."
tlab_pause

tlab_explain "ping is Ansible asking: can I SSH and run Python on both boxes?"
e2e_run "bash scripts/setup_rhel_hosts.sh ping"
tlab_checkpoint "SUCCESS / pong for rhel-dev and rhel-prod. Ignore the python3.9 warning."
tlab_pause

tlab_explain "doctor checks SELinux is Enforcing and that ausearch (the no-log) and sesearch (is this already allowed?) exist on each VM."
e2e_run "bash scripts/setup_rhel_hosts.sh doctor"
tlab_checkpoint "Each host prints Enforcing, then paths to ausearch and sesearch."
tlab_pause

tlab_explain "Copy the presenter scripts onto both VMs so the other two windows have the same talk track (prod gets a tiny folder — no git clone)."
e2e_run "ssh ansible@${DEV_HOST} 'if test -d ~/selinux-demo && ! test -d ~/selinux-pac; then mv ~/selinux-demo ~/selinux-pac; fi; if test -d ~/selinux-pac; then git -C ~/selinux-pac pull --ff-only || true; else git clone https://github.com/anurag-saran/selinux-pac.git ~/selinux-pac; fi'"
e2e_run "scp scripts/demo_e2e_rhel_dev.sh ansible@${DEV_HOST}:~/selinux-pac/scripts/"
e2e_run "scp scripts/lib/e2e_demo.sh scripts/lib/training_lab_runner.sh ansible@${DEV_HOST}:~/selinux-pac/scripts/lib/"
e2e_run "ssh ansible@${PROD_HOST} 'mkdir -p ~/e2e-demo/lib'"
e2e_run "scp scripts/demo_e2e_rhel_prod.sh ansible@${PROD_HOST}:~/e2e-demo/"
e2e_run "scp scripts/lib/e2e_demo.sh scripts/lib/training_lab_runner.sh ansible@${PROD_HOST}:~/e2e-demo/lib/"
tlab_pause

tlab_explain "bootstrap only PRINTS the next SSH steps. It does not install the app. We follow the real steps in the other windows."
e2e_run "bash scripts/setup_rhel_hosts.sh bootstrap"
tlab_pause

e2e_handoff "On the DEV VM window run:
  bash ~/selinux-pac/scripts/demo_e2e_rhel_dev.sh --part app
Press Enter here when the demo app is up (myapp.service is active)."

tlab_print_section "Part 3 — Compile rules on the Mac, canary on the VM"
tlab_explain "A Mac cannot compile SELinux itself. This script uses a small Linux container and writes selinux/myapp.pp here."
e2e_run "bash scripts/compile_and_validate.sh selinux"
e2e_run "ls -l selinux/myapp.pp"
tlab_pause

tlab_explain "Canary: Ansible copies that .pp to ${DEV_HOST}, loads it, and puts ONLY the demo app in log-but-do-not-block mode. The whole OS stays Enforcing."
e2e_run "ansible-playbook -i ansible/inventory.dev.yml ansible/deploy_canary.yml"
tlab_checkpoint "failed=0. Recent myapp_t events should be 0 raw / 0 net-new."
tlab_pause

e2e_handoff "On the DEV VM window run:
  bash ~/selinux-pac/scripts/demo_e2e_rhel_dev.sh --part generate
That reads the audit log (needs sudo) and proposes new allow rules.
Press Enter here when it finishes."

tlab_print_section "Part 5 — Lab enforce on DEV only"
tlab_explain "Dev inventory waits 0 days so we can lock down in a demo. Do not copy soak_min_days: 0 onto prod."
e2e_run "ansible-playbook -i ansible/inventory.dev.yml ansible/enforce_production.yml -e change_ticket=LAB"
tlab_checkpoint "failed=0. Host getenforce is still Enforcing; myapp_t is no longer permissive."
tlab_pause

tlab_print_section "Part 6 — Build RPMs on the Mac, copy to prod"
tlab_explain "Production must not git clone this repo. We ship installer files (RPMs), like a .pkg on a Mac."
e2e_run "bash packaging/build_rpms.sh"
e2e_run "ls dist/*.rpm 2>/dev/null || echo '(no dist/*.rpm yet — compile image / rpmbuild needed; skip scp or copy from an earlier build)'"
tlab_pause

if [[ "${E2E_DRY}" -eq 1 ]] || compgen -G "${PROJECT_ROOT}/dist/*.rpm" >/dev/null; then
    tlab_explain "scp copies the two RPMs into the prod user’s home directory."
    e2e_run "scp dist/selinux-policy-ops-*.rpm dist/myapp-selinux-*.rpm ansible@${PROD_HOST}:~/"
else
    tlab_why "No RPMs in dist/. In a customer shop CI publishes them. For this demo, skip scp or build with the compile image (docs/admin/COMPILE_IMAGE.md)."
fi

e2e_handoff "On the PROD VM window run:
  bash ~/e2e-demo/demo_e2e_rhel_prod.sh
Press Enter here when rpm -q selinux-policy-ops myapp-selinux succeeds."

tlab_print_section "Part 6d — Canary and soak on PROD (from the Mac)"
tlab_explain "Same canary idea, but inventory.production.yml talks to ${PROD_HOST} and uses RPMs, not a git checkout."
e2e_run "ansible-playbook -i ansible/inventory.production.yml ansible/deploy_canary.yml --limit canary"
tlab_pause

tlab_explain "soak_monitor: any NEW denials that the installed rules do not already allow?"
e2e_run "ansible-playbook -i ansible/inventory.production.yml ansible/soak_monitor.yml --limit canary"
tlab_pause

tlab_explain "soak_status is read-only: how many days since canary? Prod wants 7."
e2e_run "ansible-playbook -i ansible/inventory.production.yml ansible/soak_status.yml --limit canary"
tlab_pause

tlab_explain "Enforce on prod MUST fail until seven days have passed. That is the product, not a bug."
e2e_run_expect_fail "ansible-playbook -i ansible/inventory.production.yml ansible/enforce_production.yml -e change_ticket=CHG123"
tlab_checkpoint "You already locked down the DEV VM in Part 5. Prod waits."

echo
echo -e "${TLAB_BOLD}End of the Mac talk track.${TLAB_NC} Full script: docs/admin/RHEL_TWO_HOST.md"
echo
