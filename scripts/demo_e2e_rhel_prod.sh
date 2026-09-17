#!/usr/bin/env bash
#
# demo_e2e_rhel_prod.sh — Typewriter talk track for the PROD VM (192.168.64.5).
#
# Run ON rhel-prod, not on the Mac. Do not git clone this repo onto prod.
# Copy this script from the Mac if needed:
#   scp scripts/demo_e2e_rhel_prod.sh scripts/lib/e2e_demo.sh scripts/lib/training_lab_runner.sh \
#     ansible@192.168.64.5:~/e2e-demo/
#   # then on prod: mkdir -p ~/e2e-demo/lib && mv ~/e2e-demo/e2e_demo.sh ~/e2e-demo/lib/ ...
#
# Easier: the Mac presenter copies a bundle. Then:
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh
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
else
    echo "Cannot find lib/e2e_demo.sh. From the Mac:" >&2
    echo "  ssh ansible@192.168.64.5 'mkdir -p ~/e2e-demo/lib'" >&2
    echo "  scp scripts/demo_e2e_rhel_prod.sh ansible@192.168.64.5:~/e2e-demo/" >&2
    echo "  scp scripts/lib/e2e_demo.sh scripts/lib/training_lab_runner.sh ansible@192.168.64.5:~/e2e-demo/lib/" >&2
    exit 1
fi

TLAB_PS1='[ansible@rhel-prod ~]$'

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Presenter script for the PROD VM (${PROD_HOST}). Do not run this on the Mac.
Do not git clone onto this box — RPMs only.

$(e2e_usage_common)
EOF
}

e2e_parse_args "$@"
e2e_require_rhel "the PROD VM (${PROD_HOST})"

e2e_banner "PROD VM — pretend production (${PROD_HOST})"
tlab_why "Real shops do not git clone policy onto prod. Helpers come from RPMs (installer files), like a .pkg on a Mac."
e2e_run "hostname"
e2e_run "test ! -d ${HOME}/selinux-pac && echo 'Good: no git clone of selinux-pac in home' || echo 'Note: a checkout exists — Ansible still uses RPM paths, not this tree'"
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
        echo "RPMs are not in ${HOME} and not installed. On the Mac, finish packaging/build_rpms.sh and scp, then re-run this script." >&2
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
tlab_checkpoint "Both RPMs print a version. Enforcing. Go back to the Mac for canary / soak / (failing) enforce."

echo
echo -e "${TLAB_BOLD}End of the PROD talk track.${TLAB_NC} Playbooks run on the Mac, not here."
echo
