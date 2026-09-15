#!/usr/bin/env bash
#
# run_boolean_query_integration.sh — Live sesearch boolean discovery (optional).
# Skips cleanly when Podman or the SELinux build image is unavailable.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if ! command -v podman >/dev/null 2>&1; then
    echo "SKIP boolean query integration: podman not installed"
    exit 0
fi

# shellcheck source=lib/build_image.sh
source "${SCRIPT_DIR}/lib/build_image.sh"
if ! selinux_build_image_ready 2>/dev/null; then
    bash "${SCRIPT_DIR}/lib/build_image.sh" ensure 2>/dev/null || true
fi
if ! selinux_build_image_ready 2>/dev/null; then
    echo "SKIP boolean query integration: SELinux build image unavailable"
    exit 0
fi

IMAGE="${SELINUX_BUILD_IMAGE:-localhost/selinux-build:stream9}"

podman run --rm -v "${PROJECT_ROOT}:/work:ro" "${IMAGE}" bash -lc '
set -euo pipefail
export PYTHONPATH=/work/cli
python3 <<PY
import sys
from pathlib import Path

sys.path.insert(0, "/work/cli")
from avc_preprocess import AccessNeed
from boolean_hints import load_boolean_hints, resolve_booleans_for_need

need = AccessNeed(
    "myapp_t",
    "http_port_t",
    "tcp_socket",
    frozenset({"name_connect"}),
)
empty_hints = Path("/tmp/empty_hints.yml")
empty_hints.write_text("hints: []\n", encoding="utf-8")
hints = load_boolean_hints(empty_hints)
result = resolve_booleans_for_need(need, hints, {"app_name": "myapp", "domain": "myapp_t"})
if result.status == "unavailable":
    print(f"SKIP boolean query integration: {result.detail}")
    raise SystemExit(0)
assert result.status == "matched", result
names = [m.name for m in result.matches]
assert "httpd_can_network_connect" in names, names
if len(names) > 1:
    print(f"OK multiple booleans listed (no auto-pick): {names}")
else:
    print("OK discovered httpd_can_network_connect via policy query")
PY
'

echo "boolean query integration passed"
