#!/usr/bin/env bash
#
# post_deploy_report.sh — Structured deploy/rollback feedback artifact.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PHASE="${DEPLOY_PHASE:-unknown}"
HOST="$(hostname -s 2>/dev/null || hostname)"
DOMAIN="${SELINUX_DOMAIN:-myapp_t}"
VAR_DIR="${VAR_DIR:-/var/myapp}"
MARKER_FILE="${SOAK_MARKER_FILE:-${VAR_DIR}/selinux_canary_deployed_at}"
REPORT_FILE="${DEPLOY_REPORT_FILE:-${VAR_DIR}/selinux_deploy_report.json}"
POLICY_VERSION_FILE="${PROJECT_ROOT}/selinux/policy_version.txt"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Write ${VAR_DIR}/selinux_deploy_report.json with deploy health summary.

Options:
  --phase NAME          canary | enforce | rollback (required)
  --host NAME           Host label (default: short hostname)
  --domain NAME         SELinux domain (default: myapp_t)
  --var-dir PATH        Data directory (default: /var/myapp)
  --marker-file PATH    Soak marker for AVC/day calculations
  --report-file PATH    Output JSON path
  --project-root PATH   Repo root for policy version lookup
  -h, --help            Show help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase) PHASE="$2"; shift 2 ;;
        --host) HOST="$2"; shift 2 ;;
        --domain) DOMAIN="$2"; shift 2 ;;
        --var-dir) VAR_DIR="$2"; shift 2 ;;
        --marker-file) MARKER_FILE="$2"; shift 2 ;;
        --report-file) REPORT_FILE="$2"; shift 2 ;;
        --project-root) PROJECT_ROOT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

[[ "${PHASE}" != "unknown" ]] || { log_error "--phase is required"; usage; exit 1; }

policy_version="unknown"
if [[ -f "${POLICY_VERSION_FILE}" ]]; then
    policy_version="$(tr -d '[:space:]' < "${POLICY_VERSION_FILE}")"
fi

selinux_mode="$(getenforce 2>/dev/null || echo unknown)"
domain_permissive="null"
if command -v semanage >/dev/null 2>&1; then
    if semanage permissive -l 2>/dev/null | grep -qw "${DOMAIN}"; then
        domain_permissive="true"
    else
        domain_permissive="false"
    fi
fi

myapp_state="$(systemctl is-active myapp.service 2>/dev/null || echo unknown)"
backend_state="$(systemctl is-active myapp-backend.service 2>/dev/null || echo unknown)"

endpoint_tmp="$(mktemp)"
if bash "${SCRIPT_DIR}/wait_for_endpoints.sh" --host 127.0.0.1 --retries 5 --delay 1 --json > "${endpoint_tmp}" 2>/dev/null; then
    endpoint_status="pass"
else
    echo '{"status":"fail","endpoints":{}}' > "${endpoint_tmp}"
    endpoint_status="fail"
fi

avc_count=0
if [[ -f "${MARKER_FILE}" ]]; then
    avc_json="$(bash "${SCRIPT_DIR}/monitor_avc.sh" \
        --domain "${DOMAIN}" \
        --marker-file "${MARKER_FILE}" \
        --max-avc -1 \
        --show-lines 0 \
        --format json 2>/dev/null || echo '{"count":0}')"
    avc_count="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("count",0))' <<< "${avc_json}" 2>/dev/null || echo 0)"
fi

soak_days=0
if [[ -f "${MARKER_FILE}" ]]; then
    deploy_epoch="$(tr -d '[:space:]' < "${MARKER_FILE}")"
    if [[ "${deploy_epoch}" =~ ^[0-9]+$ ]]; then
        now_epoch="$(date +%s)"
        soak_days=$(( (now_epoch - deploy_epoch) / 86400 ))
    fi
fi

overall_status="pass"
if [[ "${myapp_state}" != "active" || "${backend_state}" != "active" || "${endpoint_status}" != "pass" ]]; then
    overall_status="fail"
fi

mkdir -p "$(dirname "${REPORT_FILE}")"

python3 - "${endpoint_tmp}" <<PY
import json
from datetime import datetime, timezone
from pathlib import Path

endpoint_path = Path("${endpoint_tmp}")
endpoint_data = json.loads(endpoint_path.read_text(encoding="utf-8"))
domain_permissive = ${domain_permissive}

report = {
    "phase": "${PHASE}",
    "policy_version": "${policy_version}",
    "host": "${HOST}",
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "selinux_mode": "${selinux_mode}",
    "domain": "${DOMAIN}",
    "domain_permissive": domain_permissive,
    "services": {
        "myapp": "${myapp_state}",
        "myapp-backend": "${backend_state}",
    },
    "endpoints": endpoint_data.get("endpoints", {}),
    "avc_count_since_marker": int("${avc_count}"),
    "soak_days_elapsed": int("${soak_days}"),
    "status": "${overall_status}",
    "report_file": "${REPORT_FILE}",
}
Path("${REPORT_FILE}").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
print(json.dumps(report, indent=2))
PY

rm -f "${endpoint_tmp}"

log_info "Wrote deploy report: ${REPORT_FILE} (status=${overall_status})"

[[ "${overall_status}" == "pass" ]]
