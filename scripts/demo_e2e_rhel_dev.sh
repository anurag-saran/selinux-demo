#!/usr/bin/env bash
#
# demo_e2e_rhel_dev.sh — Typewriter talk track for the DEV VM (192.168.64.6).
#
# Run ON rhel-dev, not on the Mac:
#   ssh ansible@192.168.64.6
#   cd ~/selinux-pac
#   bash scripts/demo_e2e_rhel_dev.sh --part app
#   bash scripts/demo_e2e_rhel_dev.sh --part generate
#   bash scripts/demo_e2e_rhel_dev.sh --part generate --skip-export   # after prod AVC copy
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
TLAB_PS1='[ansible@rhel-dev selinux-pac]$'
REPO_URL="${REPO_URL:-https://github.com/anurag-saran/selinux-pac.git}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Presenter script for the DEV VM (${DEV_HOST}). Do not run this on the Mac.

  --part app              Flask app, domain seed, file tour, first-ship curls
  --part generate         ausearch (or --skip-export) → policy
  --part all              app, then pause, then generate
  --skip-export           With --part generate: use policy_out/avc.log from prod

$(e2e_usage_common)
EOF
}

e2e_parse_args "$@"
e2e_require_rhel "the DEV VM (${DEV_HOST})"

part_app() {
    e2e_banner "DEV VM — practice box (${DEV_HOST})"
    tlab_why "SELinux runs HERE. The Mac is only the remote control. If the prompt does not say rhel-dev, stop."
    tlab_explain "hostname and whoami: confirm you are on the Linux VM as ansible, not on the Mac."
    e2e_run "hostname"
    e2e_run "whoami"
    tlab_pause

    tlab_print_section "Part 2 — Install the app and a types-only domain seed"
    tlab_explain "These packages give us git, Python, and the SELinux tools: ausearch (read denials), sesearch (ask if a rule already exists), semanage (labels / permissive domain)."
    e2e_run "sudo dnf install -y git python3 python3-pip policycoreutils policycoreutils-python-utils setools-console audit selinux-policy-devel"
    tlab_checkpoint "Complete! or already installed."
    tlab_pause

    if [[ -d "${HOME}/selinux-demo" && ! -d "${HOME}/selinux-pac" ]]; then
        tlab_explain "Renaming the old ~/selinux-demo tree to ~/selinux-pac to match the product name."
        e2e_run "mv ${HOME}/selinux-demo ${HOME}/selinux-pac"
    fi
    if [[ -d "${HOME}/selinux-pac" ]]; then
        tlab_explain "The project is already on this VM (git clone or rsync from the Mac). We do not clone into a non-empty directory. Do not clone onto prod later."
        e2e_run "ls ${HOME}/selinux-pac/config/myapp.manifest.yml"
    else
        tlab_explain "This is a SECOND copy of the project. The Mac still has its own tree. Ansible will look here, not under /Users/..."
        e2e_run "git clone ${REPO_URL} ${HOME}/selinux-pac"
    fi
    tlab_pause

    tlab_explain "cd puts us in this VM’s copy of the project (~/selinux-pac), not /Users/... on the Mac."
    e2e_run "cd ${HOME}/selinux-pac && pwd"
    tlab_pause

    tlab_explain "GitHub ships a last-generated selinux/myapp.te (today 1.1.3) so CI can lint a real file. That is source control, not the policy this box is running. We overwrite it next. Do not canary that 1.1.3 file."
    e2e_run "echo '--- file from git (will be replaced) ---'; head -8 selinux/myapp.te; echo '--- what the kernel has loaded ---'; sudo semodule -l | grep myapp || echo 'Good: no myapp module loaded'"
    tlab_pause

    tlab_explain "--app-only copies Flask to /opt/myapp, installs systemd units, and starts myapp + myapp-backend. It does not compile policy and does not semodule -i."
    e2e_run "sudo bash scripts/setup_staging_env.sh --app-only"
    tlab_pause

    tlab_explain "write_domain_seed.sh overwrites myapp.te with a 1.0.0 seed: type names, file labels, and only the rules systemd needs to start the binary as myapp_t. That is a domain, not an application allow list (no ports, logs, scripts). --load compiles, semodule -i, then semanage permissive so denials are logged without blocking. Permissive is not written into the .te."
    e2e_run "sudo bash scripts/write_domain_seed.sh --load"
    tlab_pause

    tlab_explain "head and cat prove the git 1.1.3 file is gone. You should see policy_module(myapp, 1.0.0) and types / init_daemon_domain — not a page of extra allow lines."
    e2e_run "head -20 selinux/myapp.te; echo '---'; cat selinux/policy_version.txt"
    tlab_pause

    tlab_print_section "What lives under selinux/ on this box"
    e2e_explain_selinux_tree "${HOME}/selinux-pac"
    tlab_pause

    tlab_explain "doctor is a health check: SELinux is on, ausearch and sesearch exist, app paths exist. It does not generate policy."
    e2e_run "sudo bash scripts/selinux_pac_adopt.sh doctor"
    tlab_pause

    tlab_explain "getenforce is the host-wide mode. The whole OS stays Enforcing. Only the demo app domain is log-but-do-not-block, and that flag is in semanage, not in myapp.te."
    e2e_run "getenforce"
    e2e_run "sudo semanage permissive -l | grep myapp || true"
    tlab_pause

    tlab_explain "systemctl is-active asks systemd whether the website units are running. This is not a SELinux command."
    e2e_run "systemctl is-active myapp.service myapp-backend.service"
    tlab_pause

    tlab_explain "These six URLs are first-ship. They may return 200 because myapp_t is permissive; SELinux still writes AVCs for anything the seed does not allow. Those AVCs are the input to generate. We do not call /feature-spool — that test is Act 2 on prod."
    e2e_run 'for path in / /save-log /run-script /rotate-log /probe-backend /notify-socket; do echo "=== GET ${path} ==="; curl -sf "http://127.0.0.1:8888${path}" | head -c 80; echo; done; echo "=== GET :8889/health ==="; curl -sf http://127.0.0.1:8889/health; echo'
    tlab_checkpoint "Enforcing; both services active; six probes succeeded under a types-only seed. Go back to the Mac — next is generate."
}

part_generate() {
    e2e_banner "DEV VM — turn denials into the first (or next) real .te"
    cd "${HOME}/selinux-pac"
    if [[ "${E2E_SKIP_EXPORT}" -eq 1 ]]; then
        tlab_why "Prod already captured the denial. We do not generate on prod. This box reads policy_out/avc.log copied from rhel-prod and writes new allows."
        tlab_explain "ls / wc: confirm the Mac copied the prod AVC file here before we generate."
        e2e_run "ls -l policy_out/avc.log; wc -l policy_out/avc.log"
        tlab_pause
        tlab_explain "sudo is required: policy_out/ is often owned by root. --skip-export keeps that prod log instead of running ausearch on this box. --apply writes the new allows into selinux/."
        e2e_run "sudo bash scripts/dev_generate_policy.sh --skip-export --apply"
    else
        tlab_why "The 1.0.0 seed plus semanage permissive logged ‘SELinux said no’ without blocking. We read that log and write the first real allow list. That replaces the seed — we are not using the git 1.1.3 file."
        tlab_explain "restorecon applies labels that myapp.fc already describes. Relabel AVCs are a labeling fix, not missing allows."
        e2e_run "sudo restorecon -Rv /opt/myapp /var/lib/myapp /var/log/myapp /run/myapp"
        tlab_pause
        tlab_explain "sudo is required: the audit log is root-only. --apply exports ausearch, generates candidate .te/.fc under policy_out/, and copies them into selinux/. Do not SSH to yourself — you are already on rhel-dev."
        e2e_run "sudo bash scripts/dev_generate_policy.sh --apply"
    fi
    tlab_explain "compile_and_validate.sh turns .te/.fc into selinux/myapp.pp on this Linux box (a Mac cannot). It also runs the forbidden-pattern check GitHub Actions will run on the PR."
    e2e_run "bash scripts/compile_and_validate.sh selinux"
    tlab_pause
    tlab_explain "ls shows the generated sources, the version bump, and the compiled .pp. head shows real allow lines from AVCs. policy_out/ holds avc.log and the PR body."
    e2e_run "ls -l selinux/myapp.te selinux/myapp.fc selinux/policy_version.txt selinux/myapp.pp"
    e2e_run "echo '--- generated myapp.te (head) ---'; head -30 selinux/myapp.te; echo '--- policy_out ---'; ls -l policy_out"
    tlab_checkpoint "selinux/myapp.te is generated from AVCs. Go back to the Mac: copy sources, open a GitHub PR, then canary."
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
echo -e "${TLAB_BOLD}End of this DEV talk-track part.${TLAB_NC} Do not type exit until the Mac script asks you to."
echo
