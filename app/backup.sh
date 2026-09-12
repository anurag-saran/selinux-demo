#!/bin/bash
# Dummy backup script executed by the Order Processor App.
# Labeled myapp_script_exec_t after restorecon; exec from myapp_t triggers
# an AVC until domain transition / execute allow rules are in policy.

set -euo pipefail

BACKUP_LOG="/var/myapp/backup.log"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

mkdir -p "$(dirname "${BACKUP_LOG}")"
echo "[${TIMESTAMP}] backup ran" >> "${BACKUP_LOG}"
echo "backup completed"
