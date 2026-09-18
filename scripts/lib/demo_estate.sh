#!/usr/bin/env bash
# demo_estate.sh — Shared paths, variant, and stamp helpers for the three-app demo.
# Source only.
set -euo pipefail

DEMO_STATE_DIR="${DEMO_STATE_DIR:-/var/lib/selinux-pac-demo}"
DEMO_STAMP_DIR="${DEMO_STATE_DIR}/stamps"
DEMO_VARIANT_FILE="${DEMO_STATE_DIR}/variant"
APP_B_DATA="${APP_B_DATA:-/opt/appdata}"
APP_B_PORT="${APP_B_PORT:-8090}"
APP_A_PORT="${APP_A_PORT:-8080}"
APP_A_FORBIDDEN_PATH="${APP_A_FORBIDDEN_PATH:-${DEMO_STATE_DIR}/out-of-scope.txt}"
DEMO_PODMAN_IMAGE="${DEMO_PODMAN_IMAGE:-docker.io/library/fedora:41}"

demo_estate_load_shopapi_manifest() {
    local project_root="${1:?}"
    local manifest="${project_root}/config/shopapi.manifest.yml"
    # shellcheck source=manifest_shell.sh
    source "${project_root}/scripts/lib/manifest_shell.sh"
    source_app_manifest_exports "${manifest}"
}

demo_stamp_done() {
    local name="${1:?}"
    mkdir -p "${DEMO_STAMP_DIR}"
    date -u +%Y-%m-%dT%H:%M:%SZ >"${DEMO_STAMP_DIR}/${name}"
}

demo_stamp_exists() {
    [[ -f "${DEMO_STAMP_DIR}/${1:?}" ]]
}

demo_variant() {
    if [[ -n "${DEMO_TOMCAT_VARIANT:-}" ]]; then
        echo "${DEMO_TOMCAT_VARIANT}"
        return 0
    fi
    if [[ -f "${DEMO_VARIANT_FILE}" ]]; then
        cat "${DEMO_VARIANT_FILE}"
        return 0
    fi
    echo "unknown"
}

demo_tomcat_domain() {
    case "$(demo_variant)" in
        jws) echo jws6_tomcat_t ;;
        tomcat) echo tomcat_t ;;
        *) echo tomcat_t ;;
    esac
}

# File type used when retuning App B. JWS names differ; Act 2 tries this then tomcat_var_lib_t.
demo_tomcat_fcontext_type() {
    case "$(demo_variant)" in
        jws) echo jws6_tomcat_var_lib_t ;;
        *) echo tomcat_var_lib_t ;;
    esac
}

demo_tomcat_service() {
    if [[ -n "${DEMO_TOMCAT_SERVICE:-}" ]]; then
        echo "${DEMO_TOMCAT_SERVICE}"
        return 0
    fi
    case "$(demo_variant)" in
        jws)
            if command -v systemctl >/dev/null 2>&1 \
                && systemctl list-unit-files jws6-tomcat.service >/dev/null 2>&1; then
                echo jws6-tomcat.service
                return 0
            fi
            echo tomcat.service
            ;;
        *) echo tomcat.service ;;
    esac
}

demo_tomcat_webapps() {
    if [[ -n "${DEMO_TOMCAT_WEBAPPS:-}" ]]; then
        echo "${DEMO_TOMCAT_WEBAPPS}"
        return 0
    fi
    local d
    for d in \
        /opt/rh/jws6/root/usr/share/tomcat/webapps \
        /opt/jws-6.0/tomcat/webapps \
        /opt/rh/jws5/root/usr/share/tomcat/webapps \
        /var/lib/tomcat/webapps \
        /usr/share/tomcat/webapps
    do
        if [[ -d "${d}" ]]; then
            echo "${d}"
            return 0
        fi
    done
    echo /var/lib/tomcat/webapps
}

demo_tomcat_server_xml() {
    if [[ -n "${DEMO_TOMCAT_SERVER_XML:-}" ]]; then
        echo "${DEMO_TOMCAT_SERVER_XML}"
        return 0
    fi
    local f
    for f in \
        /opt/rh/jws6/root/usr/share/tomcat/conf/server.xml \
        /opt/jws-6.0/tomcat/conf/server.xml \
        /opt/rh/jws5/root/usr/share/tomcat/conf/server.xml \
        /etc/tomcat/server.xml
    do
        if [[ -f "${f}" ]]; then
            echo "${f}"
            return 0
        fi
    done
    echo /etc/tomcat/server.xml
}

demo_tomcat_catalina_localhost() {
    local conf
    conf="$(dirname "$(demo_tomcat_server_xml)")"
    echo "${conf}/Catalina/localhost"
}

demo_jws_repo_reachable() {
    if command -v dnf >/dev/null 2>&1; then
        if dnf --cacheonly --quiet list available jws6-tomcat >/dev/null 2>&1; then
            return 0
        fi
        if dnf repolist enabled 2>/dev/null | grep -qiE 'jws|rh-jws'; then
            return 0
        fi
        # Networked probe — bootstrap may install. Failure means no JWS repo.
        if dnf --quiet list available jws6-tomcat >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

demo_write_variant() {
    local variant="${1:?}"
    mkdir -p "${DEMO_STATE_DIR}"
    echo "${variant}" >"${DEMO_VARIANT_FILE}"
    DEMO_TOMCAT_VARIANT="${variant}"
}

# Write /etc/shopapi.env and the systemd unit from config/shopapi.manifest.yml (no path literals).
demo_write_shopapi_runtime_files() {
    local project_root="${1:?}"
    local manifest="${project_root}/config/shopapi.manifest.yml"
    python3 - "${manifest}" "${APP_B_PORT}" <<'PY'
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
app_b_port = sys.argv[2]
sys.path.insert(0, str(manifest_path.resolve().parents[1] / "scripts" / "lib"))
from app_manifest import load_manifest

m = load_manifest(manifest_path)
paths = m["paths"]
http = m["http"]
domain = m["domain"]
unit = m["services"]["primary"]["unit"]
install_root = paths["install_root"]
state_name = pathlib.Path(paths["var_dir"]).name
log_name = pathlib.Path(paths["log_dir"]).name
run_name = pathlib.Path(paths["runtime_dir"]).name

env = pathlib.Path("/etc/shopapi.env")
env.write_text(
    (
        f"SHOPAPI_PORT={http['port']}\n"
        f"SHOPAPI_STATE_DIR={paths['var_dir']}\n"
        f"SHOPAPI_LOG_DIR={paths['log_dir']}\n"
        f"APP_B_GATEWAY_URL=http://127.0.0.1:{http['port']}/health\n"
    ),
    encoding="utf-8",
)
print(f"Wrote {env}", file=sys.stderr)

unit_text = f"""[Unit]
Description=shopapi Spring Boot (SELinux PaC demo — no vendor policy)
After=network.target auditd.service
Wants=auditd.service

[Service]
Type=simple
User=shopapi
Group=shopapi
EnvironmentFile=-/etc/shopapi.env
WorkingDirectory={install_root}
# /usr/bin/java is bin_t (or java_exec_t) and is shared by every JVM — it cannot
# carry this app's entrypoint label. systemd sets the process domain directly.
SELinuxContext=system_u:system_r:{domain}:s0
ExecStart=/usr/bin/java -jar {install_root}/shopapi.jar
# Alternative (labelled wrapper, not used here):
#   install a copy of the JRE launcher at install_root/bin/java labeled
#   shopapi_exec_t, then init_daemon_domain({domain}, shopapi_exec_t) and omit
#   SELinuxContext=. That is the classic type_transition path.
Restart=on-failure
RestartSec=5
NoNewPrivileges=false
StateDirectory={state_name}
LogsDirectory={log_name}
RuntimeDirectory={run_name}

[Install]
WantedBy=multi-user.target
"""
dest = pathlib.Path("/etc/systemd/system") / unit
dest.write_text(unit_text, encoding="utf-8")
print(f"Wrote {dest} (App B connector stays on {app_b_port})", file=sys.stderr)
print(paths["install_root"])
print(paths["var_dir"])
print(paths["log_dir"])
print(paths["runtime_dir"])
print(http["port"])
print(unit)
print(domain)
PY
}

demo_manifest_http_port() {
    local manifest="${1:?}"
    local port=""
    if command -v python3 >/dev/null 2>&1; then
        port="$(python3 - "${manifest}" <<'PY' 2>/dev/null || true
import pathlib
import sys

try:
    sys.path.insert(0, str(pathlib.Path(sys.argv[1]).resolve().parents[1] / "scripts" / "lib"))
    from app_manifest import load_manifest
    print(load_manifest(pathlib.Path(sys.argv[1]))["http"]["port"])
except Exception:
    raise SystemExit(1)
PY
)"
    fi
    if [[ -z "${port}" ]]; then
        port="$(awk '/^http:/{h=1} h && $1=="port:"{print $2; exit}' "${manifest}")"
    fi
    printf '%s\n' "${port}"
}

demo_write_tomcat_dropin() {
    local project_root="${1:?}"
    local manifest="${project_root}/config/shopapi.manifest.yml"
    local svc dir
    svc="$(demo_tomcat_service)"
    dir="/etc/systemd/system/${svc}.d"
    mkdir -p "${dir}"
    python3 - "${manifest}" "${APP_A_FORBIDDEN_PATH}" "${dir}/demo.conf" <<'PY'
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
forbidden = sys.argv[2]
dest = pathlib.Path(sys.argv[3])
sys.path.insert(0, str(manifest_path.resolve().parents[1] / "scripts" / "lib"))
from app_manifest import load_manifest

m = load_manifest(manifest_path)
port = m["http"]["port"]
host = m["http"].get("host", "127.0.0.1")
dest.write_text(
    (
        "[Service]\n"
        f"Environment=APP_B_GATEWAY_URL=http://{host}:{port}/health\n"
        f"Environment=APP_A_FORBIDDEN_PATH={forbidden}\n"
    ),
    encoding="utf-8",
)
print(f"Wrote {dest}")
PY
}
