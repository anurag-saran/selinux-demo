#!/usr/bin/env bash
#
# compile_policy.sh — Shared refpolicy Makefile compile (native or Podman).
#
# Source from other scripts:
#   source "${SCRIPT_DIR}/lib/compile_policy.sh"
#
set -euo pipefail

SELINUX_COMPILE_IMAGE="${SELINUX_COMPILE_IMAGE:-quay.io/centos/centos:stream9}"

has_selinux_devel() {
    [[ -f /usr/share/selinux/devel/Makefile ]]
}

compile_policy_module() {
    local policy_dir="$1"
    local module_name="${2:-myapp}"
    local output_pp="${3:-${policy_dir}/${module_name}.pp}"

    local te="${policy_dir}/${module_name}.te"
    local fc="${policy_dir}/${module_name}.fc"

    [[ -f "${te}" && -f "${fc}" ]] || {
        echo "[ERROR] Missing ${te} or ${fc}" >&2
        return 1
    }

    rm -f "${output_pp}" "${policy_dir}/${module_name}.mod"

    if has_selinux_devel; then
        local work_dir
        work_dir="$(mktemp -d)"
        cp "${te}" "${fc}" "${work_dir}/"
        make -C "${work_dir}" -f /usr/share/selinux/devel/Makefile "${module_name}.pp"
        cp "${work_dir}/${module_name}.pp" "${output_pp}"
        rm -rf "${work_dir}"
    elif command -v podman >/dev/null 2>&1; then
        local work_dir
        work_dir="$(mktemp -d)"
        cp "${te}" "${fc}" "${work_dir}/"
        podman run --rm \
            -v "${work_dir}:/build:Z" \
            "${SELINUX_COMPILE_IMAGE}" \
            bash -lc "
                set -euo pipefail
                dnf install -y -q selinux-policy-devel checkpolicy policycoreutils
                make -C /build -f /usr/share/selinux/devel/Makefile ${module_name}.pp
            "
        cp "${work_dir}/${module_name}.pp" "${output_pp}"
        rm -rf "${work_dir}"
    else
        echo "[ERROR] Install selinux-policy-devel or podman for policy compile" >&2
        return 1
    fi
}

verify_pp_matches_sources() {
    local policy_dir="$1"
    local module_name="${2:-myapp}"

    local committed_pp="${policy_dir}/${module_name}.pp"
    local built_pp
    built_pp="$(mktemp)"

    compile_policy_module "${policy_dir}" "${module_name}" "${built_pp}"

    if [[ ! -f "${committed_pp}" ]]; then
        echo "[ERROR] Committed policy package missing: ${committed_pp}" >&2
        rm -f "${built_pp}"
        return 1
    fi

    if ! cmp -s "${committed_pp}" "${built_pp}"; then
        echo "[ERROR] ${committed_pp} drifts from ${module_name}.te/.fc — rebuild and commit" >&2
        rm -f "${built_pp}"
        return 1
    fi

    rm -f "${built_pp}"
    echo "[INFO] ${committed_pp} matches compiled output from sources"
}
