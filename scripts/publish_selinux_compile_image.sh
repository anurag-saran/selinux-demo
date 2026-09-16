#!/usr/bin/env bash
#
# publish_selinux_compile_image.sh — Build and push the SELinux compile image to Docker Hub.
#
# Requires a Hub access token (recommended) or account password via stdin — never commit secrets.
#
#   export DOCKERHUB_USER=asaran
#   export DOCKERHUB_TOKEN='…'
#   bash scripts/publish_selinux_compile_image.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/build_image.sh
source "${SCRIPT_DIR}/lib/build_image.sh"

USER="${DOCKERHUB_USER:-asaran}"
TOKEN="${DOCKERHUB_TOKEN:-}"
export SELINUX_BUILD_IMAGE="docker.io/${USER}/selinux-demo-selinux-build:stream9"

if [[ -z "${TOKEN}" ]]; then
    echo "[ERROR] Set DOCKERHUB_TOKEN (Hub → Account Settings → Security → Access Token)." >&2
    echo "        Do not store tokens in the repo." >&2
    exit 1
fi

if ! command -v podman >/dev/null 2>&1; then
    echo "[ERROR] podman is required" >&2
    exit 1
fi

echo "[INFO] Logging in to docker.io as ${USER} …" >&2
printf '%s' "${TOKEN}" | podman login docker.io -u "${USER}" --password-stdin

if selinux_build_image_ready; then
    echo "[INFO] Image ${SELINUX_BUILD_IMAGE} already present — skipping rebuild." >&2
else
    bash "${SCRIPT_DIR}/build_selinux_compile_image.sh"
fi

echo "[INFO] Pushing ${SELINUX_BUILD_IMAGE} …" >&2
podman push "${SELINUX_BUILD_IMAGE}"

# Optional second tag for demos
if [[ "${SELINUX_BUILD_IMAGE_PUSH_LATEST:-1}" == "1" ]]; then
    latest="docker.io/${USER}/selinux-demo-selinux-build:latest"
    podman tag "${SELINUX_BUILD_IMAGE}" "${latest}"
    podman push "${latest}"
    echo "[INFO] Also pushed ${latest}" >&2
fi

echo "[INFO] Done. Demo hosts: export SELINUX_BUILD_IMAGE=${SELINUX_BUILD_IMAGE}" >&2
