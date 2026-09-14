#!/usr/bin/env bash
#
# blast_radius_collect.sh — Diff sesearch rule lines between two installed modules.
# Invoked inside a CentOS Stream container (not on host).
#
set -euo pipefail

MODULE="${BLAST_RADIUS_MODULE:-myapp}"
BASE_PP="${1:?base.pp path}"
CAND_PP="${2:?candidate.pp path}"
OUT_DIR="${3:?output dir}"
mkdir -p "${OUT_DIR}"

KERN="/var/lib/selinux/targeted/active/policy.kern"

collect_side() {
    local pp="$1"
    local allow_out="$2"
    local type_out="$3"
    semodule -r "${MODULE}" 2>/dev/null || true
    semodule -i "${pp}"
    [[ -f "${KERN}" ]] || {
        echo "blast_radius_collect: missing ${KERN} after semodule -i ${pp}" >&2
        return 1
    }
    local errf
    errf="$(mktemp)"
    sesearch --allow "${KERN}" >"${allow_out}" 2>"${errf}"
    local ec=$?
    if [[ -s "${errf}" ]]; then
        cat "${errf}" >&2
        rm -f "${errf}"
        return 1
    fi
    if [[ ${ec} -ne 0 && ${ec} -ne 1 ]]; then
        rm -f "${errf}"
        return "${ec}"
    fi
    rm -f "${errf}"
    : > "${type_out}"
    errf="$(mktemp)"
    sesearch -T "${KERN}" >"${type_out}" 2>"${errf}"
    ec=$?
    if [[ -s "${errf}" ]]; then
        cat "${errf}" >&2
        rm -f "${errf}"
        return 1
    fi
    if [[ ${ec} -ne 0 && ${ec} -ne 1 ]]; then
        rm -f "${errf}"
        return "${ec}"
    fi
    rm -f "${errf}"
    sort -u -o "${allow_out}" "${allow_out}"
    sort -u -o "${type_out}" "${type_out}"
}

collect_side "${BASE_PP}" "${OUT_DIR}/base_allow.txt" "${OUT_DIR}/base_type.txt"
collect_side "${CAND_PP}" "${OUT_DIR}/cand_allow.txt" "${OUT_DIR}/cand_type.txt"
semodule -r "${MODULE}" 2>/dev/null || true

comm -23 "${OUT_DIR}/cand_allow.txt" "${OUT_DIR}/base_allow.txt" > "${OUT_DIR}/added_allow.txt"
comm -23 "${OUT_DIR}/cand_type.txt" "${OUT_DIR}/base_type.txt" > "${OUT_DIR}/added_type.txt"
{
    cat "${OUT_DIR}/added_type.txt"
    cat "${OUT_DIR}/added_allow.txt"
} > "${OUT_DIR}/added_all.txt"
