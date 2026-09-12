#!/usr/bin/env bash
#
# monitor_avc.sh — Daily AVC report for permissive soak monitoring
#
set -euo pipefail

DOMAIN="${SELINUX_DOMAIN:-myapp_t}"
PATHS="${MONITOR_PATHS:-/opt/myapp,/var/myapp}"
SINCE="${MONITOR_SINCE:-recent}"
MAX_AVC="${MONITOR_MAX_AVC:--1}"
SHOW_LINES="${MONITOR_SHOW_LINES:-10}"
MARKER_FILE="${SOAK_MARKER_FILE:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Report AVC denials for a domain during permissive soak. Exit non-zero if count exceeds --max-avc.

Options:
  --domain NAME         SELinux domain (default: myapp_t)
  --paths CSV           Path filter substring list (default: /opt/myapp,/var/myapp)
  --since TS            ausearch -ts value or 'recent' (default: recent)
  --marker-file PATH    Use canary deploy epoch as ausearch start (overrides --since)
  --max-avc N           Fail if count > N (-1 = report only, default)
  --show-lines N        Print last N matching lines (default: 10)
  --skip-if-unavailable Exit 0 when audit tools unavailable (CI smoke)
  -h, --help            Show help
EOF
}

SKIP_IF_UNAVAILABLE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        --paths) PATHS="$2"; shift 2 ;;
        --since) SINCE="$2"; shift 2 ;;
        --marker-file) MARKER_FILE="$2"; shift 2 ;;
        --max-avc) MAX_AVC="$2"; shift 2 ;;
        --show-lines) SHOW_LINES="$2"; shift 2 ;;
        --skip-if-unavailable) SKIP_IF_UNAVAILABLE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

if [[ -n "${MARKER_FILE}" && -f "${MARKER_FILE}" ]]; then
    deploy_epoch="$(tr -d '[:space:]' < "${MARKER_FILE}")"
    if [[ "${deploy_epoch}" =~ ^[0-9]+$ ]]; then
        SINCE="$(python3 - "${deploy_epoch}" <<'PY'
import datetime, sys
deploy = datetime.datetime.fromtimestamp(int(sys.argv[1]), tz=datetime.timezone.utc).astimezone()
print(deploy.strftime("%m/%d/%Y %H:%M:%S"))
PY
)"
    fi
fi

if command -v ausearch >/dev/null 2>&1; then
    raw="$(ausearch -m avc -i -ts "${SINCE}" 2>/dev/null || true)"
elif [[ -f /var/log/audit/audit.log ]]; then
    raw="$(grep '^type=AVC' /var/log/audit/audit.log || true)"
else
    if [[ "${SKIP_IF_UNAVAILABLE}" -eq 1 ]]; then
        log_info "No audit sources available — skipping AVC monitor"
        exit 0
    fi
    log_error "No ausearch or /var/log/audit/audit.log available"
    exit 1
fi

IFS=',' read -r -a path_filters <<< "${PATHS}"
matches=()
while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    [[ "${line}" != *"${DOMAIN}"* ]] && continue
    ok=0
    if [[ ${#path_filters[@]} -eq 0 ]]; then
        ok=1
    else
        for p in "${path_filters[@]}"; do
            p="${p// /}"
            [[ -n "${p}" && "${line}" == *"${p}"* ]] && ok=1 && break
        done
    fi
    [[ "${ok}" -eq 1 ]] && matches+=("${line}")
done <<< "${raw}"

count="${#matches[@]}"
log_info "AVC report: domain=${DOMAIN} since=${SINCE} count=${count}"

if [[ "${SHOW_LINES}" -gt 0 && "${count}" -gt 0 ]]; then
    echo "--- recent matching AVC lines ---"
    start=$(( count > SHOW_LINES ? count - SHOW_LINES : 0 ))
    for ((i=start; i<count; i++)); do
        echo "${matches[$i]}"
    done
fi

if [[ "${MAX_AVC}" -ge 0 && "${count}" -gt "${MAX_AVC}" ]]; then
    log_error "AVC count ${count} exceeds threshold ${MAX_AVC}"
    exit 1
fi

log_info "AVC monitoring check complete"
