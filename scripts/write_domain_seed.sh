#!/usr/bin/env bash
#
# write_domain_seed.sh — Types + file_contexts so systemd can start myapp_t.
#
# This is not a stub policy: no extra allows, no permissive in the .te.
# Customer talk: run AFTER unconfined curls prove ausearch is empty, then collect
# myapp_t AVCs. Discovery uses `semanage permissive -a myapp_t`. The first real
# allow list comes from scripts/dev_generate_policy.sh --apply.
#
# Usage:
#   bash scripts/write_domain_seed.sh           # write selinux/myapp.te .fc version
#   sudo bash scripts/write_domain_seed.sh --load   # compile, semodule -i, permissive
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOAD=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [--load] [--app-root DIR]

Write a types-only myapp domain seed into \$APP_ROOT/selinux/ (not selinux/stub/).
Customer talk: --app-root ~/myapp so the seed lives in the application repo tree.

  --load       Compile, replace any loaded myapp module, semanage permissive myapp_t
  --app-root   Application tree (default: sibling/~/myapp if present, else this repo)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --load) LOAD=1; shift ;;
        --app-root) APP_ROOT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

# shellcheck source=lib/app_root.sh
source "${SCRIPT_DIR}/lib/app_root.sh"
bind_app_tree "${PROJECT_ROOT}"
SELINUX_DIR="${APP_ROOT}/selinux"

mkdir -p "${SELINUX_DIR}"

cat >"${SELINUX_DIR}/myapp.te" <<'EOF'
policy_module(myapp, 1.0.0)

#############################################
# Domain seed — types, labels, systemd transition only.
# Allows come from AVC generation (dev_generate_policy.sh --apply).
#############################################

type myapp_t;
type myapp_exec_t;
type myapp_var_lib_t;
type myapp_script_exec_t;
type myapp_backend_t;
type myapp_backend_exec_t;

files_type(myapp_exec_t)
files_type(myapp_var_lib_t)
files_type(myapp_script_exec_t)
files_type(myapp_backend_exec_t)

init_daemon_domain(myapp_t, myapp_exec_t)
init_daemon_domain(myapp_backend_t, myapp_backend_exec_t)

require {
    type init_t;
    class process { transition dyntransition siginh rlimitinh };
    class file entrypoint;
}

# systemd (init_t) -> myapp_t / myapp_backend_t when executing the labeled entrypoint
allow init_t myapp_exec_t:file { execute read open getattr map ioctl execute_no_trans };
allow init_t myapp_t:process { transition dyntransition siginh rlimitinh };
allow myapp_t myapp_exec_t:file entrypoint;
type_transition init_t myapp_exec_t:process myapp_t;

allow init_t myapp_backend_exec_t:file { execute read open getattr map ioctl execute_no_trans };
allow init_t myapp_backend_t:process { transition dyntransition siginh rlimitinh };
allow myapp_backend_t myapp_backend_exec_t:file entrypoint;
type_transition init_t myapp_backend_exec_t:process myapp_backend_t;
EOF

cat >"${SELINUX_DIR}/myapp.fc" <<'EOF'
/opt/myapp/app\.py                         gen_context(system_u:object_r:myapp_exec_t,s0)
/opt/myapp/backend_stub\.py                gen_context(system_u:object_r:myapp_backend_exec_t,s0)
/opt/myapp/bin/.*                          gen_context(system_u:object_r:myapp_script_exec_t,s0)
/opt/myapp/venv(/.*)?                      gen_context(system_u:object_r:myapp_exec_t,s0)
/var/opt/myapp/app\.py                     gen_context(system_u:object_r:myapp_exec_t,s0)
/var/opt/myapp/backend_stub\.py            gen_context(system_u:object_r:myapp_backend_exec_t,s0)
/var/opt/myapp/bin/.*                      gen_context(system_u:object_r:myapp_script_exec_t,s0)
/var/opt/myapp/venv(/.*)?                  gen_context(system_u:object_r:myapp_exec_t,s0)
/var/lib/myapp(/.*)?                       gen_context(system_u:object_r:myapp_var_lib_t,s0)
/run/myapp(/.*)?                           gen_context(system_u:object_r:myapp_var_lib_t,s0)
EOF

printf '%s\n' '1.0.0' >"${SELINUX_DIR}/policy_version.txt"

echo "[INFO] Wrote ${SELINUX_DIR}/myapp.te, myapp.fc, policy_version.txt (domain seed 1.0.0)"

if [[ "${LOAD}" -ne 1 ]]; then
    exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] --load requires root (sudo bash scripts/write_domain_seed.sh --load)" >&2
    exit 1
fi

# shellcheck source=lib/compile_policy.sh
source "${SCRIPT_DIR}/lib/compile_policy.sh"

if command -v semanage >/dev/null 2>&1; then
    semanage port -d -t myapp_port_t -p tcp 8888 2>/dev/null || true
    semanage port -d -t myapp_backend_port_t -p tcp 8889 2>/dev/null || true
fi
for mod in myapp_ports myapp_canary myapp; do
    semodule -r "${mod}" 2>/dev/null || true
done
if command -v semanage >/dev/null 2>&1; then
    semanage port -d -t myapp_port_t -p tcp 8888 2>/dev/null || true
    semanage port -d -t myapp_backend_port_t -p tcp 8889 2>/dev/null || true
fi

POLICY_MODULE=myapp bash "${SCRIPT_DIR}/compile_and_validate.sh" "${SELINUX_DIR}"
semodule -i "${SELINUX_DIR}/myapp.pp"

if command -v semanage >/dev/null 2>&1; then
    semanage permissive -a myapp_t 2>/dev/null || true
    semanage permissive -a myapp_backend_t 2>/dev/null || true
fi

restorecon -Rv /opt/myapp /var/lib/myapp /var/log/myapp /run/myapp 2>/dev/null || true
systemctl restart myapp-backend.service myapp.service 2>/dev/null || true
echo "[INFO] Loaded domain seed; myapp_t is permissive via semanage (not in the .te)"
