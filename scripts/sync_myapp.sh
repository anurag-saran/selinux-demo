#!/usr/bin/env bash
#
# sync_myapp.sh — Clone github.com/anurag-saran/myapp if needed, rsync to rhel-qa.
#
# The application GitHub repo holds Flask + selinux/. This tool repo stays
# the generator / AAP path. Run from the Mac (Ansible controller).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/app_root.sh
source "${SCRIPT_DIR}/lib/app_root.sh"

MYAPP_REPO_URL="${MYAPP_REPO_URL:-https://github.com/anurag-saran/myapp.git}"
DEV_HOST="${DEV_HOST:-192.168.64.6}"
DEV_USER="${ANSIBLE_SSH_USER:-ansible}"
TARGET="${DEV_USER}@${DEV_HOST}"
REMOTE_DEST="${MYAPP_REMOTE_DEST:-myapp}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o LogLevel=ERROR)

if [[ -z "${APP_ROOT:-}" ]]; then
    APP_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)/myapp"
fi

usage() {
    cat <<EOF
Usage: $(basename "$0") [user@host]

Clone ${MYAPP_REPO_URL} to ${APP_ROOT} if that directory is missing,
then rsync it to ${TARGET}:~/${REMOTE_DEST}/.

Override: MYAPP_ROOT / APP_ROOT, MYAPP_REPO_URL, DEV_HOST, ANSIBLE_SSH_USER.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *)
            TARGET="$1"
            shift
            ;;
    esac
done

if [[ ! -d "${APP_ROOT}/.git" ]]; then
    if [[ -e "${APP_ROOT}" && ! -d "${APP_ROOT}" ]]; then
        echo "APP_ROOT exists and is not a directory: ${APP_ROOT}" >&2
        exit 1
    fi
    echo "Cloning ${MYAPP_REPO_URL} -> ${APP_ROOT}"
    git clone "${MYAPP_REPO_URL}" "${APP_ROOT}"
fi

if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync not found on this controller" >&2
    exit 1
fi

ssh "${SSH_OPTS[@]}" "${TARGET}" "command -v rsync >/dev/null || sudo dnf install -y rsync"
ssh "${SSH_OPTS[@]}" "${TARGET}" "mkdir -p $(printf '%q' "${REMOTE_DEST}")"
ssh "${SSH_OPTS[@]}" "${TARGET}" \
    'sudo chown -R "$(id -un):$(id -gn)" ~/myapp 2>/dev/null || true'

rsync -az --delete \
    -e "ssh ${SSH_OPTS[*]}" \
    --exclude '.git/' \
    --exclude '.cursor/' \
    --exclude 'policy_out/' \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    --exclude '.DS_Store' \
    --exclude 'selinux/*.pp' \
    "${APP_ROOT}/" "${TARGET}:${REMOTE_DEST}/"

echo "Synced ${APP_ROOT} -> ${TARGET}:${REMOTE_DEST}/"
