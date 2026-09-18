#!/usr/bin/env bash
#
# vendor_policy_check.sh — Refuse to generate a module that duplicates
# vendor or base policy (JWS/Tomcat, EAP/JBoss, httpd, named, postgresql).
#
# JWS and EAP ship SELinux in a separate RPM that is not installed by default
# (jws6-tomcat-selinux, eap7-selinux / eap8-selinux). Until that RPM is
# installed the process runs unconfined_java_t — "no module loaded" does not
# mean "no policy exists".
#
# Source from other scripts:
#   source "${SCRIPT_DIR}/lib/vendor_policy_check.sh"
#   vendor_policy_preflight --app-name NAME [--unit UNIT] [--pid PID] [--force]
#
# When executed: same argv, exit status of the check.
#
# Mock env (smoke tests only; no live tools):
#   VENDOR_CHECK_MOCK=1
#   VENDOR_CHECK_SEMODULE_L   semodule -l text
#   VENDOR_CHECK_RPM_QA       rpm -qa text (vendor selinux NEVRAs)
#   VENDOR_CHECK_DNF_AVAILABLE  newline-separated available package names
#   VENDOR_CHECK_PS_EZ        ps -eZ / ps -o label=,comm= text
#
set -euo pipefail

_vpc_info() {
    if declare -F log_info >/dev/null 2>&1; then
        log_info "$@"
    else
        echo "[INFO] $*"
    fi
}

_vpc_warn() {
    if declare -F log_warn >/dev/null 2>&1; then
        log_warn "$@"
    else
        echo "[WARN] $*"
    fi
}

_vpc_error() {
    if declare -F log_error >/dev/null 2>&1; then
        log_error "$@"
    else
        echo "[ERROR] $*" >&2
    fi
}

vendor_policy_classify() {
    local blob
    blob="$(printf '%s' "$*" | tr '[:upper:]' '[:lower:]')"
    case "${blob}" in
        *tomcat*|*jws*|*catalina*) echo tomcat ;;
        *jboss*|*eap*|*wildfly*) echo eap ;;
        *httpd*|*apache*) echo httpd ;;
        *named*|*bind9*|*bind*) echo named ;;
        *postgres*) echo postgresql ;;
        *python*|*gunicorn*|*uwsgi*) echo python ;;
        *) echo none ;;
    esac
}

vendor_pkgs_for_class() {
    case "$1" in
        tomcat)
            printf '%s\n' jws5-tomcat-selinux jws6-tomcat-selinux tomcat-selinux
            ;;
        eap)
            printf '%s\n' eap7-selinux eap8-selinux
            ;;
        postgresql)
            printf '%s\n' postgresql-selinux
            ;;
        *)
            ;;
    esac
}

vendor_module_grep_for_class() {
    case "$1" in
        tomcat) echo '^(tomcat|jws[0-9]*_tomcat|jws[0-9]+)$' ;;
        eap) echo '^(jboss|eap[0-9]+|eap|wildfly)$' ;;
        httpd) echo '^httpd$' ;;
        named) echo '^named$' ;;
        postgresql) echo '^(postgresql|postgres)$' ;;
        python) echo '^(python|python3)$' ;;
        *) echo '^$' ;;
    esac
}

vendor_check_tools_missing() {
    if [[ "${VENDOR_CHECK_MOCK:-}" == "1" ]]; then
        return 1
    fi
    if command -v semodule >/dev/null 2>&1; then
        return 1
    fi
    if command -v rpm >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

vendor_check_semodule_l() {
    if [[ "${VENDOR_CHECK_MOCK:-}" == "1" ]]; then
        printf '%s\n' "${VENDOR_CHECK_SEMODULE_L:-}"
        return 0
    fi
    if command -v semodule >/dev/null 2>&1; then
        semodule -l 2>/dev/null || true
    fi
}

vendor_check_rpm_qa() {
    if [[ "${VENDOR_CHECK_MOCK:-}" == "1" ]]; then
        printf '%s\n' "${VENDOR_CHECK_RPM_QA:-}"
        return 0
    fi
    if ! command -v rpm >/dev/null 2>&1; then
        return 0
    fi
    # Local NEVRA query only — no network. Globs keep this cheaper than rpm -qa.
    rpm -qa \
        'jws*-tomcat-selinux' \
        'eap*-selinux' \
        'tomcat-selinux' \
        'postgresql-selinux' \
        'selinux-policy-targeted' \
        2>/dev/null || true
}

vendor_rpm_has_pkg() {
    local pkg="$1"
    local qa="$2"
    printf '%s\n' "${qa}" | grep -E "^${pkg}(-|$)" >/dev/null 2>&1
}

vendor_check_pkg_available() {
    local pkg="$1"
    local out=""
    if [[ "${VENDOR_CHECK_MOCK:-}" == "1" ]]; then
        if printf '%s\n' "${VENDOR_CHECK_DNF_AVAILABLE:-}" | grep -E "^${pkg}(\.|$)" >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi
    if command -v dnf >/dev/null 2>&1; then
        out="$(dnf --cacheonly --quiet list available "${pkg}" 2>/dev/null || true)"
        if [[ "${out}" == *"${pkg}"* ]]; then
            return 0
        fi
        return 1
    fi
    if command -v yum >/dev/null 2>&1; then
        out="$(yum -C --quiet list available "${pkg}" 2>/dev/null || true)"
        if [[ "${out}" == *"${pkg}"* ]]; then
            return 0
        fi
        return 1
    fi
    return 1
}

vendor_check_ps_context() {
    local pid="${1:-}"
    local unit="${2:-}"
    local mpid=""

    if [[ "${VENDOR_CHECK_MOCK:-}" == "1" ]]; then
        printf '%s\n' "${VENDOR_CHECK_PS_EZ:-}"
        return 0
    fi

    if [[ -n "${pid}" ]] && command -v ps >/dev/null 2>&1; then
        ps -o label=,comm= -p "${pid}" 2>/dev/null || true
        return 0
    fi
    if [[ -n "${unit}" ]] && command -v systemctl >/dev/null 2>&1 && command -v ps >/dev/null 2>&1; then
        mpid="$(systemctl show -p MainPID --value "${unit}" 2>/dev/null || true)"
        if [[ -n "${mpid}" && "${mpid}" != "0" ]]; then
            ps -o label=,comm= -p "${mpid}" 2>/dev/null || true
        fi
    fi
}

vendor_match_loaded_modules() {
    local class="$1"
    local listing="$2"
    local pattern names
    pattern="$(vendor_module_grep_for_class "${class}")"
    [[ -n "${listing}" ]] || return 0
    names="$(printf '%s\n' "${listing}" | awk '{print $1}')"
    printf '%s\n' "${names}" | grep -E "${pattern}" || true
}

_vpc_refuse_loaded() {
    local module="$1"
    local class="$2"
    _vpc_error "vendor policy already loaded: module '${module}' covers this app (class ${class})."
    _vpc_error "Tune booleans and file contexts for the vendor domain; do not generate a duplicate module."
    _vpc_error "Escape hatch: re-run with --force if this app genuinely differs from the vendor policy."
    return 1
}

_vpc_refuse_package() {
    local pkg="$1"
    local detail="$2"
    _vpc_error "vendor SELinux package ${detail}: ${pkg}"
    _vpc_error "Install or enable the vendor package; do not generate a duplicate module."
    _vpc_error "Until that RPM is installed, Tomcat/EAP often runs as unconfined_java_t — that is not confinement."
    _vpc_error "Escape hatch: re-run with --force if this app genuinely differs from the vendor policy."
    return 1
}

_vpc_refuse_unconfined() {
    local domain="$1"
    _vpc_error "process domain is ${domain} (looks like Tomcat/EAP); vendor policy exists but is not enabled."
    _vpc_error "Install jws6-tomcat-selinux or eap7-selinux/eap8-selinux, then confirm the process runs in jws*_tomcat_t / jboss_t."
    _vpc_error "Do not generate a duplicate module."
    _vpc_error "Escape hatch: re-run with --force if this app genuinely differs from the vendor policy."
    return 1
}

_vpc_refuse_base() {
    local class="$1"
    _vpc_error "vendor/base policy already covers this app class (${class} via selinux-policy-targeted)."
    _vpc_error "Tune booleans and file contexts for the vendor domain; do not generate a duplicate module."
    _vpc_error "Escape hatch: re-run with --force if this app genuinely differs from the vendor policy."
    return 1
}

vendor_policy_preflight() {
    local app_name="" unit="" pid="" force=0 report=0
    local class="none" listing="" rpm_qa="" loaded="" pkg="" installed="" available=""
    local ctx="" domain=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app-name)
                app_name="$2"
                shift 2
                ;;
            --unit)
                unit="$2"
                shift 2
                ;;
            --pid)
                pid="$2"
                shift 2
                ;;
            --force)
                force=1
                shift
                ;;
            --report)
                report=1
                shift
                ;;
            *)
                _vpc_error "vendor_policy_check: unknown option $1"
                return 1
                ;;
        esac
    done

    if [[ -z "${app_name}" ]]; then
        _vpc_error "vendor_policy_check: --app-name is required"
        return 1
    fi

    if [[ "${force}" -eq 1 && "${report}" -eq 0 ]]; then
        _vpc_warn "vendor policy check bypassed (--force)"
        return 0
    fi

    if vendor_check_tools_missing; then
        _vpc_warn "vendor policy check skipped: semodule and rpm not found; continuing"
        return 0
    fi

    class="$(vendor_policy_classify "${app_name} ${unit}")"

    # Custom apps (myapp, node, Spring Boot, …) are not vendor-covered.
    # Do not treat a loaded module named after the app as vendor — that is
    # our own seed/module from a previous generate.
    if [[ "${class}" == "none" ]]; then
        _vpc_info "TRIAGE situation=none app=${app_name} action=generate"
        _vpc_info "vendor policy check: no vendor or base module covers '${app_name}'; continuing"
        return 0
    fi

    listing="$(vendor_check_semodule_l)"
    loaded="$(vendor_match_loaded_modules "${class}" "${listing}")"
    if [[ -n "${loaded}" ]]; then
        loaded="$(printf '%s\n' "${loaded}" | head -n 1)"
        if [[ "${report}" -eq 1 ]]; then
            _vpc_info "TRIAGE situation=loaded app=${app_name} module=${loaded} class=${class} action=tune"
            return 0
        fi
        _vpc_refuse_loaded "${loaded}" "${class}"
        return 1
    fi

    rpm_qa="$(vendor_check_rpm_qa)"

    while IFS= read -r pkg; do
        [[ -n "${pkg}" ]] || continue
        if vendor_rpm_has_pkg "${pkg}" "${rpm_qa}"; then
            installed="${pkg}"
            break
        fi
    done < <(vendor_pkgs_for_class "${class}")

    if [[ -n "${installed}" ]]; then
        if [[ "${report}" -eq 1 ]]; then
            _vpc_info "TRIAGE situation=package_installed app=${app_name} package=${installed} class=${class} action=enable"
            return 0
        fi
        _vpc_refuse_package "${installed}" "installed but module not loaded"
        return 1
    fi

    while IFS= read -r pkg; do
        [[ -n "${pkg}" ]] || continue
        if vendor_check_pkg_available "${pkg}"; then
            available="${pkg}"
            break
        fi
    done < <(vendor_pkgs_for_class "${class}")

    if [[ -n "${available}" ]]; then
        if [[ "${report}" -eq 1 ]]; then
            _vpc_info "TRIAGE situation=package_available app=${app_name} package=${available} class=${class} action=install"
            return 0
        fi
        _vpc_refuse_package "${available}" "available but not installed"
        return 1
    fi

    if [[ "${class}" == "tomcat" || "${class}" == "eap" ]]; then
        ctx="$(vendor_check_ps_context "${pid}" "${unit}")"
        if printf '%s\n' "${ctx}" | grep -Eq 'unconfined_java_t|unconfined_service_t'; then
            domain="$(printf '%s\n' "${ctx}" | grep -Eo 'unconfined_java_t|unconfined_service_t' | head -n 1 || true)"
            if [[ "${report}" -eq 1 ]]; then
                _vpc_info "TRIAGE situation=unconfined app=${app_name} domain=${domain} class=${class} action=install"
                return 0
            fi
            _vpc_refuse_unconfined "${domain}"
            return 1
        fi
    fi

    if [[ "${class}" == "httpd" || "${class}" == "named" || "${class}" == "postgresql" ]]; then
        if vendor_rpm_has_pkg "selinux-policy-targeted" "${rpm_qa}"; then
            if [[ "${report}" -eq 1 ]]; then
                _vpc_info "TRIAGE situation=base_policy app=${app_name} class=${class} action=tune"
                return 0
            fi
            _vpc_refuse_base "${class}"
            return 1
        fi
    fi

    _vpc_info "TRIAGE situation=none app=${app_name} class=${class} action=generate"
    _vpc_info "vendor policy check: no vendor or base module covers '${app_name}' (class ${class}); continuing"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    vendor_policy_preflight "$@"
    exit $?
fi
