# app_root.sh — Resolve the application tree vs this tool tree.
# Source from scripts that live in selinux-pac. Sets APP_ROOT.
#
#   APP_ROOT=/path/to/checkout       # or --app-root (caller sets APP_ROOT first)
#   sibling ../myapp                 # optional split checkout (legacy)
#   ~/myapp                          # optional split checkout on rhel-qa
#   $1 (selinux-pac)                 # default: this repo (shopapi demo + myapp generator fixture)
#
# shellcheck shell=bash

resolve_app_root() {
    local tool_root="$1"
    local sibling
    if [[ -n "${APP_ROOT:-}" ]]; then
        (cd "${APP_ROOT}" && pwd)
        return
    fi
    sibling="$(cd "${tool_root}/.." && pwd)/myapp"
    if [[ -d "${sibling}/selinux" || -d "${sibling}/.git" ]]; then
        echo "${sibling}"
        return
    fi
    if [[ -d "${HOME}/myapp/selinux" ]]; then
        echo "${HOME}/myapp"
        return
    fi
    echo "${tool_root}"
}

bind_app_tree() {
    local tool_root="$1"
    APP_ROOT="$(resolve_app_root "${tool_root}")"
}
