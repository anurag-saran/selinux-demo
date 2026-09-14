#!/usr/bin/env bash
#
# repair_podman_machine.sh — Reset Podman Machine storage (macOS overlay readlink errors).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${HOME}/.local/share/selinux-demo/podman/env.sh"

if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
fi

if ! command -v podman >/dev/null 2>&1; then
    echo "[ERROR] podman not found. Run: bash scripts/fix_podman.sh" >&2
    exit 1
fi

echo "[INFO] Stopping and removing podman-machine-default …" >&2
podman machine stop 2>/dev/null || true
podman machine rm -f podman-machine-default 2>/dev/null || true

if [[ ! $(podman machine list 2>/dev/null | grep -c podman-machine-default) -gt 0 ]]; then
    echo "[INFO] Initializing rootful machine (60GB disk) …" >&2
    podman machine init --rootful --cpus 4 --memory 8192 --disk-size 60
fi

podman machine start
sleep 8

# Optional: clear corrupted rootful storage inside the VM (restarts API briefly).
if podman machine ssh -- sudo podman system reset -f 2>/dev/null; then
    echo "[INFO] Reset rootful storage inside VM." >&2
    podman machine stop
    podman machine start
    sleep 10
fi

echo "[INFO] Smoke test …" >&2
podman run --rm quay.io/centos/centos:stream9 echo podman-ok
echo "[INFO] Repair complete. Build compile image: bash scripts/build_selinux_compile_image.sh" >&2
