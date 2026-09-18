#!/usr/bin/env bash
#
# demo_e2e_rhel_prod.sh — Typewriter talk track for the PROD VM (192.168.64.5).
#
# Run ON rhel-prod, not on the Mac. Do not git clone this repo onto prod.
#
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part app     # Flask app only
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part rpms    # policy RPMs
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak    # first-ship 200, AVC file clean
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak-avc  # no soak-fail AVC file
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part fail    # /feature-spool 500 after enforce
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part restore # app 200 after rollback
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part retest  # /feature-spool 200 after recanary
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib/e2e_demo.sh" ]]; then
    # shellcheck source=lib/training_lab_runner.sh
    source "${SCRIPT_DIR}/lib/training_lab_runner.sh"
    # shellcheck source=lib/e2e_demo.sh
    source "${SCRIPT_DIR}/lib/e2e_demo.sh"
elif [[ -f "${HOME}/e2e-demo/lib/e2e_demo.sh" ]]; then
    # shellcheck source=lib/training_lab_runner.sh
    source "${HOME}/e2e-demo/lib/training_lab_runner.sh"
    # shellcheck source=lib/e2e_demo.sh
    source "${HOME}/e2e-demo/lib/e2e_demo.sh"
    SCRIPT_DIR="${HOME}/e2e-demo/scripts"
    if [[ ! -d "${SCRIPT_DIR}" ]]; then
        SCRIPT_DIR="${HOME}/e2e-demo"
    fi
else
    echo "Cannot find lib/e2e_demo.sh. From the Mac:" >&2
    echo "  ssh ansible@192.168.64.5 'mkdir -p ~/e2e-demo/lib ~/e2e-demo/scripts ~/e2e-demo/app'" >&2
    echo "  scp scripts/demo_e2e_rhel_prod.sh ansible@192.168.64.5:~/e2e-demo/" >&2
    echo "  scp scripts/lib/e2e_demo.sh scripts/lib/training_lab_runner.sh ansible@192.168.64.5:~/e2e-demo/lib/" >&2
    exit 1
fi

TLAB_PS1='[ansible@rhel-prod ~]$'
APP_BUNDLE="${HOME}/e2e-demo"
AVC_EXPORT="/tmp/prod-feature-spool.avc"
SOAK_FAIL_AVC="/var/lib/myapp/selinux_soak_last_fail.avc"
SOAK_FAIL_JSON="/var/lib/myapp/selinux_soak_last_fail.json"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Presenter script for the PROD VM (${PROD_HOST}). Do not run this on the Mac.
Do not git clone onto this box — app files from scp, policy from RPMs.

  --part app      Install the Flask app only (no SELinux module, no git)
  --part rpms     Install selinux-policy-ops + myapp-selinux from ~/
  --part soak     Canary soak: first-ship URLs 200, no myapp AVC since canary
  --part soak-avc Confirm soak_monitor did not write a fail AVC file
  --part fail     curl /feature-spool (expect 500) and export AVCs
  --part restore  After emergency rollback: app 200 again (not a policy fix)
  --part retest   curl /feature-spool (expect 200) after recanary
  --part all      rpms (legacy default)

$(e2e_usage_common)
EOF
}

e2e_parse_args "$@"
e2e_require_rhel "the PROD VM (${PROD_HOST})"

part_app() {
    e2e_banner "PROD VM — install the application (no git, no policy module)"
    tlab_why "The website must be running here before we ship SELinux RPMs. We copy app files from the Mac. We do not clone selinux-pac."
    e2e_run "hostname"
    e2e_run "test ! -d ${HOME}/selinux-pac && echo 'Good: no git clone of selinux-pac in home' || echo 'Note: a checkout exists — we still install from ~/e2e-demo, not that tree'"
    tlab_pause

    tlab_explain "python3 for the venv. policycoreutils is already on RHEL; we are not compiling policy on prod."
    e2e_run "sudo dnf install -y python3 python3-pip policycoreutils policycoreutils-python-utils"
    tlab_pause

    if [[ ! -f "${APP_BUNDLE}/scripts/setup_staging_env.sh" || ! -f "${APP_BUNDLE}/app/app.py" ]]; then
        echo "Missing ${APP_BUNDLE}/app or scripts/setup_staging_env.sh. On the Mac, finish the app scp, then re-run --part app." >&2
        exit 1
    fi
    tlab_explain "--app-only copies Flask + systemd units. No SELinux module. Policy arrives later as an RPM."
    e2e_run "sudo bash ${APP_BUNDLE}/scripts/setup_staging_env.sh --app-only"
    e2e_run "getenforce"
    e2e_run "systemctl is-active myapp.service myapp-backend.service"
    e2e_run 'ok=0; for i in $(seq 1 30); do if curl -sf -o /dev/null http://127.0.0.1:8888/; then echo HTTP 200 /; ok=1; break; fi; sleep 2; done; test "${ok}" = 1'
    tlab_checkpoint "App is up. Go back to the Mac. Policy is not installed yet."
}

part_rpms() {
    e2e_banner "PROD VM — pretend production (${PROD_HOST})"
    tlab_why "Real shops do not git clone policy onto prod. Helpers come from RPMs (installer files), like a .pkg on a Mac."
    e2e_run "hostname"
    tlab_pause

    tlab_print_section "Install log tools + our two RPMs"
    tlab_explain "policycoreutils / setools / audit: same tools as doctor (semodule, sesearch, ausearch). No git. No selinux-policy-devel."
    e2e_run "sudo dnf install -y policycoreutils policycoreutils-python-utils setools-console audit"
    tlab_pause

    if compgen -G "${HOME}/selinux-policy-ops-*.rpm" >/dev/null && compgen -G "${HOME}/myapp-selinux-*.rpm" >/dev/null; then
        newest_ops="$(ls -1 "${HOME}"/selinux-policy-ops-*.rpm | sort -V | tail -1)"
        newest_app="$(ls -1 "${HOME}"/myapp-selinux-*.rpm | sort -V | tail -1)"
        tlab_explain "rpm -Uvh --force installs or replaces with the newest files in ~. dnf localinstall is a no-op for the same version, which left stale ops scripts on this box."
        e2e_run "sudo rpm -Uvh --force ${newest_ops} ${newest_app}"
    elif rpm -q selinux-policy-ops myapp-selinux >/dev/null 2>&1; then
        tlab_explain "Both RPMs are already installed from an earlier run, and there is no new pair in ~. We skip localinstall."
    else
        if [[ "${TLAB_AUTO}" -eq 1 ]]; then
            echo "RPMs are not in ${HOME} and not installed. On the Mac, finish packaging/build_rpms.sh and scp, then re-run --part rpms." >&2
            exit 1
        fi
        tlab_why "RPMs are not in ~ yet. Go to the Mac window, finish scp, then press Enter here."
        tlab_pause
        newest_ops="$(ls -1 "${HOME}"/selinux-policy-ops-*.rpm | sort -V | tail -1)"
        newest_app="$(ls -1 "${HOME}"/myapp-selinux-*.rpm | sort -V | tail -1)"
        e2e_run "sudo rpm -Uvh --force ${newest_ops} ${newest_app}"
    fi

    e2e_run "rpm -q selinux-policy-ops myapp-selinux"
    e2e_run "getenforce"
    e2e_run "command -v ausearch; command -v sesearch"
    tlab_checkpoint "Both RPMs print a version. Enforcing. Go back to the Mac for canary, then soak on this window."
}

part_soak() {
    e2e_banner "PROD VM — soak: app is up, AVC file is clean"
    tlab_why "Canary left myapp_t permissive. First-ship URLs are in the module we just shipped. Soak is: the website works and there is nothing new in the denial log."
    e2e_run "sudo rm -f ${SOAK_FAIL_JSON} ${SOAK_FAIL_AVC}"
    tlab_explain "Curl the six first-ship URLs only. Do not call /feature-spool yet — that is the outage after we enforce."
    e2e_run 'for path in / /save-log /run-script /rotate-log /probe-backend /notify-socket; do echo "=== GET ${path} ==="; curl -sf "http://127.0.0.1:8888${path}" | head -c 80; echo; done'
    tlab_explain "ausearch since the canary marker. You should see no myapp denials. That is a clean soak."
    e2e_run 'marker=$(sudo cat /var/lib/myapp/selinux_canary_deployed_at 2>/dev/null || true); if [[ -n "${marker}" ]]; then ts=$(date -d "@${marker}" "+%m/%d/%Y %H:%M:%S" 2>/dev/null || date -r "${marker}" "+%m/%d/%Y %H:%M:%S"); echo "canary marker ${ts}"; sudo ausearch -m avc -ts "${ts}" 2>/dev/null | grep myapp | tail -20 && echo "(unexpected myapp AVC — leftover from an earlier demo?)" || echo "Good: no myapp AVC since canary"; else sudo ausearch -m avc -ts recent 2>/dev/null | grep myapp | tail -10 || echo "Good: no myapp AVC in recent log"; fi'
    tlab_checkpoint "HTTP 200 on first-ship URLs and a clean AVC log. Go back to the Mac for soak_monitor (it should pass)."
}

part_soak_avc() {
    e2e_banner "PROD VM — soak AVC file (should not exist)"
    tlab_why "soak_monitor only writes selinux_soak_last_fail.avc when net-new denials exist. A clean soak leaves no fail file."
    e2e_run "sudo test ! -f ${SOAK_FAIL_AVC} && sudo test ! -f ${SOAK_FAIL_JSON} && echo 'Good: no ${SOAK_FAIL_AVC}' || sudo ls -l ${SOAK_FAIL_JSON} ${SOAK_FAIL_AVC}"
    tlab_checkpoint "No fail AVC file. Soak is clean. Go back to the Mac — we treat soak as complete and enforce."
}

part_fail() {
    e2e_banner "PROD VM — Act 2: the new feature is denied after enforce"
    tlab_why "Policy is live here. /feature-spool was never in the first module. The app fails on prod. We will not semodule -i on this box."
    tlab_explain "/feature-spool writes /var/spool/myapp/feature.log. systemd allows the path; SELinux should not (yet)."
    e2e_run_expect_fail "curl -sf http://127.0.0.1:8888/feature-spool"
    e2e_run "curl -sS http://127.0.0.1:8888/feature-spool || true"
    tlab_explain "ausearch is the no-log. Export it so the Mac can copy the file to rhel-qa. Generate happens there."
    e2e_run "sudo ausearch -m avc -ts recent 2>/dev/null | tee ${AVC_EXPORT} | grep -E 'myapp|spool|var_spool' | tail -20 || true"
    e2e_run "sudo chmod a+r ${AVC_EXPORT}; wc -l ${AVC_EXPORT}"
    tlab_checkpoint "HTTP 500 + an AVC in ${AVC_EXPORT}. Go back to the Mac — admin rollback first so the app is running, then generate on rhel-qa."
}

part_restore() {
    e2e_banner "PROD VM — admin restore (domain permissive again)"
    tlab_why "emergency_rollback.yml does not rewrite policy. It puts myapp_t back to permissive so customers are not down while we open a PR."
    e2e_run "getenforce"
    e2e_run "systemctl is-active myapp.service myapp-backend.service"
    e2e_run "curl -sf -o /dev/null http://127.0.0.1:8888/ && echo 'HTTP 200 /'"
    e2e_run "curl -sf http://127.0.0.1:8888/feature-spool | head -c 120; echo"
    tlab_checkpoint "Host is still Enforcing. App is up. Policy is not fixed. Next: copy the AVC log to rhel-qa and generate."
}

part_retest() {
    e2e_banner "PROD VM — the fix arrived as a new RPM"
    tlab_why "Same URL as the failure. After recanary the new module must allow the spool write."
    e2e_run "curl -sf http://127.0.0.1:8888/feature-spool"
    tlab_checkpoint "HTTP 200 under the new module (enforcing). Clean soak, then outage, rollback kept the app up, PR fixed policy."
}

case "${E2E_PART}" in
    app) part_app ;;
    rpms|all) part_rpms ;;
    soak) part_soak ;;
    soak-avc) part_soak_avc ;;
    fail) part_fail ;;
    restore) part_restore ;;
    retest) part_retest ;;
    *)
        echo "Unknown --part ${E2E_PART} (use app, rpms, soak, soak-avc, fail, restore, retest)" >&2
        exit 2
        ;;
esac

echo
echo -e "${TLAB_BOLD}End of this PROD talk-track part.${TLAB_NC} Playbooks run on the Mac, not here."
echo
