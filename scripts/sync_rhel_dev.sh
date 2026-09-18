#!/usr/bin/env bash
#
# sync_rhel_dev.sh — Copy this checkout to the QA VM over SSH (rsync).
#
# rhel-qa often has a tree that is not a git clone. The Mac talk track uses
# this instead of `git pull`. Does not copy gitignored inventories or sudo-owned
# policy_out/dist build dirs.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEV_HOST="${DEV_HOST:-192.168.64.6}"
DEV_USER="${ANSIBLE_SSH_USER:-ansible}"
TARGET="${DEV_USER}@${DEV_HOST}"
REMOTE_DEST="selinux-pac"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o LogLevel=ERROR)

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dest PATH] [user@host]

Sync repo root to PATH on the QA VM (default: ~/selinux-pac on ${DEV_USER}@${DEV_HOST}).
--dest may be a home-relative path (selinux-pac) or an absolute path (/tmp/selinux-pac-rpm).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --dest) REMOTE_DEST="$2"; shift 2 ;;
        *)
            TARGET="$1"
            shift
            ;;
    esac
done

if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync not found on this controller" >&2
    exit 1
fi

ssh "${SSH_OPTS[@]}" "${TARGET}" "command -v rsync >/dev/null || sudo dnf install -y rsync"
ssh "${SSH_OPTS[@]}" "${TARGET}" "mkdir -p $(printf '%q' "${REMOTE_DEST}")"

# sudo generate/rpmbuild can leave root-owned dirs that block rsync
if [[ "${REMOTE_DEST}" == selinux-pac || "${REMOTE_DEST}" == */selinux-pac ]]; then
    ssh "${SSH_OPTS[@]}" "${TARGET}" \
        'sudo chown -R "$(id -un):$(id -gn)" ~/selinux-pac/selinux ~/selinux-pac/scripts ~/selinux-pac/packaging 2>/dev/null || true'
fi

rsync -az --delete \
    -e "ssh ${SSH_OPTS[*]}" \
    --exclude '.git/' \
    --exclude '.cursor/' \
    --exclude 'ansible/inventory.dev.yml' \
    --exclude 'ansible/inventory.production.yml' \
    --exclude 'policy_out/' \
    --exclude 'dist/' \
    --exclude 'packaging/rpmbuild/' \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    --exclude '.DS_Store' \
    "${PROJECT_ROOT}/" "${TARGET}:${REMOTE_DEST}/"

echo "Synced ${PROJECT_ROOT} -> ${TARGET}:${REMOTE_DEST}/"
