#!/usr/bin/env bash
#
# check_soak_ready.sh — Gate production enforce on soak duration + AVC count + deploy coverage
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/avc_query.sh
source "${SCRIPT_DIR}/lib/avc_query.sh"

DOMAIN="${SELINUX_DOMAIN:-myapp_t}"
MARKER_FILE="${SOAK_MARKER_FILE:-/var/lib/myapp/selinux_canary_deployed_at}"
REPORT_FILE="${DEPLOY_REPORT_FILE:-/var/lib/myapp/selinux_deploy_report.json}"
MIN_DAYS="${SOAK_MIN_DAYS:-7}"
MAX_AVC="${SOAK_MAX_AVC:-0}"
SKIP_SELINUX="${SKIP_SELINUX:-0}"
AUTO_TIER="${SOAK_AUTO_TIER:-0}"
APP_DOMAIN="${SELINUX_APP_DOMAIN:-myapp_t}"
BACKEND_DOMAIN="${SELINUX_BACKEND_DOMAIN:-myapp_backend_t}"
MANIFEST=""
POLICY_HISTORY_DIR="${POLICY_HISTORY_DIR:-/var/lib/myapp/policy-history}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Exit 0 when canary soak period elapsed, domain event count is within threshold,
and last deploy report shows endpoint coverage.

Options:
  --domain NAME         SELinux domain (default: myapp_t)
  --marker-file PATH    Canary deploy timestamp file (epoch seconds)
  --report-file PATH    Deploy report JSON (default: /var/lib/myapp/selinux_deploy_report.json)
  --min-days N          Minimum soak days (default: 7)
  --max-avc N           Maximum allowed AVC events since canary (default: 0)
  --auto-tier           Disabled until blast-radius classifier is fixed (PR 2)
  --manifest PATH       App manifest for deploy report domain verification
  --skip-if-unavailable Exit 0 when marker or audit tools missing (CI smoke)
  -h, --help            Show help
EOF
}

SKIP_IF_UNAVAILABLE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        --marker-file) MARKER_FILE="$2"; shift 2 ;;
        --report-file) REPORT_FILE="$2"; shift 2 ;;
        --min-days) MIN_DAYS="$2"; shift 2 ;;
        --max-avc) MAX_AVC="$2"; shift 2 ;;
        --auto-tier) AUTO_TIER=1; shift ;;
        --manifest) MANIFEST="$2"; shift 2 ;;
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

if [[ "${AUTO_TIER}" == "1" || "${SOAK_AUTO_TIER:-0}" == "1" ]]; then
    log_error "--auto-tier is disabled until blast-radius classification is fixed (use fixed soak_min_days, default 7)"
    exit 1
fi

deploy_epoch="$(tr -d '[:space:]' < "${MARKER_FILE}")"
if ! [[ "${deploy_epoch}" =~ ^[0-9]+$ ]]; then
    log_error "Invalid epoch in marker file: ${MARKER_FILE}"
    exit 1
fi

now_epoch="$(date +%s)"
days_elapsed=$(( (now_epoch - deploy_epoch) / 86400 ))
since_ts="$(avc_epoch_to_ts "${deploy_epoch}")"
avc_count="$(count_domain_events_since "${DOMAIN}" "${since_ts}")"

log_info "Soak: ${days_elapsed} day(s) elapsed (minimum ${MIN_DAYS})"
log_info "Events since canary deploy for ${DOMAIN}: ${avc_count} (maximum ${MAX_AVC})"

if [[ "${days_elapsed}" -lt "${MIN_DAYS}" ]]; then
    log_error "Soak period not met — wait $((MIN_DAYS - days_elapsed)) more day(s) or use force_enforce=true (break-glass only)"
    exit 1
fi

if [[ "${avc_count}" == "-1" ]]; then
    if [[ "${SKIP_IF_UNAVAILABLE}" -eq 1 ]]; then
        log_info "Audit tools unavailable — treating event count as 0 for this check"
        avc_count=0
    else
        log_error "Could not determine AVC count (install audit / ensure auditd running)"
        exit 1
    fi
fi

if [[ "${avc_count}" -gt "${MAX_AVC}" ]]; then
    log_error "Too many SELinux events since canary deploy (${avc_count} > ${MAX_AVC})"
    exit 1
fi

if [[ -f "${REPORT_FILE}" ]]; then
    if [[ -z "${MANIFEST}" ]]; then
        MANIFEST="$(python3 "${SCRIPT_DIR}/lib/app_manifest.py" resolve 2>/dev/null || true)"
    fi
    report_ok="$(python3 - "${REPORT_FILE}" "${MANIFEST:-}" <<PY
import json, sys
from pathlib import Path

report = json.loads(open(sys.argv[1], encoding="utf-8").read())
manifest_path = sys.argv[2]

if report.get("status") != "pass":
    print("no")
    raise SystemExit
if not report.get("endpoints_exercised"):
    print("no")
    raise SystemExit
if report.get("domain_context_verified") is True:
    print("yes")
    raise SystemExit
if manifest_path and Path(manifest_path).is_file():
    sys.path.insert(0, "${SCRIPT_DIR}/lib")
    from app_manifest import load_manifest, domain_context_matches
    manifest = load_manifest(Path(manifest_path))
    ctx = report.get("domain_context", {})
    fake = {"domain_context": ctx}
    print("yes" if domain_context_matches(fake, manifest) else "no")
else:
    ctx = report.get("domain_context", {})
    ok = ctx.get("myapp.service") == "${APP_DOMAIN}" and ctx.get("myapp-backend.service") == "${BACKEND_DOMAIN}"
    print("yes" if ok else "no")
PY
)"
    if [[ "${report_ok}" != "yes" ]]; then
        log_error "Deploy report ${REPORT_FILE} missing pass status, endpoint coverage, or domain context (${APP_DOMAIN}/${BACKEND_DOMAIN})"
        exit 1
    fi
    log_info "Deploy report confirms endpoint coverage and domain context"
else
    log_error "Deploy report not found: ${REPORT_FILE}"
    exit 1
fi

log_info "Soak gate passed — safe to enforce ${DOMAIN}"
