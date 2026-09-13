#!/bin/bash
# Dummy backup script executed by the Order Processor App.
# Labeled myapp_script_exec_t after restorecon; exec from myapp_t triggers
# an AVC until domain transition / execute allow rules are in policy.

set -euo pipefail

BACKUP_LOG="/var/lib/myapp/backup.log"
TIMESTAMP="$(printf '%(%Y-%m-%dT%H:%M:%SZ)T' -1)"

# /var/lib/myapp is created at install time; append only (no bin_t helpers).
echo "[${TIMESTAMP}] backup ran" >> "${BACKUP_LOG}"
echo "backup completed"
