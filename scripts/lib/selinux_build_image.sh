#!/usr/bin/env bash
#
# selinux_build_image.sh — Defaults and pull-first helpers for the pre-baked compile image.
#
# Red Hat demo: compile image on Docker Hub (asaran/selinux-demo-selinux-build:stream9).
# Default build base: CentOS Stream 9 (RHEL 9 upstream). Optional: SELINUX_BUILD_BASE_IMAGE=registry.redhat.io/rhel9/rhel:9.4
#
set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${_LIB_DIR}/../.." && pwd)"

# Docker Hub pull-first (demo / CI).
SELINUX_BUILD_IMAGE_DEFAULT="docker.io/asaran/selinux-demo-selinux-build:stream9"
SELINUX_BUILD_IMAGE="${SELINUX_BUILD_IMAGE:-${SELINUX_BUILD_IMAGE_DEFAULT}}"
SELINUX_BUILD_BASE_IMAGE_DEFAULT="quay.io/centos/centos:stream9"
SELINUX_BUILD_BASE_IMAGE="${SELINUX_BUILD_BASE_IMAGE:-${SELINUX_BUILD_BASE_IMAGE_DEFAULT}}"
# Slow-path base when compile image is missing (dnf install each run).
SELINUX_COMPILE_IMAGE="${SELINUX_COMPILE_IMAGE:-quay.io/centos/centos:stream9}"
SELINUX_BUILD_IMAGE_AUTO="${SELINUX_BUILD_IMAGE_AUTO:-1}"
# Try registry pull before local build (seconds on demo laptops).
SELINUX_BUILD_IMAGE_PULL="${SELINUX_BUILD_IMAGE_PULL:-1}"

BUILD_IMAGE_SCRIPT="${PROJECT_ROOT}/scripts/build_selinux_compile_image.sh"

selinux_build_image_ready() {
    command -v podman >/dev/null 2>&1 \
        && podman image inspect "${SELINUX_BUILD_IMAGE}" >/dev/null 2>&1
}

pull_selinux_build_image() {
    if [[ "${SELINUX_BUILD_IMAGE_PULL}" != "1" ]]; then
        return 1
    fi
    if ! command -v podman >/dev/null 2>&1; then
        return 1
    fi
    echo "[INFO] Pull-first: fetching ${SELINUX_BUILD_IMAGE} …" >&2
    if podman pull "${SELINUX_BUILD_IMAGE}"; then
        echo "[INFO] Using pulled image ${SELINUX_BUILD_IMAGE}" >&2
        return 0
    fi
    echo "[WARN] Pull failed for ${SELINUX_BUILD_IMAGE} — will build locally or use slow compile path." >&2
    return 1
}

ensure_selinux_build_image() {
    if selinux_build_image_ready; then
        return 0
    fi
    pull_selinux_build_image && selinux_build_image_ready && return 0
    [[ "${SELINUX_BUILD_IMAGE_AUTO}" == "1" ]] || return 1
    [[ -x "${BUILD_IMAGE_SCRIPT}" ]] || return 1
    echo "[INFO] Building ${SELINUX_BUILD_IMAGE} locally (~2–4 min); publish with scripts/publish_selinux_compile_image.sh" >&2
    bash "${BUILD_IMAGE_SCRIPT}"
    selinux_build_image_ready
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-ensure}"
    case "${cmd}" in
        pull) pull_selinux_build_image ;;
        ensure) ensure_selinux_build_image ;;
        *)
            echo "Usage: $(basename "$0") [pull|ensure]" >&2
            exit 1
            ;;
    esac
fi
