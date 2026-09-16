#!/usr/bin/env bash
# CI: restore cached image tar or build once (keyed on Containerfile hash).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/selinux_build_image.sh
source "${SCRIPT_DIR}/../lib/selinux_build_image.sh"

CACHE_TAR="${SELINUX_BUILD_IMAGE_CACHE_TAR:-/tmp/selinux-build-image.tar}"

if [[ -f "${CACHE_TAR}" ]]; then
    echo "[INFO] Loading cached SELinux build image from ${CACHE_TAR}" >&2
    podman load -i "${CACHE_TAR}"
    exit 0
fi

ensure_selinux_build_image
podman save -o "${CACHE_TAR}" "${SELINUX_BUILD_IMAGE}"
echo "[INFO] Saved ${SELINUX_BUILD_IMAGE} to ${CACHE_TAR} for Actions cache" >&2
