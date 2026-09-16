#!/usr/bin/env bash
#
# build_selinux_compile_image.sh — Build the reusable SELinux compile/container image.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/build_image.sh
source "${SCRIPT_DIR}/lib/build_image.sh"

if ! command -v podman >/dev/null 2>&1; then
    echo "podman is required to build ${SELINUX_BUILD_IMAGE}" >&2
    exit 1
fi

start=$(date +%s)
export SELINUX_BUILD_IMAGE_REFRESH=1
build_selinux_build_image_local
elapsed=$(( $(date +%s) - start ))
echo "Built ${SELINUX_BUILD_IMAGE} in ${elapsed}s."
echo "Optional Hub publish: DOCKERHUB_TOKEN=… SELINUX_BUILD_IMAGE_PULL=1 bash scripts/publish_selinux_compile_image.sh"
