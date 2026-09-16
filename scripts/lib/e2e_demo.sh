# e2e_demo.sh — shared talk-track helpers for demo_e2e_*.sh (source only)
# Requires scripts/lib/training_lab_runner.sh already sourced.

E2E_DRY="${E2E_DRY:-0}"
E2E_PART="${E2E_PART:-all}"
DEV_HOST="${DEV_HOST:-192.168.64.6}"
PROD_HOST="${PROD_HOST:-192.168.64.5}"

e2e_usage_common() {
    cat <<EOF
Options:
  --auto       No Enter pauses (recording)
  --no-type    Print commands instantly (no typewriter)
  --dry-run    Type and explain only — do not run commands
  -h, --help   Show help
EOF
}

e2e_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto) TLAB_AUTO=1; shift ;;
            --no-type) TLAB_NO_TYPE=1; shift ;;
            --dry-run|--say-only) E2E_DRY=1; shift ;;
            --part) E2E_PART="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
        esac
    done
}

e2e_banner() {
    echo
    echo -e "${TLAB_BOLD}${TLAB_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${TLAB_NC}"
    echo -e "${TLAB_BOLD}  $*${TLAB_NC}"
    echo -e "${TLAB_BOLD}${TLAB_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${TLAB_NC}"
    echo
}

e2e_run() {
    local cmd="$1"
    tlab_type_line "${cmd}"
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        echo -e "${TLAB_DIM}(dry-run — not executing)${TLAB_NC}"
        echo
        return 0
    fi
    eval "${cmd}"
    echo
}

e2e_run_expect_fail() {
    local cmd="$1"
    tlab_type_line "${cmd}"
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        echo -e "${TLAB_DIM}(dry-run — would fail on prod until 7 soak days)${TLAB_NC}"
        echo
        return 0
    fi
    set +e
    eval "${cmd}"
    local rc=$?
    set -e
    echo
    echo -e "${TLAB_YELLOW}Exit ${rc} — that failure is the point of this step.${TLAB_NC}"
    echo
}

e2e_handoff() {
    echo
    echo -e "${TLAB_BOLD}${TLAB_YELLOW}>>> Switch windows${TLAB_NC}"
    echo -e "${TLAB_YELLOW}$*${TLAB_NC}"
    echo
    tlab_pause
}

e2e_require_mac() {
    if [[ "$(uname -s)" != Darwin ]]; then
        echo "This script is the Mac talk track. On a RHEL VM use demo_e2e_rhel_dev.sh or demo_e2e_rhel_prod.sh." >&2
        exit 1
    fi
}

e2e_require_rhel() {
    local who="$1"
    if [[ "$(uname -s)" == Darwin ]]; then
        echo "This script runs ON ${who}, not on the Mac." >&2
        echo "On the Mac: ssh ansible@${DEV_HOST}   or   ssh ansible@${PROD_HOST}" >&2
        exit 1
    fi
    if ! command -v getenforce >/dev/null 2>&1; then
        echo "getenforce not found — this is not a SELinux host." >&2
        exit 1
    fi
}
