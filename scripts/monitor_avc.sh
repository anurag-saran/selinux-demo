#!/usr/bin/env bash
#
# monitor_avc.sh — Daily AVC report for permissive soak monitoring
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/avc_query.sh
source "${SCRIPT_DIR}/lib/avc_query.sh"
# shellcheck source=lib/manifest_shell.sh
source "${SCRIPT_DIR}/lib/manifest_shell.sh"

DOMAIN="${SELINUX_DOMAIN:-}"
PATHS="${MONITOR_PATHS:-}"
SINCE="${MONITOR_SINCE:-recent}"
MAX_AVC="${MONITOR_MAX_AVC:--1}"
MAX_NET_NEW="${MONITOR_MAX_NET_NEW:--1}"
SHOW_LINES="${MONITOR_SHOW_LINES:-10}"
MARKER_FILE="${SOAK_MARKER_FILE:-}"
MANIFEST="${APP_MANIFEST:-}"
POLICY_KERN="${POLICY_KERN:-/sys/fs/selinux/policy}"
DOMAIN_CLI=0
PATHS_CLI=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Report SELinux events for a domain during permissive soak. Exit non-zero if count exceeds --max-avc or --max-net-new.

Options:
  --domain NAME         SELinux domain (or use --manifest)
  --paths CSV           Path filter substring list (or use --manifest)
  --manifest PATH       Load domain and paths from app manifest
  --since TS            ausearch -ts value or 'recent' (default: recent; ~10 min window)
  --marker-file PATH    Use canary deploy epoch as ausearch start (overrides --since)
  --max-avc N           Fail if raw count > N (-1 = report only, default)
  --max-net-new N       Fail if net-new access needs > N (-1 = report only, default)
  --policy-kern PATH    Kernel policy for sesearch net-new (-1 default)
  --show-lines N        Print last N matching lines (default: 10)
  --format FORMAT       Output format: text (default) or json
  --notify-webhook URL  POST JSON summary to webhook on failure
  --skip-if-unavailable Exit 0 when audit tools unavailable (CI smoke)
  -h, --help            Show help
EOF
}

SKIP_IF_UNAVAILABLE=0
OUTPUT_FORMAT="text"
NOTIFY_WEBHOOK=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="$2"; DOMAIN_CLI=1; shift 2 ;;
        --paths) PATHS="$2"; PATHS_CLI=1; shift 2 ;;
        --manifest) MANIFEST="$2"; shift 2 ;;
        --since) SINCE="$2"; shift 2 ;;
        --marker-file) MARKER_FILE="$2"; shift 2 ;;
        --max-avc) MAX_AVC="$2"; shift 2 ;;
        --max-net-new) MAX_NET_NEW="$2"; shift 2 ;;
        --policy-kern) POLICY_KERN="$2"; shift 2 ;;
        --show-lines) SHOW_LINES="$2"; shift 2 ;;
        --format) OUTPUT_FORMAT="$2"; shift 2 ;;
        --notify-webhook) NOTIFY_WEBHOOK="$2"; shift 2 ;;
        --skip-if-unavailable) SKIP_IF_UNAVAILABLE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

if [[ -z "${MANIFEST}" ]]; then
    MANIFEST="$(resolve_app_manifest_path "" 2>/dev/null || true)"
fi
if [[ -n "${MANIFEST}" && -f "${MANIFEST}" ]]; then
    source_app_manifest_exports "${MANIFEST}"
    [[ "${DOMAIN_CLI}" -eq 0 ]] && DOMAIN="${PRIMARY_DOMAIN}"
    [[ "${PATHS_CLI}" -eq 0 ]] && PATHS="${PATHS_CSV}"
fi

if [[ -z "${DOMAIN}" ]]; then
    log_error "SELinux domain required (--domain or --manifest / APP_MANIFEST)"
    exit 1
fi
if [[ -z "${PATHS}" ]]; then
    log_error "Path filters required (--paths or --manifest with paths.*)"
    exit 1
fi

if [[ -n "${MARKER_FILE}" && -f "${MARKER_FILE}" ]]; then
    deploy_epoch="$(tr -d '[:space:]' < "${MARKER_FILE}")"
    if [[ "${deploy_epoch}" =~ ^[0-9]+$ ]]; then
        SINCE="$(avc_epoch_to_ts "${deploy_epoch}")"
    fi
fi

DOMAINS_CSV="${DOMAIN}"
if [[ -n "${MANIFEST}" && -f "${MANIFEST}" ]]; then
    DOMAINS_CSV="$(python3 "${SCRIPT_DIR}/lib/app_manifest.py" domains-csv "${MANIFEST}" 2>/dev/null || echo "${DOMAIN}")"
fi

raw=""
IFS=',' read -r -a domain_list <<< "${DOMAINS_CSV}"
for d in "${domain_list[@]}"; do
    d="${d// /}"
    [[ -z "${d}" ]] && continue
    chunk="$(fetch_domain_avc_raw "${d}" "${SINCE}")"
    if [[ -n "${chunk}" ]]; then
        raw+="${chunk}"$'\n'
    fi
done

if [[ -z "${raw}" ]] && ! command -v ausearch >/dev/null 2>&1 && [[ ! -f /var/log/audit/audit.log ]]; then
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

net_new_json="$(mktemp)"
net_new_count=-1
avc_fail_closed=0
if [[ ${#matches[@]} -gt 0 ]] && [[ -f "${PROJECT_ROOT}/cli/soak_net_new.py" ]]; then
    manifest_arg=()
    [[ -n "${MANIFEST}" && -f "${MANIFEST}" ]] && manifest_arg=(--manifest "${MANIFEST}")
    if printf '%s\n' "${matches[@]}" | python3 "${PROJECT_ROOT}/cli/soak_net_new.py" \
        "${manifest_arg[@]}" --policy-kern "${POLICY_KERN}" --json-out "${net_new_json}" >/dev/null 2>&1; then
        net_new_count="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("net_new_count",-1))' "${net_new_json}")"
        avc_fail_closed="$(python3 -c 'import json,sys; print(1 if json.load(open(sys.argv[1])).get("fail_closed") else 0)' "${net_new_json}")"
    else
        avc_fail_closed=1
    fi
elif [[ -f "${SCRIPT_DIR}/lib/soak_net_new.py" ]]; then
    manifest_arg=()
    [[ -n "${MANIFEST}" && -f "${MANIFEST}" ]] && manifest_arg=(--manifest "${MANIFEST}")
    if printf '%s\n' "${matches[@]}" | python3 "${SCRIPT_DIR}/lib/soak_net_new.py" \
        "${manifest_arg[@]}" --policy-kern "${POLICY_KERN}" --json-out "${net_new_json}" >/dev/null 2>&1; then
        net_new_count="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("net_new_count",-1))' "${net_new_json}")"
        avc_fail_closed="$(python3 -c 'import json,sys; print(1 if json.load(open(sys.argv[1])).get("fail_closed") else 0)' "${net_new_json}")"
    else
        avc_fail_closed=1
    fi
fi

if [[ "${OUTPUT_FORMAT}" == "json" ]]; then
    MON_DOMAIN="${DOMAIN}" MON_SINCE="${SINCE}" MON_COUNT="${count}" \
        MON_MAX_AVC="${MAX_AVC}" MON_MAX_NET_NEW="${MAX_NET_NEW}" \
        MON_NET_NEW="${net_new_count}" MON_FAIL_CLOSED="${avc_fail_closed}" \
        python3 - "${net_new_json}" <<'PY'
import json, sys, os

net_path = sys.argv[1]
extra = {}
if os.path.isfile(net_path) and os.path.getsize(net_path) > 0:
    extra = json.load(open(net_path, encoding="utf-8"))

out = {
    "domain": os.environ["MON_DOMAIN"],
    "since": os.environ["MON_SINCE"],
    "count": int(os.environ["MON_COUNT"]),
    "max_avc": int(os.environ["MON_MAX_AVC"]),
    "max_net_new": int(os.environ["MON_MAX_NET_NEW"]),
    "net_new_count": int(os.environ.get("MON_NET_NEW", "-1")),
    "avc_fail_closed": os.environ.get("MON_FAIL_CLOSED", "0") == "1",
    "exceptions": extra.get("exceptions", [])[:20],
    "status": "pass",
}
if out["max_avc"] >= 0 and out["count"] > out["max_avc"]:
    out["status"] = "fail"
if (
    out["max_net_new"] >= 0
    and out["net_new_count"] >= 0
    and not out["avc_fail_closed"]
    and out["net_new_count"] > out["max_net_new"]
):
    out["status"] = "fail"
print(json.dumps(out, indent=2))
PY
else
    log_info "AVC report: domain=${DOMAIN} since=${SINCE} count=${count} net_new=${net_new_count}"
fi

rm -f "${net_new_json}"

if [[ "${OUTPUT_FORMAT}" != "json" && "${SHOW_LINES}" -gt 0 && "${count}" -gt 0 ]]; then
    echo "--- recent matching event lines ---"
    start=$(( count > SHOW_LINES ? count - SHOW_LINES : 0 ))
    for ((i=start; i<count; i++)); do
        echo "${matches[$i]}"
    done
fi

fail=0
if [[ "${MAX_AVC}" -ge 0 && "${count}" -gt "${MAX_AVC}" ]]; then
    log_error "Event count ${count} exceeds threshold ${MAX_AVC}"
    fail=1
fi
if [[ "${MAX_NET_NEW}" -ge 0 && "${net_new_count}" -ge 0 && "${avc_fail_closed}" -eq 0 && "${net_new_count}" -gt "${MAX_NET_NEW}" ]]; then
    log_error "Net-new access needs ${net_new_count} exceed threshold ${MAX_NET_NEW}"
    fail=1
fi
if [[ "${fail}" -eq 1 ]]; then
    if [[ -n "${NOTIFY_WEBHOOK}" ]]; then
        curl -sf -X POST -H "Content-Type: application/json" \
            -d "{\"text\":\"SELinux AVC alert: domain=${DOMAIN} count=${count} net_new=${net_new_count}\"}" \
            "${NOTIFY_WEBHOOK}" >/dev/null 2>&1 || true
    fi
    exit 1
fi

if [[ "${OUTPUT_FORMAT}" != "json" ]]; then
    log_info "AVC monitoring check complete"
fi
