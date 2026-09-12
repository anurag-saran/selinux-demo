#!/usr/bin/env bash
#
# fix_podman.sh — Repair legacy Podman 2.x on macOS (no Homebrew sudo required).
#
# Installs Podman 5.4.2 to:
#   ~/.local/share/selinux-demo/podman/current/
#
# Then initializes/starts podman machine.
#
set -euo pipefail

PODMAN_VERSION="5.4.2"
MIN_VERSION="4.0.0"
INSTALLER_DIR="${HOME}/.local/share/selinux-demo/podman-install"
PODMAN_HOME="${HOME}/.local/share/selinux-demo/podman/current"
PODMAN_CONF="${HOME}/.local/share/selinux-demo/podman/containers.conf"
ENV_FILE="${HOME}/.local/share/selinux-demo/podman/env.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

version_ge() {
    local current="${1#v}"
    local minimum="${2#v}"
    [[ "$(printf '%s\n' "${minimum}" "${current}" | sort -V | head -n1)" == "${minimum}" ]]
}

current_version() {
    if [[ -x "${PODMAN_HOME}/bin/podman" ]]; then
        PATH="${PODMAN_HOME}/bin:${PATH}" podman --version 2>/dev/null | awk '{print $3}'
    elif command -v podman >/dev/null 2>&1; then
        podman --version 2>/dev/null | awk '{print $3}'
    else
        echo "0.0.0"
    fi
}

download_pkg() {
    mkdir -p "${INSTALLER_DIR}"
    local pkg="${INSTALLER_DIR}/podman-installer-v${PODMAN_VERSION}.pkg"
    if [[ -f "${pkg}" ]]; then
        echo "${pkg}"
        return 0
    fi
    log_info "Downloading Podman ${PODMAN_VERSION} universal installer..."
    curl -fsSL \
        "https://github.com/containers/podman/releases/download/v${PODMAN_VERSION}/podman-installer-macos-universal.pkg" \
        -o "${pkg}"
    echo "${pkg}"
}

extract_pkg() {
    local pkg="$1"
    local tmp
    tmp="$(mktemp -d)"
    log_info "Extracting Podman binaries to ${PODMAN_HOME}..."
    xar -xf "${pkg}" -C "${tmp}"
    rm -rf "${PODMAN_HOME}"
    mkdir -p "${PODMAN_HOME}"
    (cd "${tmp}/podman.pkg" && cat Payload | gunzip -dc | cpio -i)
    cp -R "${tmp}/podman.pkg/podman/"* "${PODMAN_HOME}/"
    rm -rf "${tmp}"
}

write_env() {
    mkdir -p "$(dirname "${PODMAN_CONF}")"
    cat > "${PODMAN_CONF}" <<EOF
[engine]
helper_binaries_dir = ["${PODMAN_HOME}/bin"]
EOF

    cat > "${ENV_FILE}" <<EOF
# Source this file before using Podman for the SELinux PoC:
#   source "${ENV_FILE}"
export PATH="${PODMAN_HOME}/bin:\${PATH}"
export CONTAINERS_CONF="${PODMAN_CONF}"
EOF
}

activate_podman() {
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
}

machine_ready() {
    podman info >/dev/null 2>&1
}

init_machine() {
    activate_podman
    if ! podman machine list >/dev/null 2>&1; then
        log_error "podman machine still unavailable after install."
        exit 1
    fi

    if ! podman machine list | grep -q "podman-machine-default"; then
        log_info "Initializing podman machine (first run may take a few minutes)..."
        podman machine init --cpus 2 --memory 4096 --disk-size 40
    fi

    if ! machine_ready; then
        log_info "Starting podman machine..."
        podman machine start
    fi

    log_info "Podman is ready:"
    podman --version
    podman machine ls
}

main() {
    local current
    current="$(current_version)"
    log_info "Detected podman version: ${current}"

    if [[ -x "${PODMAN_HOME}/bin/podman" ]] && version_ge "${current}" "${MIN_VERSION}"; then
        log_info "User-local Podman already installed at ${PODMAN_HOME}"
    else
        if version_ge "${current}" "${MIN_VERSION}" && machine_ready; then
            log_info "System podman ${current} is already working."
            exit 0
        fi

        if [[ "${current}" != "0.0.0" ]] && ! version_ge "${current}" "${MIN_VERSION}"; then
            log_warn "Legacy podman ${current} found (Homebrew 2.x). Installing user-local ${PODMAN_VERSION}..."
        fi

        local pkg
        pkg="$(download_pkg)"
        extract_pkg "${pkg}"
        write_env
    fi

    init_machine

    cat <<EOF

${GREEN}Podman fixed.${NC}

Before running the PoC in this shell:
  source "${ENV_FILE}"

Permanent setup (add to ~/.zshrc):
  source "${ENV_FILE}"

Then:
  cd "$(cd "$(dirname "$0")/.." && pwd)"
  bash scripts/podman_build.sh
  bash scripts/podman_run.sh up
  bash scripts/podman_run.sh setup

Optional system-wide install (overrides old Homebrew 2.0.6):
  sudo installer -pkg ${INSTALLER_DIR}/podman-installer-v${PODMAN_VERSION}.pkg -target /
EOF
}

main "$@"
