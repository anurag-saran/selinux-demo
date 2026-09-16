#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}/ansible"

for pb in deploy_canary.yml enforce_production.yml emergency_rollback.yml \
    reset_host_state.yml soak_monitor.yml soak_status.yml; do
    ansible-playbook --syntax-check "${pb}"
done

echo "ansible syntax-check OK"
