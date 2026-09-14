#!/usr/bin/env bash
#
# build_selinux_compile_image.sh — Build the reusable SELinux compile/container image.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE="${SELINUX_BUILD_IMAGE:-selinux-demo/selinux-build:stream9}"

if ! command -v podman >/dev/null 2>&1; then
    echo "podman is required to build ${IMAGE}" >&2
    exit 1
fi

podman build \
    --tag "${IMAGE}" \
    --file "${PROJECT_ROOT}/packaging/Containerfile.selinux-build" \
    "${PROJECT_ROOT}"

echo "Built ${IMAGE}. Export SELINUX_BUILD_IMAGE=${IMAGE} for compile scripts."
