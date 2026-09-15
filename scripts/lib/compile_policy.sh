#!/usr/bin/env bash
#
# compile_policy.sh — Shared refpolicy Makefile compile (native or Podman).
#
# Source from other scripts:
#   source "${SCRIPT_DIR}/lib/compile_policy.sh"
#
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=selinux_build_image.sh
source "${LIB_DIR}/selinux_build_image.sh"

has_selinux_devel() {
    [[ -f /usr/share/selinux/devel/Makefile ]]
}

selinux_container_image() {
    if selinux_build_image_ready; then
        echo "${SELINUX_BUILD_IMAGE}"
    else
        echo "${SELINUX_COMPILE_IMAGE}"
    fi
}

run_selinux_container() {
    local mount_src="$1"
    shift
    local img
    img="$(selinux_container_image)"
    if [[ "${img}" == "${SELINUX_COMPILE_IMAGE}" ]]; then
        echo "[WARN] ${SELINUX_BUILD_IMAGE} missing — slow dnf-in-container path. Fix: bash scripts/build_selinux_compile_image.sh" >&2
    fi
    podman run --rm -v "${mount_src}:/work:Z" "${img}" "$@"
}

compile_toolchain_available() {
    has_selinux_devel && return 0
    command -v podman >/dev/null 2>&1
}

compile_policy_module() {
    local policy_dir="$1"
    local module_name="${2:-myapp}"
    local output_pp="${3:-${policy_dir}/${module_name}.pp}"

    local te="${policy_dir}/${module_name}.te"
    local fc="${policy_dir}/${module_name}.fc"
    local if_file="${policy_dir}/${module_name}.if"

    [[ -f "${te}" && -f "${fc}" ]] || {
        echo "[ERROR] Missing ${te} or ${fc}" >&2
        return 1
    }

    rm -f "${output_pp}" "${policy_dir}/${module_name}.mod"

    _copy_module_sources() {
        local dest="$1"
        cp "${te}" "${fc}" "${dest}/"
        if [[ -f "${if_file}" ]]; then
            cp "${if_file}" "${dest}/"
        fi
    }

    if has_selinux_devel; then
        local work_dir
        work_dir="$(mktemp -d)"
        _copy_module_sources "${work_dir}"
        make -C "${work_dir}" -f /usr/share/selinux/devel/Makefile "${module_name}.pp"
        cp "${work_dir}/${module_name}.pp" "${output_pp}"
        rm -rf "${work_dir}"
    elif command -v podman >/dev/null 2>&1; then
        ensure_selinux_build_image || true
        local work_dir
        work_dir="$(mktemp -d)"
        _copy_module_sources "${work_dir}"
        if selinux_build_image_ready; then
            podman run --rm \
                -v "${work_dir}:/build:Z" \
                "${SELINUX_BUILD_IMAGE}" \
                make -C /build -f /usr/share/selinux/devel/Makefile "${module_name}.pp"
        else
            echo "[WARN] ${SELINUX_BUILD_IMAGE} not found — slow path (dnf in container). Build once: bash scripts/build_selinux_compile_image.sh" >&2
            podman run --rm \
                -v "${work_dir}:/build:Z" \
                "${SELINUX_COMPILE_IMAGE}" \
                bash -lc "
                    set -euo pipefail
                    dnf install -y -q selinux-policy-devel checkpolicy policycoreutils
                    make -C /build -f /usr/share/selinux/devel/Makefile ${module_name}.pp
                "
        fi
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
