#!/usr/bin/env bash
#
# podman_build.sh — Build the selinux-ai-poc container image.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE_NAME="${SELINUX_POC_IMAGE:-selinux-ai-poc}"

if ! command -v podman >/dev/null 2>&1; then
    echo "Error: podman is not installed." >&2
    echo "Run: bash scripts/fix_podman.sh" >&2
    exit 1
fi

PODMAN_ENV="${HOME}/.local/share/selinux-demo/podman/env.sh"
if [[ -f "${PODMAN_ENV}" ]]; then
    # shellcheck disable=SC1090
    source "${PODMAN_ENV}"
fi

echo "Building image: ${IMAGE_NAME}"
podman build \
    --tag "${IMAGE_NAME}" \
    --file "${PROJECT_ROOT}/Containerfile" \
    "${PROJECT_ROOT}"

echo "Built ${IMAGE_NAME}. Run: bash scripts/podman_run.sh shell"
