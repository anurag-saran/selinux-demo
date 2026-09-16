#!/usr/bin/env bash
#
# selinux_build_image.sh — Optional registry pull, then local build (see build_image.sh).
#
set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=build_image.sh
source "${_LIB_DIR}/build_image.sh"

# Demo / mirror pull (off by default — local build only).
SELINUX_BUILD_IMAGE_PULL="${SELINUX_BUILD_IMAGE_PULL:-0}"
SELINUX_HUB_IMAGE_DEFAULT="docker.io/asaran/selinux-demo-selinux-build:stream9"

pull_selinux_build_image() {
    if [[ "${SELINUX_BUILD_IMAGE_PULL}" != "1" ]]; then
        return 1
    fi
    if ! command -v podman >/dev/null 2>&1; then
        return 1
    fi
    local pull_tag="${SELINUX_BUILD_IMAGE}"
    if [[ "${pull_tag}" == "${SELINUX_BUILD_IMAGE_DEFAULT}" ]]; then
        pull_tag="${SELINUX_HUB_IMAGE_DEFAULT}"
    fi
    echo "[INFO] Pull-first: fetching ${pull_tag} …" >&2
    if podman pull "${pull_tag}"; then
        if [[ "${pull_tag}" != "${SELINUX_BUILD_IMAGE}" ]]; then
            podman tag "${pull_tag}" "${SELINUX_BUILD_IMAGE}" 2>/dev/null || true
        fi
        echo "[INFO] Using pulled image as ${SELINUX_BUILD_IMAGE}" >&2
        return 0
    fi
    echo "[WARN] Pull failed for ${pull_tag} — will build locally." >&2
    return 1
}

ensure_selinux_build_image() {
    if [[ "${SELINUX_BUILD_IMAGE_REFRESH:-0}" == "1" ]]; then
        build_selinux_build_image_local
        return $?
    fi
    if selinux_build_image_ready; then
        return 0
    fi
    if pull_selinux_build_image && selinux_build_image_ready; then
        return 0
    fi
    build_selinux_build_image_local
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
