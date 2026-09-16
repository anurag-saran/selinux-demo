#!/usr/bin/env bash
#
# run_demo_prep.sh — Demo showcase / presenter prep (no flags required)
#
# Runs the full 10-act paced walkthrough with:
#   • Talking points before each act (see docs/training/DEMO_GUIDE.md)
#   • Typewriter-style “show on screen” commands after each act
#   • Pauses between steps (rehearse what to say)
#   • Built-in demo-mode + offline AI fixtures + Podman VM on macOS
#
# Usage (from repo root):
#   bash scripts/run_demo_prep.sh
#
# Live presentation without pauses: use scripts/demo_present.sh instead.
# Hands-on SELinux labs: bash scripts/run_training_lab.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0")

Demo prep / showcase mode — no options required.

Defaults (you do not pass flags):
  • Full acts 1–10 with presenter pauses
  • --demo-mode (soak calendar shortcut for acts 8–9)
  • --skip-ai (fixture policy; no generation at Act 3)
  • Optional: --llm-summary + OPENAI_API_KEY polishes pr_summary.md after deterministic gen
  • --use-vm on macOS; native Linux needs sudo on this script

Before first run on Mac:
  source ~/.local/share/selinux-demo/podman/env.sh
  bash scripts/run_on_podman_vm.sh setup   # if staging not yet installed

Acts 6–10 install ansible/requirements.yml collections on the VM automatically when needed.

Docs: docs/training/DEMO_GUIDE.md
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *)
            echo "This script runs in one mode only — no flags." >&2
            echo "Use: bash scripts/run_demo_prep.sh" >&2
            echo "For options see: bash scripts/demo_present.sh --help" >&2
            exit 1
            ;;
    esac
done

export DEMO_PREP=1

# shellcheck source=lib/training_lab_runner.sh
source "${SCRIPT_DIR}/lib/training_lab_runner.sh"
# shellcheck source=lib/demo_prep_talk.sh
source "${SCRIPT_DIR}/lib/demo_prep_talk.sh"
# shellcheck source=demo_present.sh
source "${SCRIPT_DIR}/demo_present.sh"

# Baked-in demo prep profile (replaces demo_present.sh flags)
AUTO=0
DEMO_MODE=1
SKIP_AI=1
USE_VM=0
ACTS_SPEC="1-10"
if [[ "$(uname -s)" == Darwin ]]; then
    USE_VM=1
fi

TLAB_AUTO=0
TLAB_NO_TYPE=0
TLAB_USE_VM="${USE_VM}"

parse_acts

echo -e "${TLAB_BOLD}SELinux PaC — paced walkthrough${TLAB_NC}"
echo -e "${TLAB_DIM}Talking points + typed show commands + full presenter demo (acts 1–10).${TLAB_NC}"
if [[ "${USE_VM}" -eq 1 ]]; then
    echo -e "${TLAB_DIM}SELinux commands run inside Podman VM; policy_out/ artifacts on this Mac.${TLAB_NC}"
else
    echo -e "${TLAB_DIM}Run as root on native Linux: sudo bash scripts/run_demo_prep.sh${TLAB_NC}"
fi
echo
tlab_pause

if [[ "${USE_VM}" -eq 1 ]]; then
    TLAB_VM_PROJECT="${VM_PROJECT:-/home/core/selinux-pac}"
fi

main
