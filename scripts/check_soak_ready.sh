#!/usr/bin/env bash
#
# check_soak_ready.sh — Gate production enforce on soak duration + AVC count
#
set -euo pipefail

DOMAIN="${SELINUX_DOMAIN:-myapp_t}"
MARKER_FILE="${SOAK_MARKER_FILE:-/var/myapp/selinux_canary_deployed_at}"
MIN_DAYS="${SOAK_MIN_DAYS:-7}"
MAX_AVC="${SOAK_MAX_AVC:-0}"
SKIP_SELINUX="${SKIP_SELINUX:-0}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Exit 0 when canary soak period elapsed and domain AVC count is within threshold.

Options:
  --domain NAME         SELinux domain (default: myapp_t)
  --marker-file PATH    Canary deploy timestamp file (epoch seconds)
  --min-days N          Minimum soak days (default: 7)
  --max-avc N           Maximum allowed AVC lines since canary (default: 0)
  --skip-if-unavailable Exit 0 when marker or audit tools missing (CI smoke)
  -h, --help            Show help
EOF
}

SKIP_IF_UNAVAILABLE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        --marker-file) MARKER_FILE="$2"; shift 2 ;;
        --min-days) MIN_DAYS="$2"; shift 2 ;;
        --max-avc) MAX_AVC="$2"; shift 2 ;;
        --skip-if-unavailable) SKIP_IF_UNAVAILABLE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

if [[ "${SKIP_SELINUX}" == "1" ]]; then
    log_info "SKIP_SELINUX=1 — skipping soak gate"
    exit 0
fi

if [[ ! -f "${MARKER_FILE}" ]]; then
    if [[ "${SKIP_IF_UNAVAILABLE}" -eq 1 ]]; then
        log_info "Marker file missing — skipping soak check"
        exit 0
    fi
    log_error "Canary marker not found: ${MARKER_FILE} (run deploy_canary.yml first)"
    exit 1
fi

deploy_epoch="$(tr -d '[:space:]' < "${MARKER_FILE}")"
if ! [[ "${deploy_epoch}" =~ ^[0-9]+$ ]]; then
    log_error "Invalid epoch in marker file: ${MARKER_FILE}"
    exit 1
fi

read -r days_elapsed avc_count <<EOF
$(python3 - "${deploy_epoch}" "${MIN_DAYS}" "${MAX_AVC}" "${DOMAIN}" "${MARKER_FILE}" <<'PY'
import datetime
import re
import subprocess
import sys

deploy_epoch = int(sys.argv[1])
min_days = int(sys.argv[2])
max_avc = int(sys.argv[3])
domain = sys.argv[4]
marker_file = sys.argv[5]

now = datetime.datetime.now(datetime.timezone.utc)
deploy = datetime.datetime.fromtimestamp(deploy_epoch, tz=datetime.timezone.utc)
days = (now - deploy).total_seconds() / 86400.0

avc_count = 0
deploy_local = deploy.astimezone()
ts = deploy_local.strftime("%m/%d/%Y %H:%M:%S")
try:
    proc = subprocess.run(
        ["ausearch", "-m", "avc", "-ts", ts],
        capture_output=True,
        text=True,
        check=False,
    )
    text = proc.stdout or ""
    avc_count = sum(1 for line in text.splitlines() if domain in line)
except FileNotFoundError:
    # Fallback: grep audit.log since marker epoch (best effort)
    try:
        with open("/var/log/audit/audit.log", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if "type=AVC" in line and domain in line:
                    avc_count += 1
    except OSError:
        avc_count = -1

print(int(days), avc_count)
PY
)
EOF

log_info "Soak: ${days_elapsed} day(s) elapsed (minimum ${MIN_DAYS})"
log_info "AVCs since canary deploy for ${DOMAIN}: ${avc_count} (maximum ${MAX_AVC})"

if [[ "${days_elapsed}" -lt "${MIN_DAYS}" ]]; then
    log_error "Soak period not met — wait $((MIN_DAYS - days_elapsed)) more day(s) or use force_enforce=true (break-glass only)"
    exit 1
fi

if [[ "${avc_count}" -lt 0 ]]; then
    if [[ "${SKIP_IF_UNAVAILABLE}" -eq 1 ]]; then
        log_info "Audit tools unavailable — treating AVC count as 0 for this check"
        avc_count=0
    else
        log_error "Could not determine AVC count (install audit / ensure auditd running)"
        exit 1
    fi
fi

if [[ "${avc_count}" -gt "${MAX_AVC}" ]]; then
    log_error "Too many AVC denials since canary deploy (${avc_count} > ${MAX_AVC})"
    exit 1
fi

log_info "Soak gate passed — safe to enforce ${DOMAIN}"
