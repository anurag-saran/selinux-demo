#!/usr/bin/env bash
#
# avc_query.sh — Shared AVC counting for soak/monitor scripts.
#
set -euo pipefail

avc_epoch_to_ts() {
    local deploy_epoch="$1"
    python3 - "${deploy_epoch}" <<'PY'
import datetime, sys
deploy = datetime.datetime.fromtimestamp(int(sys.argv[1]), tz=datetime.timezone.utc).astimezone()
print(deploy.strftime("%m/%d/%Y %H:%M:%S"))
PY
}

count_domain_events_since() {
    local domain="$1"
    local since_ts="$2"

    if ! command -v ausearch >/dev/null 2>&1; then
        echo "-1"
        return 0
    fi

    local count
    count="$(ausearch --input-logs \
        -m AVC,USER_AVC,SELINUX_ERR,USER_SELINUX_ERR \
        -ts "${since_ts}" \
        --subject "${domain}" \
        --format raw 2>/dev/null | grep -c '^type=AVC' || true)"
    echo "${count:-0}"
}

# Filter raw AVC lines by optional path substrings (comma-separated CSV).
avc_filter_lines_by_paths() {
    local paths_csv="$1"
    local -a path_filters=()
    if [[ -n "${paths_csv}" ]]; then
        IFS=',' read -r -a path_filters <<< "${paths_csv}"
    fi
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" != type=AVC* ]] && continue
        if [[ ${#path_filters[@]} -eq 0 ]]; then
            echo "${line}"
            continue
        fi
        for p in "${path_filters[@]}"; do
            p="${p// /}"
            [[ -n "${p}" && "${line}" == *"${p}"* ]] && echo "${line}" && break
        done
    done
}

fetch_domain_avc_raw() {
    local domain="$1"
    local since_ts="$2"

    if command -v ausearch >/dev/null 2>&1; then
        ausearch --input-logs \
            -m AVC,USER_AVC,SELINUX_ERR,USER_SELINUX_ERR \
            -ts "${since_ts}" \
            --subject "${domain}" \
            --format raw 2>/dev/null || true
        return 0
    fi
    if [[ -f /var/log/audit/audit.log ]]; then
        grep -E '^(type=AVC|type=SELINUX_ERR|type=USER_AVC|type=USER_SELINUX_ERR)' /var/log/audit/audit.log \
            | grep "${domain}" || true
    fi
}

# Export app-related AVC lines (same message types / --subject as monitor_avc.sh).
export_app_avcs_to_file() {
    local outfile="$1"
    local since_ts="${2:-boot}"
    local primary_domain="${3:-${SELINUX_DOMAIN:-myapp_t}}"
    local backend_domain="${4:-${SELINUX_BACKEND_DOMAIN:-myapp_backend_t}}"
    local paths_csv="${5:-/opt/myapp,/var/lib/myapp,/var/log/myapp,/run/myapp,/var/opt/myapp}"

    mkdir -p "$(dirname "${outfile}")"
    : > "${outfile}"

    local raw=""
    raw="$(fetch_domain_avc_raw "${primary_domain}" "${since_ts}")"
    if [[ -n "${backend_domain}" && "${backend_domain}" != "${primary_domain}" ]]; then
        raw+=$'\n'
        raw+="$(fetch_domain_avc_raw "${backend_domain}" "${since_ts}")"
    fi

    if [[ -z "${raw}" ]]; then
        return 0
    fi

    printf '%s\n' "${raw}" | avc_filter_lines_by_paths "${paths_csv}" >> "${outfile}" || true
}
