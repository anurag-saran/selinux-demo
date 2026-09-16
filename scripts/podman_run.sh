#!/usr/bin/env bash
#
# podman_run.sh — Run the PoC inside a privileged Fedora container with systemd.
#
# Usage:
#   bash scripts/podman_run.sh up             # start persistent container (systemd + port 8888)
#   bash scripts/podman_run.sh setup          # run setup inside the running container
#   bash scripts/podman_run.sh shell          # interactive root shell
#   bash scripts/podman_run.sh demo           # one-shot full demo (needs OPENAI_API_KEY)
#   bash scripts/podman_run.sh stop           # stop and remove the container
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE_NAME="${SELINUX_POC_IMAGE:-selinux-ai-poc}"
CONTAINER_NAME="${SELINUX_POC_CONTAINER:-selinux-ai-poc-run}"
PODMAN_ENV="${HOME}/.local/share/selinux-demo/podman/env.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  build    Build the container image
  up       Start persistent container (systemd, port 8888 published)
  stop     Stop and remove the persistent container
  setup    Run scripts/setup_environment.sh in the running container
  shell    Interactive bash shell in the running container
  demo     Run full demo in the persistent container (requires OPENAI_API_KEY)
  exec     Run a command in the running container
  logs     Follow container logs

Environment:
  OPENAI_API_KEY        Required for demo
  SELINUX_POC_IMAGE     Image name (default: selinux-ai-poc)
  SELINUX_POC_CONTAINER Container name (default: selinux-ai-poc-run)

Examples:
  export OPENAI_API_KEY="sk-..."
  bash scripts/podman_build.sh
  bash scripts/podman_run.sh up
  bash scripts/podman_run.sh setup
  curl http://127.0.0.1:8888/save-log
  bash scripts/podman_run.sh exec python3 cli/selinux_gen.py --apply --output-dir policy_out
  bash scripts/podman_run.sh stop
EOF
}

ensure_podman() {
    # Prefer user-local Podman installed by scripts/fix_podman.sh
    if [[ -f "${PODMAN_ENV}" ]]; then
        # shellcheck disable=SC1090
        source "${PODMAN_ENV}"
    fi

    if ! command -v podman >/dev/null 2>&1; then
        log_error "podman not found. Install from https://podman.io or run: bash scripts/fix_podman.sh"
        exit 1
    fi

    local ver
    ver="$(podman --version 2>/dev/null | awk '{print $3}')"
    if [[ "${ver}" == 2.* ]] || [[ "${ver}" == 1.* ]]; then
        log_error "Podman ${ver} is too old (needs >= 4.0)."
        log_error "Run: bash scripts/fix_podman.sh"
        exit 1
    fi

    if podman info 2>/dev/null | grep -q "Cannot connect"; then
        log_warn "Podman connection issue. Try: bash scripts/fix_podman.sh"
    fi

    if ! podman info >/dev/null 2>&1; then
        log_warn "Podman is not connected. Starting machine..."
        podman machine start 2>/dev/null || {
            log_error "Cannot connect to Podman. Run: bash scripts/fix_podman.sh"
            exit 1
        }
    fi
}

ensure_image() {
    if ! podman image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
        log_info "Image ${IMAGE_NAME} not found; building..."
        bash "${SCRIPT_DIR}/podman_build.sh"
    fi
}

container_running() {
    podman ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"
}

container_exists() {
    podman ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"
}

append_runtime_args() {
    RUNTIME_ARGS=(
        --privileged
        --systemd=always
        --security-opt seccomp=unconfined
        --publish 8888:8888
        --volume "${PROJECT_ROOT}:/workspace:Z"
        --workdir /workspace
        --env "OPENAI_API_KEY=${OPENAI_API_KEY:-}"
        --env container=oci
        --cap-add SYS_ADMIN
    )

    if [[ -d /sys/fs/selinux ]]; then
        RUNTIME_ARGS+=(--volume /sys/fs/selinux:/sys/fs/selinux:rw)
    else
        log_warn "/sys/fs/selinux not found on host; SELinux may be disabled in container."
        log_warn "PoC AVC/policy steps require a SELinux-enabled Podman host or machine."
    fi
}

start_persistent_container() {
    ensure_podman
    ensure_image
    append_runtime_args

    if container_running; then
        log_info "Container ${CONTAINER_NAME} is already running."
        return 0
    fi

    podman rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

    log_info "Starting persistent container ${CONTAINER_NAME}..."
    podman run \
        --detach \
        --name "${CONTAINER_NAME}" \
        "${RUNTIME_ARGS[@]}" \
        "${IMAGE_NAME}"

    # Give systemd and the entrypoint time to start auditd.
    sleep 3
    log_info "Container started. App will be available after setup."
    log_info "Next: bash scripts/podman_run.sh setup"
}

stop_container() {
    ensure_podman
    if container_exists; then
        log_info "Stopping ${CONTAINER_NAME}..."
        podman rm -f "${CONTAINER_NAME}" >/dev/null
    else
        log_info "Container ${CONTAINER_NAME} is not running."
    fi
}

require_running_container() {
    ensure_podman
    if ! container_running; then
        log_info "Container not running; starting it now..."
        start_persistent_container
    fi
}

exec_in_container() {
    require_running_container
    podman exec -it "${CONTAINER_NAME}" "$@"
}

cmd="${1:-}"
shift || true

case "${cmd}" in
    build)
        bash "${SCRIPT_DIR}/podman_build.sh"
        ;;
    up|start)
        start_persistent_container
        ;;
    stop|down)
        stop_container
        ;;
    setup)
        exec_in_container /bin/bash -lc "bash scripts/setup_environment.sh"
        log_info "Setup complete. From the host, try:"
        echo "  curl -v http://127.0.0.1:8888/save-log"
        echo "  curl -v http://127.0.0.1:8888/run-script"
        ;;
    shell)
        exec_in_container /bin/bash
        ;;
    demo)
        if [[ -z "${OPENAI_API_KEY:-}" ]]; then
            log_error "OPENAI_API_KEY is not set."
            exit 1
        fi
        start_persistent_container
        podman exec -it "${CONTAINER_NAME}" /bin/bash -lc "bash scripts/run_demo.sh"
        ;;
    exec)
        if [[ $# -eq 0 ]]; then
            log_error "exec requires a command."
            exit 1
        fi
        exec_in_container "$@"
        ;;
    logs)
        require_running_container
        podman logs -f "${CONTAINER_NAME}"
        ;;
    -h|--help|help|"")
        usage
        ;;
    *)
        log_error "Unknown command: ${cmd}"
        usage
        exit 1
        ;;
esac
