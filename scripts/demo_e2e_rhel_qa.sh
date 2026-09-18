#!/usr/bin/env bash
# Talk track for the QA VM. Same as demo_e2e_rhel_dev.sh (legacy name).
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/demo_e2e_rhel_dev.sh" "$@"
