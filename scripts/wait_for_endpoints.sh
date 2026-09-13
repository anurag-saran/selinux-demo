#!/usr/bin/env bash
#
# wait_for_endpoints.sh — Unified service + HTTP endpoint readiness checks.
#
set -euo pipefail

HOST="127.0.0.1"
RETRIES=15
DELAY=2
JSON=0
CHECK_SYSTEMD=1
CHECK_DOMAIN=1
APP_DOMAIN="${SELINUX_APP_DOMAIN:-myapp_t}"
BACKEND_DOMAIN="${SELINUX_BACKEND_DOMAIN:-myapp_backend_t}"
ENDPOINTS=(
    /
    /save-log
    /run-script
    /rotate-log
    /probe-backend
    /notify-socket
)

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Wait for myapp + myapp-backend systemd units and HTTP endpoints.
Verifies each service MainPID runs in the expected SELinux domain.

Options:
  --host HOST         HTTP host (default: 127.0.0.1)
  --retries N         Attempts per check (default: 15)
  --delay SEC         Seconds between attempts (default: 2)
  --json              Print JSON result on stdout
  --skip-systemd      Skip systemctl active checks
  --skip-domain-check Skip SELinux domain verification
  --app-domain TYPE   Expected app domain (default: myapp_t)
  --backend-domain TYPE Expected backend domain (default: myapp_backend_t)
  -h, --help          Show help

Exit codes:
  0  all checks passed
  1  systemd service not active
  2  endpoint HTTP failure
  3  timeout / usage
  4  SELinux domain mismatch
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --retries) RETRIES="$2"; shift 2 ;;
        --delay) DELAY="$2"; shift 2 ;;
        --json) JSON=1; shift ;;
        --skip-systemd) CHECK_SYSTEMD=0; shift ;;
        --skip-domain-check) CHECK_DOMAIN=0; shift ;;
        --app-domain) APP_DOMAIN="$2"; shift 2 ;;
        --backend-domain) BACKEND_DOMAIN="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 3 ;;
    esac
done

wait_systemd() {
    local unit="$1"
    local attempt
    for ((attempt = 1; attempt <= RETRIES; attempt++)); do
        if systemctl is-active --quiet "${unit}" 2>/dev/null; then
            return 0
        fi
        sleep "${DELAY}"
    done
    log_error "systemd unit not active: ${unit}"
    systemctl status "${unit}" --no-pager 2>/dev/null | head -15 || true
    return 1
}

service_domain() {
    local unit="$1"
    local pid ctx

    pid="$(systemctl show -p MainPID --value "${unit}" 2>/dev/null || echo 0)"
    if [[ -z "${pid}" || "${pid}" -le 0 ]]; then
        echo "unknown"
        return 1
    fi
    ctx="$(ps -o label= -p "${pid}" 2>/dev/null | awk '{print $1}' | awk -F: '{print $3}')"
    if [[ -z "${ctx}" ]]; then
        echo "unknown"
        return 1
    fi
    echo "${ctx}"
}

verify_service_domain() {
    local unit="$1"
    local expected="$2"
    local observed attempt

    for ((attempt = 1; attempt <= RETRIES; attempt++)); do
        observed="$(service_domain "${unit}" || true)"
        if [[ "${observed}" == "${expected}" ]]; then
            log_info "${unit} running as ${expected} (pid domain verified)"
            echo "${observed}"
            return 0
        fi
        sleep "${DELAY}"
    done

    log_error "FATAL: ${unit} running as ${observed:-unknown}, not ${expected}"
    return 4
}

wait_http() {
    local path="$1"
    local url="http://${HOST}:8888${path}"
    local attempt code
    for ((attempt = 1; attempt <= RETRIES; attempt++)); do
        code="$(curl -sf -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || echo "000")"
        if [[ "${code}" == "200" ]]; then
            ENDPOINT_CODES["${path}"]=200
            return 0
        fi
        ENDPOINT_CODES["${path}"]="${code}"
        sleep "${DELAY}"
    done
    log_error "endpoint not ready: ${path} (last HTTP ${code})"
    return 2
}

wait_backend_health() {
    local attempt code
    for ((attempt = 1; attempt <= RETRIES; attempt++)); do
        code="$(curl -sf -o /dev/null -w '%{http_code}' "http://${HOST}:8889/health" 2>/dev/null || echo "000")"
        if [[ "${code}" == "200" ]]; then
            return 0
        fi
        sleep "${DELAY}"
    done
    log_error "backend health not ready on :8889 (last HTTP ${code})"
    return 2
}

declare -A ENDPOINT_CODES=()
declare -A SERVICE_STATUS=()
APP_DOMAIN_OBSERVED="unknown"
BACKEND_DOMAIN_OBSERVED="unknown"

if [[ "${CHECK_SYSTEMD}" -eq 1 ]]; then
    for unit in myapp-backend.service myapp.service; do
        if ! wait_systemd "${unit}"; then
            SERVICE_STATUS["${unit}"]="inactive"
            [[ "${JSON}" -eq 1 ]] && python3 - <<PY
import json
print(json.dumps({"status": "fail", "reason": "systemd", "services": {"${unit}": "inactive"}}, indent=2))
PY
            exit 1
        fi
        SERVICE_STATUS["${unit}"]="active"
    done
fi

if [[ "${CHECK_DOMAIN}" -eq 1 ]]; then
    if ! BACKEND_DOMAIN_OBSERVED="$(verify_service_domain myapp-backend.service "${BACKEND_DOMAIN}")"; then
        exit 4
    fi
    if ! APP_DOMAIN_OBSERVED="$(verify_service_domain myapp.service "${APP_DOMAIN}")"; then
        exit 4
    fi
fi

if ! wait_backend_health; then
    [[ "${JSON}" -eq 1 ]] && python3 - <<'PY'
import json
print(json.dumps({"status": "fail", "reason": "backend_health"}, indent=2))
PY
    exit 2
fi

for path in "${ENDPOINTS[@]}"; do
    if ! wait_http "${path}"; then
        if [[ "${JSON}" -eq 1 ]]; then
            python3 - "${ENDPOINT_CODES[@]}" <<'PY'
import json, sys
paths = ["/", "/save-log", "/run-script", "/rotate-log", "/probe-backend", "/notify-socket"]
codes = sys.argv[1:]
print(json.dumps({"status": "fail", "reason": "endpoint", "endpoints": dict(zip(paths, codes))}, indent=2))
PY
        fi
        exit 2
    fi
done

log_info "All endpoints ready on ${HOST}:8888 (${#ENDPOINTS[@]} checks)"

if [[ "${JSON}" -eq 1 ]]; then
    python3 - "${APP_DOMAIN_OBSERVED}" "${BACKEND_DOMAIN_OBSERVED}" <<'PY'
import json, sys
app_ctx, backend_ctx = sys.argv[1], sys.argv[2]
endpoints = {
    "/": 200,
    "/save-log": 200,
    "/run-script": 200,
    "/rotate-log": 200,
    "/probe-backend": 200,
    "/notify-socket": 200,
}
print(json.dumps({
    "status": "pass",
    "endpoints": endpoints,
    "domain_context": {
        "myapp.service": app_ctx,
        "myapp-backend.service": backend_ctx,
    },
}, indent=2))
PY
fi

exit 0
