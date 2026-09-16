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

# Prepend inline dnf to a bash -lc script (slow-path fallback).
_selinux_wrap_bash_lc_with_dnf() {
    local inner="$1"
    printf 'set -euo pipefail; dnf install -y -q %s; %s' "${SELINUX_CONTAINER_DNF_PKGS}" "${inner}"
}

# Run a command in the prebuilt image, or fall back to inline dnf on bare Stream.
# Usage: run_selinux_container MOUNT_DIR [podman flags...] cmd args...
run_selinux_container() {
    local mount_src="$1"
    shift
    local podman_extra=()
    while [[ $# -gt 0 && "$1" == -* ]]; do
        case "$1" in
            -e | --env)
                podman_extra+=("$1" "$2")
                shift 2
                ;;
            -v | --volume)
                podman_extra+=("$1" "$2")
                shift 2
                ;;
            *)
                podman_extra+=("$1")
                shift
                ;;
        esac
    done
    ensure_selinux_build_image || true
    if selinux_build_image_ready; then
        podman run --rm -v "${mount_src}:/work:Z" "${podman_extra[@]}" "${SELINUX_BUILD_IMAGE}" "$@"
        return $?
    fi
    echo "[WARN] Prebuilt image ${SELINUX_BUILD_IMAGE} unavailable — inline dnf install (slow, needs network). Fix: bash scripts/lib/build_image.sh" >&2
    if [[ "$1" == "bash" && "$2" == "-lc" && -n "${3:-}" ]]; then
        local wrapped
        wrapped="$(_selinux_wrap_bash_lc_with_dnf "$3")"
        podman run --rm -v "${mount_src}:/work:Z" "${podman_extra[@]}" "${SELINUX_COMPILE_IMAGE}" bash -lc "${wrapped}"
    else
        podman run --rm -v "${mount_src}:/work:Z" "${podman_extra[@]}" "${SELINUX_COMPILE_IMAGE}" \
            bash -lc "$(_selinux_wrap_bash_lc_with_dnf "$*")"
    fi
}

# Like run_selinux_container but mount at /build (refpolicy Makefile compile).
_run_selinux_build_mount() {
    local mount_src="$1"
    shift
    ensure_selinux_build_image || true
    if selinux_build_image_ready; then
        podman run --rm -v "${mount_src}:/build:Z" "${SELINUX_BUILD_IMAGE}" "$@"
        return $?
    fi
    echo "[WARN] Prebuilt image ${SELINUX_BUILD_IMAGE} unavailable — inline dnf install (slow, needs network). Fix: bash scripts/lib/build_image.sh" >&2
    if [[ "$1" == "make" ]]; then
        podman run --rm -v "${mount_src}:/build:Z" "${SELINUX_COMPILE_IMAGE}" \
            bash -lc "$(_selinux_wrap_bash_lc_with_dnf "$*")"
    else
        podman run --rm -v "${mount_src}:/build:Z" "${SELINUX_COMPILE_IMAGE}" \
            bash -lc "$(_selinux_wrap_bash_lc_with_dnf "$*")"
    fi
}

compile_toolchain_available() {
    has_selinux_devel && return 0
    command -v podman >/dev/null 2>&1
}

infer_policy_module_name() {
    local policy_dir="$1"
    local explicit="${2:-}"

    if [[ -n "${explicit}" ]]; then
        echo "${explicit}"
        return 0
    fi
    if [[ -n "${POLICY_MODULE:-}" ]]; then
        echo "${POLICY_MODULE}"
        return 0
    fi
    local te name="" count=0
    for te in "${policy_dir}"/*.te; do
        [[ -e "${te}" ]] || continue
        name="$(basename "${te}" .te)"
        count=$((count + 1))
    done
    if [[ "${count}" -eq 1 ]]; then
        echo "${name}"
        return 0
    fi
    echo "[ERROR] compile_policy_module: pass module name (${count} .te files in ${policy_dir})" >&2
    return 1
}

compile_policy_module() {
    local policy_dir="$1"
    local module_name="${2:-}"
    module_name="$(infer_policy_module_name "${policy_dir}" "${module_name}")" || return 1
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
        local work_dir
        work_dir="$(mktemp -d)"
        _copy_module_sources "${work_dir}"
        _run_selinux_build_mount "${work_dir}" \
            make -C /build -f /usr/share/selinux/devel/Makefile "${module_name}.pp"
        cp "${work_dir}/${module_name}.pp" "${output_pp}"
        rm -rf "${work_dir}"
    else
        echo "[ERROR] Install selinux-policy-devel or podman for policy compile" >&2
        return 1
    fi
}

verify_pp_matches_sources() {
    local policy_dir="$1"
    local module_name="${2:-}"
    module_name="$(infer_policy_module_name "${policy_dir}" "${module_name}")" || return 1

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
