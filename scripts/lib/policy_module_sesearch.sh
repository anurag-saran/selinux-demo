#!/usr/bin/env bash
#
# policy_module_sesearch.sh — Append sorted allow rules for one domain from a policy.kern.
# sesearch exits 1 when no rules match; that is not an error. Non-empty stderr is an error.
#
append_domain_allows() {
    local policy_kern="$1"
    local domain="$2"
    local dest="$3"

    [[ -f "${policy_kern}" ]] || {
        echo "append_domain_allows: missing policy ${policy_kern}" >&2
        return 1
    }

    local chunk errf
    chunk="$(mktemp)"
    errf="$(mktemp)"
    sesearch --allow -s "${domain}" "${policy_kern}" >"${chunk}" 2>"${errf}"
    local ec=$?
    if [[ -s "${errf}" ]]; then
        cat "${errf}" >&2
        rm -f "${chunk}" "${errf}"
        return 1
    fi
    if [[ ${ec} -ne 0 && ${ec} -ne 1 ]]; then
        rm -f "${chunk}" "${errf}"
        return "${ec}"
    fi
    if [[ -s "${chunk}" ]]; then
        sort -u "${chunk}" >> "${dest}"
    fi
    rm -f "${chunk}" "${errf}"
}
