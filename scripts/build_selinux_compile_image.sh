#!/usr/bin/env bash
#
# build_selinux_compile_image.sh — Build the reusable SELinux compile/container image.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/selinux_build_image.sh
source "${SCRIPT_DIR}/lib/selinux_build_image.sh"
IMAGE="${SELINUX_BUILD_IMAGE}"

if ! command -v podman >/dev/null 2>&1; then
    echo "podman is required to build ${IMAGE}" >&2
    exit 1
fi

PODMAN_ENV="${HOME}/.local/share/selinux-demo/podman/env.sh"
if [[ -f "${PODMAN_ENV}" ]]; then
    # shellcheck disable=SC1090
    source "${PODMAN_ENV}"
fi

if [[ "$(uname -s)" == "Darwin" ]] && [[ -f "${SCRIPT_DIR}/lib/vm_ready.sh" ]]; then
    # shellcheck source=lib/vm_ready.sh
    source "${SCRIPT_DIR}/lib/vm_ready.sh"
    ensure_vm_ready || exit 1
fi

start=$(date +%s)
echo "[INFO] Building from BASE_IMAGE=${SELINUX_BUILD_BASE_IMAGE}" >&2
podman build \
    --build-arg "BASE_IMAGE=${SELINUX_BUILD_BASE_IMAGE}" \
    --tag "${IMAGE}" \
    --file "${PROJECT_ROOT}/packaging/Containerfile.selinux-build" \
    "${PROJECT_ROOT}"
elapsed=$(( $(date +%s) - start ))
echo "Built ${IMAGE} in ${elapsed}s."
echo "Publish for demos: DOCKERHUB_TOKEN=… bash scripts/publish_selinux_compile_image.sh"
echo "Pull-first default: export SELINUX_BUILD_IMAGE=${SELINUX_BUILD_IMAGE_DEFAULT}"
