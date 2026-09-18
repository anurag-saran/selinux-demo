#!/usr/bin/env bash
#
# demo_e2e_rhel_dev.sh — Typewriter talk track for the QA VM (192.168.64.6).
# Documented name: demo_e2e_rhel_qa.sh (wrapper).
#
# Run ON rhel-qa, not on the Mac:
#   ssh ansible@192.168.64.6
#   cd ~/selinux-pac
#   bash scripts/demo_e2e_rhel_qa.sh --part app
#   bash scripts/demo_e2e_rhel_qa.sh --part generate
#   bash scripts/demo_e2e_rhel_qa.sh --part generate --skip-export   # after prod AVC copy
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib/e2e_demo.sh" ]]; then
    # shellcheck source=lib/training_lab_runner.sh
    source "${SCRIPT_DIR}/lib/training_lab_runner.sh"
    # shellcheck source=lib/e2e_demo.sh
    source "${SCRIPT_DIR}/lib/e2e_demo.sh"
elif [[ -f "${HOME}/selinux-pac/scripts/lib/e2e_demo.sh" ]]; then
    # shellcheck source=lib/training_lab_runner.sh
    source "${HOME}/selinux-pac/scripts/lib/training_lab_runner.sh"
    # shellcheck source=lib/e2e_demo.sh
    source "${HOME}/selinux-pac/scripts/lib/e2e_demo.sh"
    SCRIPT_DIR="${HOME}/selinux-pac/scripts"
else
    echo "Cannot find scripts/lib/e2e_demo.sh. On this VM: cd ~/selinux-pac && git pull" >&2
    exit 1
fi

PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TLAB_PS1='[ansible@rhel-qa selinux-pac]$'
REPO_URL="${REPO_URL:-https://github.com/anurag-saran/selinux-pac.git}"
MYAPP_REPO_URL="${MYAPP_REPO_URL:-https://github.com/anurag-saran/myapp.git}"
APP_ROOT="${APP_ROOT:-${HOME}/myapp}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Presenter script for the QA VM (${DEV_HOST}). Do not run this on the Mac.

  --part app              Flask unconfined, then domain seed, then confined AVCs
  --part generate         ausearch (or --skip-export) → policy
  --part all              app, then pause, then generate
  --skip-export           With --part generate: use policy_out/avc.log from prod

$(e2e_usage_common)
EOF
}

e2e_parse_args "$@"
e2e_require_rhel "the QA VM (${DEV_HOST})"

part_app() {
    local first_ship
    first_ship='for path in / /save-log /run-script /rotate-log /probe-backend /notify-socket; do echo "=== GET ${path} ==="; curl -sf "http://127.0.0.1:8888${path}" | head -c 80; echo; done; echo "=== GET :8889/health ==="; curl -sf http://127.0.0.1:8889/health; echo'

    e2e_banner "QA VM — discovery box (${DEV_HOST})"
    tlab_why "SELinux runs HERE. The Mac is only the remote control. If the prompt does not say rhel-qa, stop."
    tlab_explain "hostname and whoami: confirm you are on the Linux VM as ansible, not on the Mac."
    e2e_run "hostname"
    e2e_run "whoami"
    tlab_pause

    tlab_print_section "Part 2 — Run the app unconfined, then create the domain"
    tlab_explain "These packages give us git, Python, and the SELinux tools: ausearch (read denials), sesearch (ask if a rule already exists), semanage (labels / permissive domain)."
    e2e_run "sudo dnf install -y git python3 python3-pip policycoreutils policycoreutils-python-utils setools-console audit selinux-policy-devel"
    tlab_checkpoint "Complete! or already installed."
    tlab_pause

    if [[ -d "${HOME}/selinux-demo" && ! -d "${HOME}/selinux-pac" ]]; then
        tlab_explain "Renaming the old ~/selinux-demo tree to ~/selinux-pac to match the product name."
        e2e_run "mv ${HOME}/selinux-demo ${HOME}/selinux-pac"
    fi
    if [[ -d "${HOME}/selinux-pac" ]]; then
        tlab_explain "The tool is already on this VM (git clone or rsync from the Mac). We do not clone into a non-empty directory. Do not clone onto prod later."
        e2e_run "ls ${HOME}/selinux-pac/scripts/dev_generate_policy.sh"
    else
        tlab_explain "This is a SECOND copy of the SELinux PaC tool. The Mac still has its own tree. Ansible will look here, not under /Users/..."
        e2e_run "git clone ${REPO_URL} ${HOME}/selinux-pac"
    fi
    tlab_pause

    if [[ -d "${APP_ROOT}/app" ]]; then
        tlab_explain "The application GitHub repo is already at ${APP_ROOT}. Policy we generate is committed there, not in selinux-pac."
        e2e_run "ls ${APP_ROOT}/app/app.py ${APP_ROOT}/config/myapp.manifest.yml"
    else
        tlab_explain "Clone the application repo (Flask + selinux/). That is what the audience sees on GitHub: anurag-saran/myapp."
        e2e_run "git clone ${MYAPP_REPO_URL} ${APP_ROOT}"
    fi
    tlab_pause

    tlab_explain "cd puts us in this VM’s copy of the tool (~/selinux-pac). Application files live in ~/myapp."
    e2e_run "cd ${HOME}/selinux-pac && pwd && ls ${APP_ROOT}/app/app.py"
    tlab_pause

    tlab_explain "--app-only copies Flask from ~/myapp to /opt/myapp, installs systemd units, and starts myapp + myapp-backend. It does not compile policy and does not semodule -i. We have not confined the process yet."
    e2e_run "sudo bash scripts/setup_staging_env.sh --app-only --app-root ${APP_ROOT}"
    tlab_pause

    tlab_explain "doctor is a health check: SELinux is on, ausearch and sesearch exist, app paths exist. It does not generate policy."
    e2e_run "sudo bash scripts/selinux_pac_adopt.sh doctor"
    tlab_explain "getenforce is the host-wide mode. The whole OS stays Enforcing."
    e2e_run "getenforce"
    tlab_explain "systemctl is-active asks systemd whether the website units are running. This is not a SELinux command."
    e2e_run "systemctl is-active myapp.service myapp-backend.service"
    tlab_pause

    tlab_explain "If a previous demo left myapp loaded, drop it so this run starts unconfined. We are not loading a seed yet."
    e2e_run 'for mod in myapp_ports myapp_canary myapp permissive_myapp_t permissive_myapp_backend_t; do sudo semodule -r "${mod}" 2>/dev/null || true; done'
    e2e_run "sudo semanage port -d -t myapp_port_t -p tcp 8888 2>/dev/null || true; sudo semanage port -d -t myapp_backend_port_t -p tcp 8889 2>/dev/null || true; sudo semanage permissive -d myapp_t 2>/dev/null || true; sudo semanage permissive -d myapp_backend_t 2>/dev/null || true"
    e2e_run "sudo restorecon -Rv /opt/myapp /var/lib/myapp /var/log/myapp /run/myapp 2>/dev/null || true; sudo systemctl restart myapp-backend.service myapp.service 2>/dev/null || true"
    e2e_run "sudo semodule -l | grep myapp || echo 'Good: no myapp module loaded'"
    tlab_pause

    tlab_explain "ps -eZ shows the SELinux domain of the running process. Expect unconfined_service_t (or similar), not myapp_t. That is why the next ausearch will be empty."
    e2e_run "ps -eZ | grep -E 'myapp|8888' | grep -v grep || ps -eZ | grep -E 'app.py|backend_stub' | grep -v grep"
    tlab_pause

    tlab_explain "First-ship URLs while unconfined. They should return 200. We do not call /feature-spool — that test is Act 2 on prod."
    e2e_run "${first_ship}"
    tlab_pause

    tlab_explain "ausearch is the no-log. Unconfined_service_t is allowed to do what this app does, so there is nothing useful to generate from."
    e2e_run "sudo ausearch -m avc -ts recent 2>/dev/null | grep myapp || echo 'Good: no myapp denials (process is not confined yet)'"
    tlab_checkpoint "App is up; AVC log has no myapp_t lines. Next we create the confined domain so the following curls produce real denials."
    tlab_pause

    tlab_explain "Now we create the domain — types, file labels, and only the rules systemd needs to start the binary as myapp_t. That is not an application allow list (no ports, logs, scripts). --load compiles, semodule -i, then semanage permissive so denials are logged without blocking. Permissive is not written into the .te. Files land in ~/myapp/selinux (the application repo)."
    e2e_run "sudo bash scripts/write_domain_seed.sh --load --app-root ${APP_ROOT}"
    tlab_pause

    tlab_explain "head shows policy_module(myapp, 1.0.0) and types / init_daemon_domain — not a page of extra allow lines. This file did not exist as the running policy until the command we just ran."
    e2e_run "head -20 ${APP_ROOT}/selinux/myapp.te; echo '---'; cat ${APP_ROOT}/selinux/policy_version.txt"
    e2e_run "sudo semanage permissive -l | grep myapp || true"
    tlab_pause

    tlab_print_section "What lives under selinux/ in the myapp repo"
    e2e_explain_selinux_tree "${APP_ROOT}"
    tlab_pause

    tlab_explain "Same process, now myapp_t. Curl the same six URLs again so SELinux has something to say no to."
    e2e_run "ps -eZ | grep -E 'myapp|8888' | grep -v grep || ps -eZ | grep -E 'app.py|backend_stub' | grep -v grep"
    e2e_run "${first_ship}"
    tlab_pause

    tlab_explain "These myapp_t AVC lines are the input to generate. Run generate next (Part 3) so the export is this recent window, not leftover boot noise."
    e2e_run "sudo ausearch -m avc -ts recent 2>/dev/null | grep myapp | tail -20 || echo 'WARN: still no myapp AVC — check ps -eZ is myapp_t'"
    tlab_checkpoint "Enforcing; process is myapp_t; second curls produced AVCs. Go back to the Mac — next is generate."
}

part_generate() {
    e2e_banner "QA VM — turn denials into the first (or next) real .te"
    cd "${HOME}/selinux-pac"
    if [[ "${E2E_SKIP_EXPORT}" -eq 1 ]]; then
        tlab_why "Prod already captured the denial. We do not generate on prod. This box reads ~/myapp/policy_out/avc.log copied from rhel-prod and writes new allows into the myapp tree."
        tlab_explain "ls / wc: confirm the Mac copied the prod AVC file here before we generate."
        e2e_run "ls -l ${APP_ROOT}/policy_out/avc.log; wc -l ${APP_ROOT}/policy_out/avc.log"
        tlab_pause
        tlab_explain "sudo is required: policy_out/ is often owned by root. --skip-export keeps that prod log instead of running ausearch on this box. --apply writes the new allows into ~/myapp/selinux/."
        e2e_run "sudo bash scripts/dev_generate_policy.sh --skip-export --apply --app-root ${APP_ROOT}"
    else
        tlab_why "The process is now myapp_t (permissive). The second curls logged ‘SELinux said no’ without blocking. We read that log and write the first real allow list into the myapp GitHub tree. Run this immediately after those curls so ausearch -ts recent is this window."
        tlab_explain "restorecon applies labels that myapp.fc already describes. Relabel AVCs are a labeling fix, not missing allows."
        e2e_run "sudo restorecon -Rv /opt/myapp /var/lib/myapp /var/log/myapp /run/myapp"
        tlab_pause
        tlab_explain "sudo is required: the audit log is root-only. --apply exports ausearch, generates candidate .te/.fc under ~/myapp/policy_out/, and copies them into ~/myapp/selinux/. Do not SSH to yourself — you are already on rhel-qa."
        e2e_run "sudo bash scripts/dev_generate_policy.sh --apply --app-root ${APP_ROOT}"
    fi
    tlab_explain "compile_and_validate.sh turns .te/.fc into ~/myapp/selinux/myapp.pp on this Linux box (a Mac cannot). It also runs the forbidden-pattern check GitHub Actions will run on the myapp PR."
    e2e_run "bash scripts/compile_and_validate.sh ${APP_ROOT}/selinux"
    tlab_pause
    tlab_explain "ls shows the generated sources, the version bump, and the compiled .pp. head shows real allow lines from AVCs. policy_out/ holds avc.log and the PR body."
    e2e_run "ls -l ${APP_ROOT}/selinux/myapp.te ${APP_ROOT}/selinux/myapp.fc ${APP_ROOT}/selinux/policy_version.txt ${APP_ROOT}/selinux/myapp.pp"
    e2e_run "echo '--- generated myapp.te (head) ---'; head -30 ${APP_ROOT}/selinux/myapp.te; echo '--- policy_out ---'; ls -l ${APP_ROOT}/policy_out"
    tlab_checkpoint "selinux/myapp.te is generated from AVCs in the myapp repo tree. Go back to the Mac: copy sources, open a GitHub PR on anurag-saran/myapp, then canary."
}

case "${E2E_PART}" in
    app) part_app ;;
    generate) part_generate ;;
    fail)
        echo "Act 2 fail/retest runs on rhel-prod, not here:" >&2
        echo "  bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part fail" >&2
        exit 2
        ;;
    all)
        part_app
        e2e_handoff "Leave this window open. On the Mac, do not canary yet. Come back here for --part generate.
Press Enter when you are ready to generate."
        part_generate
        ;;
    *)
        echo "Unknown --part ${E2E_PART} (use app, generate, or all)" >&2
        exit 2
        ;;
esac

echo
echo -e "${TLAB_BOLD}End of this QA talk-track part.${TLAB_NC} Do not type exit until the Mac script asks you to."
echo
