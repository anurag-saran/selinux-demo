#!/usr/bin/env bash
#
# build_image.sh — Local prebuilt SELinux toolchain image (no per-run dnf).
#
# Default tag: localhost/selinux-build:stream9
# Force rebuild: SELINUX_BUILD_IMAGE_REFRESH=1
#
set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${_LIB_DIR}/../.." && pwd)"

SELINUX_BUILD_IMAGE_DEFAULT="localhost/selinux-build:stream9"
SELINUX_BUILD_IMAGE="${SELINUX_BUILD_IMAGE:-${SELINUX_BUILD_IMAGE_DEFAULT}}"
SELINUX_BUILD_BASE_IMAGE_DEFAULT="quay.io/centos/centos:stream9"
SELINUX_BUILD_BASE_IMAGE="${SELINUX_BUILD_BASE_IMAGE:-${SELINUX_BUILD_BASE_IMAGE_DEFAULT}}"
# Bare Stream base for slow-path inline dnf fallback only.
SELINUX_COMPILE_IMAGE="${SELINUX_COMPILE_IMAGE:-quay.io/centos/centos:stream9}"

CONTAINERFILE="${PROJECT_ROOT}/packaging/Containerfile.selinux-build"

# Must match Containerfile RUN line (slow-path fallback installs the same set).
SELINUX_CONTAINER_DNF_PKGS="selinux-policy-devel checkpolicy policycoreutils setools-console selinux-policy-targeted rpm-build"

selinux_build_image_ready() {
    command -v podman >/dev/null 2>&1 || return 1
    if podman image exists "${SELINUX_BUILD_IMAGE}" >/dev/null 2>&1; then
        return 0
    fi
    podman image inspect "${SELINUX_BUILD_IMAGE}" >/dev/null 2>&1
}

build_selinux_build_image_local() {
    [[ -f "${CONTAINERFILE}" ]] || {
        echo "[ERROR] Missing ${CONTAINERFILE}" >&2
        return 1
    }
    if ! command -v podman >/dev/null 2>&1; then
        echo "[ERROR] podman required to build ${SELINUX_BUILD_IMAGE}" >&2
        return 1
    fi
    echo "[INFO] Building ${SELINUX_BUILD_IMAGE} from ${CONTAINERFILE} (one-time; ~2–4 min) …" >&2
    podman build \
        --build-arg "BASE_IMAGE=${SELINUX_BUILD_BASE_IMAGE}" \
        --tag "${SELINUX_BUILD_IMAGE}" \
        --file "${CONTAINERFILE}" \
        "${PROJECT_ROOT}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "[ERROR] Use scripts/lib/selinux_build_image.sh for ensure/pull (build_image.sh is library-only)." >&2
    exit 1
fi
