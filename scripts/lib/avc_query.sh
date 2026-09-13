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
