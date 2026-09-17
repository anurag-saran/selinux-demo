#!/usr/bin/env bash
#
# demo_e2e_mac.sh — Typewriter talk track for the Mac (Ansible controller).
#
# Two-act lab: types-only seed → generate → PR (CI best-practices) → prod
# canary/soak (app up, AVC file clean) → talk-only enforce (soak complete) →
# /feature-spool 500 → emergency rollback → generate on rhel-dev → second PR →
# recanary prod.
#
#   bash scripts/demo_e2e_mac.sh
#   bash scripts/demo_e2e_mac.sh --dry-run
#   bash scripts/demo_e2e_mac.sh --auto --no-type
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/training_lab_runner.sh
source "${SCRIPT_DIR}/lib/training_lab_runner.sh"
# shellcheck source=lib/e2e_demo.sh
source "${SCRIPT_DIR}/lib/e2e_demo.sh"

TLAB_PS1='asaran@mac selinux-pac %'
DEMO_PROD_FORCE_ENFORCE="${DEMO_PROD_FORCE_ENFORCE:-true}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Presenter script for THIS Mac. It types explanations and the controller
commands from docs/admin/RHEL_TWO_HOST.md.

$(e2e_usage_common)

Other windows (do not run those scripts here unless using --auto):
  ssh ${E2E_SSH_USER}@${DEV_HOST}   →  bash ~/selinux-pac/scripts/demo_e2e_rhel_dev.sh
  ssh ${E2E_SSH_USER}@${PROD_HOST}  →  bash ~/e2e-demo/demo_e2e_rhel_prod.sh
EOF
}

mac_copy_prod_bundle() {
    tlab_explain "Prod gets the Flask app and this talk track over scp — not a git clone of selinux-pac."
    e2e_run "ssh ${E2E_SSH_USER}@${PROD_HOST} 'mkdir -p ~/e2e-demo/lib ~/e2e-demo/scripts ~/e2e-demo/app'"
    e2e_run "scp scripts/demo_e2e_rhel_prod.sh ${E2E_SSH_USER}@${PROD_HOST}:~/e2e-demo/"
    e2e_run "scp scripts/lib/e2e_demo.sh scripts/lib/training_lab_runner.sh ${E2E_SSH_USER}@${PROD_HOST}:~/e2e-demo/lib/"
    e2e_run "scp scripts/setup_staging_env.sh scripts/wait_for_endpoints.sh ${E2E_SSH_USER}@${PROD_HOST}:~/e2e-demo/scripts/"
    e2e_run "scp -r app/. ${E2E_SSH_USER}@${PROD_HOST}:~/e2e-demo/app/"
}

mac_scp_generated_from_dev() {
    tlab_explain "Copy the generated sources and compiled .pp onto this laptop. Ansible's policy_pp_src is a Mac path. GitHub PR is also opened from here."
    e2e_run "mkdir -p policy_out"
    e2e_run "scp ${E2E_SSH_USER}@${DEV_HOST}:~/selinux-pac/selinux/myapp.te ${E2E_SSH_USER}@${DEV_HOST}:~/selinux-pac/selinux/myapp.fc ${E2E_SSH_USER}@${DEV_HOST}:~/selinux-pac/selinux/policy_version.txt ${E2E_SSH_USER}@${DEV_HOST}:~/selinux-pac/selinux/myapp.pp selinux/"
    e2e_run_allow_fail "scp ${E2E_SSH_USER}@${DEV_HOST}:~/selinux-pac/policy_out/pr_body.md policy_out/pr_body.md"
    e2e_run "ls -l selinux/myapp.te selinux/myapp.fc selinux/policy_version.txt selinux/myapp.pp; echo '--- version ---'; cat selinux/policy_version.txt"
}

mac_open_policy_pr() {
    tlab_explain "Admin gate #1: a GitHub PR. CODEOWNERS must review selinux/. This is live generated policy, not a frozen demo snapshot."
    e2e_run_allow_fail "bash scripts/demo_open_generated_pr.sh"
    tlab_checkpoint "If gh is logged in, a PR URL printed. Merge is optional for the rest of this talk — we already have the .pp on this laptop."
    tlab_pause
    mac_policy_best_practices
}

mac_policy_best_practices() {
    tlab_explain "Admin gate #2: GitHub Actions reviews the PR for best practices (no shadow_t, no wildcards). The generator already ran this same script, so the check is supposed to pass — it is not a fail-on-purpose step."
    e2e_run "bash scripts/validate_forbidden_patterns.sh selinux"
    tlab_explain "That is the forbidden-patterns job on the PR. It should be green."
    e2e_run_allow_fail "command -v gh >/dev/null && gh pr checks || echo 'gh not logged in or no PR yet — local forbidden-patterns already passed'"
}

mac_canary_enforce_dev() {
    tlab_explain "Canary: Ansible copies that .pp to ${DEV_HOST}, loads it, and puts ONLY the demo app in log-but-do-not-block mode. The whole OS stays Enforcing."
    e2e_run "ansible-playbook -i ansible/inventory.dev.yml ansible/deploy_canary.yml"
    tlab_checkpoint "failed=0. Recent myapp_t events should be 0 raw / 0 net-new."
    tlab_pause

    tlab_explain "Dev inventory waits 0 days so we can lock down in a demo. Do not copy soak_min_days: 0 onto prod."
    e2e_run "ansible-playbook -i ansible/inventory.dev.yml ansible/enforce_production.yml -e change_ticket=LAB"
    tlab_checkpoint "failed=0. Host getenforce is still Enforcing; myapp_t is no longer permissive."
}

mac_ship_prod() {
    local mode="${1:-soak_demo}"
    tlab_explain "Production must not git clone this repo. We ship installer files (RPMs). rpmbuild runs on rhel-dev; this laptop collects dist/*.rpm."
    e2e_run "bash packaging/build_rpms.sh"
    e2e_run "ls dist/*.rpm"
    tlab_pause

    tlab_explain "scp copies the two RPMs into the prod user’s home directory."
    e2e_run "scp dist/selinux-policy-ops-*.rpm dist/myapp-selinux-*.rpm ${E2E_SSH_USER}@${PROD_HOST}:~/"

    e2e_handoff "On the PROD VM window run:
  bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part rpms
Press Enter here when rpm -q selinux-policy-ops myapp-selinux succeeds." \
        "ssh ${E2E_SSH_USER}@${PROD_HOST} 'bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part rpms $(e2e_auto_flags)'"

    tlab_explain "Same canary idea, but inventory.production.yml talks to ${PROD_HOST} and uses RPMs, not a git checkout."
    e2e_run "ansible-playbook -i ansible/inventory.production.yml ansible/deploy_canary.yml --limit canary"
    tlab_pause

    if [[ "${mode}" == "soak_demo" ]]; then
        tlab_print_section "Soak: app still works, AVC file is clean"
        e2e_handoff "On the PROD VM window run:
  bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak
curl the six first-ship URLs (not /feature-spool). They should return 200 and ausearch should show no myapp denials.
Press Enter here when you have seen both." \
            "ssh ${E2E_SSH_USER}@${PROD_HOST} 'bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak $(e2e_auto_flags)'"

        tlab_explain "soak_monitor gates net-new vs installed policy. First-ship URLs are already allowed, so this playbook should pass (failed=0)."
        e2e_run "ansible-playbook -i ansible/inventory.production.yml ansible/soak_monitor.yml --limit canary"
        tlab_pause

        e2e_handoff "On the PROD VM window run:
  bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak-avc
There should be no /var/lib/myapp/selinux_soak_last_fail.avc. Press Enter here when you have shown that." \
            "ssh ${E2E_SSH_USER}@${PROD_HOST} 'bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak-avc $(e2e_auto_flags)'"
    else
        tlab_explain "Recanary soak: the new module should already allow the spool write, so net-new is 0."
        e2e_run "ansible-playbook -i ansible/inventory.production.yml ansible/soak_monitor.yml --limit canary"
        tlab_pause
    fi

    tlab_explain "soak_status is read-only: how many days since canary? inventory.production.yml still wants 7. We do not change that file for the talk."
    e2e_run "ansible-playbook -i ansible/inventory.production.yml ansible/soak_status.yml --limit canary"
    tlab_pause

    if [[ "${DEMO_PROD_FORCE_ENFORCE}" == "true" ]]; then
        if [[ "${mode}" == "soak_demo" ]]; then
            tlab_explain "Soak was clean (net-new 0). Customer prod still waits 7 days. This recording treats soak as complete with force_enforce=true plus a change ticket. Then we will call /feature-spool, which is not in this module."
        else
            tlab_explain "Customer prod waits 7 days. This recording uses force_enforce=true plus a change ticket."
        fi
        e2e_run "ansible-playbook -i ansible/inventory.production.yml ansible/enforce_production.yml -e change_ticket=DEMO -e force_enforce=true"
        tlab_checkpoint "failed=0 on prod for the talk. Real shops omit force_enforce and wait seven clean days."
    else
        tlab_explain "DEMO_PROD_FORCE_ENFORCE is false — enforce MUST fail until seven days have passed. That is the product, not a bug."
        e2e_run_expect_fail "ansible-playbook -i ansible/inventory.production.yml ansible/enforce_production.yml -e change_ticket=CHG123"
        tlab_checkpoint "You already locked down the DEV VM. Prod waits."
    fi
}

mac_copy_prod_avc_to_dev() {
    tlab_explain "Prod has no generator. Copy the AVC export to rhel-dev policy_out/avc.log, then generate there."
    e2e_run "scp ${E2E_SSH_USER}@${PROD_HOST}:/tmp/prod-feature-spool.avc /tmp/prod-feature-spool.avc"
    e2e_run "ssh ${E2E_SSH_USER}@${DEV_HOST} 'mkdir -p ~/selinux-pac/policy_out'"
    e2e_run "scp /tmp/prod-feature-spool.avc ${E2E_SSH_USER}@${DEV_HOST}:~/selinux-pac/policy_out/avc.log"
    e2e_run "ssh ${E2E_SSH_USER}@${DEV_HOST} 'wc -l ~/selinux-pac/policy_out/avc.log'"
}

e2e_parse_args "$@"
e2e_require_mac
cd "${PROJECT_ROOT}"

e2e_banner "MAC — the remote control (no SELinux on this laptop)"
tlab_why "macOS cannot enforce SELinux. This window talks to two RHEL VMs over SSH: dev ${DEV_HOST} and prod ${PROD_HOST}."
tlab_explain "Look at the prompt. If it says rhel-dev or rhel-prod, you are in the wrong window."
tlab_explain "Story: generate first policy on rhel-dev → PR (CI best-practices, should pass) → prod canary/soak (app up, AVC file clean) → treat soak as complete and enforce → /feature-spool fails → admin rollback so the app is running → generate the fix on rhel-dev → second PR → recanary."
tlab_pause

tlab_print_section "Part 1 — Can the Mac reach the VMs?"
tlab_explain "write saves the two IP addresses into gitignored inventory files on this laptop."
e2e_run "bash scripts/setup_rhel_hosts.sh write --dev-host ${DEV_HOST} --prod-host ${PROD_HOST} --user ${E2E_SSH_USER}"
tlab_checkpoint "You should see Wrote …inventory.dev.yml and …inventory.production.yml."
tlab_pause

tlab_explain "ping is Ansible asking: can I SSH and run Python on both boxes?"
e2e_run "bash scripts/setup_rhel_hosts.sh ping"
tlab_checkpoint "SUCCESS / pong for rhel-dev and rhel-prod. Ignore the python3.9 warning if you still see it."
tlab_pause

tlab_explain "doctor checks SELinux is Enforcing and that ausearch (the no-log) and sesearch (is this already allowed?) exist on each VM."
e2e_run "bash scripts/setup_rhel_hosts.sh doctor"
tlab_checkpoint "Each host prints Enforcing, then paths to ausearch and sesearch."
tlab_pause

tlab_explain "rsync copies this laptop checkout onto rhel-dev. Prod gets the app bundle and talk track — no git clone."
e2e_run "bash scripts/sync_rhel_dev.sh"
mac_copy_prod_bundle
tlab_pause

tlab_explain "bootstrap only PRINTS the next SSH steps. It does not install the app. We follow the real steps in the other windows."
e2e_run "bash scripts/setup_rhel_hosts.sh bootstrap"
tlab_pause

e2e_handoff "On the PROD VM window run:
  bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part app
That installs the Flask app only (no policy module).
Press Enter here when curl / returns 200." \
    "ssh ${E2E_SSH_USER}@${PROD_HOST} 'bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part app $(e2e_auto_flags)'"

e2e_handoff "On the DEV VM window run:
  bash ~/selinux-pac/scripts/demo_e2e_rhel_dev.sh --part app
That installs the Flask app (no policy module), shows the git 1.1.3 myapp.te and overwrites it with a types-only 1.0.0 seed, then curls first-ship URLs (not /feature-spool).
Press Enter here when the six probes succeed." \
    "ssh ${E2E_SSH_USER}@${DEV_HOST} 'bash ~/selinux-pac/scripts/demo_e2e_rhel_dev.sh --part app $(e2e_auto_flags)'"

e2e_handoff "On the DEV VM window run:
  bash ~/selinux-pac/scripts/demo_e2e_rhel_dev.sh --part generate
That reads the audit log and writes the first real myapp.te from those AVCs.
Press Enter here when compile_and_validate has built selinux/myapp.pp." \
    "ssh ${E2E_SSH_USER}@${DEV_HOST} 'bash ~/selinux-pac/scripts/demo_e2e_rhel_dev.sh --part generate $(e2e_auto_flags)'"

tlab_print_section "Part 4 — Copy generated policy and open a GitHub PR"
mac_scp_generated_from_dev
tlab_pause
mac_open_policy_pr
tlab_pause

tlab_print_section "Part 5 — Canary + lab enforce on DEV"
mac_canary_enforce_dev
tlab_pause

tlab_print_section "Part 6 — RPMs on prod, canary, clean soak, then enforce"
mac_ship_prod soak_demo
tlab_pause

tlab_print_section "Part 7 — Fail on prod; admin restore; generate on dev; recanary"
e2e_handoff "On the PROD VM window run:
  bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part fail
curl /feature-spool should return 500. Press Enter here when /tmp/prod-feature-spool.avc exists." \
    "ssh ${E2E_SSH_USER}@${PROD_HOST} 'bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part fail $(e2e_auto_flags)'"

tlab_explain "Admin step: get the app running again. emergency_rollback.yml marks myapp_t permissive. Host getenforce stays Enforcing. We do not semodule -i on prod."
e2e_run "ansible-playbook -i ansible/inventory.production.yml ansible/emergency_rollback.yml"
tlab_pause

e2e_handoff "On the PROD VM window run:
  bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part restore
curl / and /feature-spool should return 200 again. Press Enter here when the app is up." \
    "ssh ${E2E_SSH_USER}@${PROD_HOST} 'bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part restore $(e2e_auto_flags)'"

mac_copy_prod_avc_to_dev
tlab_pause

e2e_handoff "On the DEV VM window generate from the prod log:
  bash ~/selinux-pac/scripts/demo_e2e_rhel_dev.sh --part generate --skip-export
Press Enter here when the second compile finishes." \
    "ssh ${E2E_SSH_USER}@${DEV_HOST} 'bash ~/selinux-pac/scripts/demo_e2e_rhel_dev.sh --part generate --skip-export $(e2e_auto_flags)'"

mac_scp_generated_from_dev
tlab_pause
mac_open_policy_pr
tlab_pause

tlab_explain "Recanary the new module on DEV, then rebuild RPMs and ship prod. We still do not generate on prod."
mac_canary_enforce_dev
tlab_pause
mac_ship_prod recanary

e2e_handoff "On the PROD VM window retest:
  bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part retest
curl /feature-spool should return 200 under the new module." \
    "ssh ${E2E_SSH_USER}@${PROD_HOST} 'bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part retest $(e2e_auto_flags)'"

echo
echo -e "${TLAB_BOLD}End of the Mac talk track.${TLAB_NC} Full script: docs/admin/RHEL_TWO_HOST.md"
echo
