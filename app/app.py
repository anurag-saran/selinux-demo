#!/opt/myapp/venv/bin/python
"""
Order Processor App - Flask service designed to trigger SELinux AVC denials.

When running under myapp_t in permissive mode, denied operations are logged to
audit.log but still succeed. In enforcing mode (after AI policy is applied),
these endpoints should work without new AVC denials.
"""

from __future__ import annotations

import logging
import os
import socket
import subprocess
import sys
import shutil
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from flask import Flask, jsonify

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
APP_HOST = "0.0.0.0"
# Non-standard HTTP port. Without corenet_tcp_bind_* allow rules for myapp_t,
# binding to 8888 triggers a network AVC denial (tcp_socket name_bind).
APP_PORT = 8888

DATA_LOG_PATH = Path("/var/lib/myapp/data.log")
BACKUP_SCRIPT = Path("/opt/myapp/bin/backup.sh")
BACKEND_HEALTH_URL = os.environ.get("MYAPP_BACKEND_URL", "http://127.0.0.1:8889/health")
NOTIFY_SOCK = Path(os.environ.get("MYAPP_NOTIFY_SOCK", "/run/myapp/notify.sock"))
SELINUX_DOMAIN = os.environ.get("MYAPP_SELINUX_DOMAIN", "myapp_t")
DEPLOY_REPORT_PATH = Path("/var/lib/myapp/selinux_deploy_report.json")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("myapp")

app = Flask(__name__)


def read_process_context() -> str | None:
    try:
        return Path("/proc/self/attr/current").read_text(encoding="utf-8").strip()
    except OSError:
        return None


def selinux_status() -> dict[str, object]:
    mode = "unknown"
    try:
        proc = subprocess.run(
            ["getenforce"],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
        mode = proc.stdout.strip() or "unknown"
    except OSError:
        pass

    domain_permissive: bool | None = None
    try:
        proc = subprocess.run(
            ["semanage", "permissive", "-l"],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
        if proc.returncode == 0:
            domain_permissive = SELINUX_DOMAIN in proc.stdout.split()
    except OSError:
        pass

    policy_version = os.environ.get("MYAPP_POLICY_VERSION", "unknown")
    if policy_version == "unknown" and DEPLOY_REPORT_PATH.is_file():
        try:
            import json

            report = json.loads(DEPLOY_REPORT_PATH.read_text(encoding="utf-8"))
            policy_version = report.get("policy_version", "unknown")
        except (OSError, ValueError):
            pass

    return {
        "mode": mode,
        "domain": SELINUX_DOMAIN,
        "domain_permissive": domain_permissive,
        "policy_version": policy_version,
        "process_context": read_process_context(),
    }


def with_selinux_error(base: dict[str, object], exc: BaseException | None = None) -> dict[str, object]:
    payload = dict(base)
    payload["selinux"] = selinux_status()
    if isinstance(exc, OSError) and exc.errno == 13:
        payload["selinux_context"] = read_process_context()
    return payload


@app.route("/", methods=["GET"])
def health_check():
    """Simple health check - should not trigger SELinux denials."""
    return jsonify(
        {
            "status": "ok",
            "service": "order-processor",
            "port": APP_PORT,
            "selinux": selinux_status(),
        }
    )


@app.route("/save-log", methods=["GET"])
def save_log():
    """
    Attempt to append a timestamp to /var/lib/myapp/data.log.

    SELinux denial (before policy):
      - Source domain: myapp_t (Flask/python3 process)
      - Target context: typically var_t or an unlabeled path under /var/lib/myapp
      - Permission denied: write, append, open (file class)
      - Cause: myapp_t lacks allow rules for myapp_var_lib_t:file write
    """
    timestamp = datetime.now(timezone.utc).isoformat()
    message = f"[{timestamp}] order processed\n"

    try:
        DATA_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with DATA_LOG_PATH.open("a", encoding="utf-8") as handle:
            handle.write(message)
    except OSError as exc:
        logger.exception("Failed to write data log at %s", DATA_LOG_PATH)
        return (
            jsonify(
                with_selinux_error(
                    {
                        "status": "error",
                        "endpoint": "/save-log",
                        "path": str(DATA_LOG_PATH),
                        "error": str(exc),
                        "selinux_hint": (
                            "Expected AVC: myapp_t -> file write on /var/lib/myapp/data.log. "
                            "Policy needs allow myapp_t myapp_var_lib_t:file { write append open };"
                        ),
                    },
                    exc,
                )
            ),
            500,
        )

    logger.info("Wrote log entry to %s", DATA_LOG_PATH)
    return jsonify(
        {
            "status": "ok",
            "endpoint": "/save-log",
            "path": str(DATA_LOG_PATH),
            "bytes_written": len(message.encode("utf-8")),
        }
    )


@app.route("/run-script", methods=["GET"])
def run_script():
    """
    Execute /opt/myapp/bin/backup.sh via subprocess.

    SELinux denial (before policy):
      - Source domain: myapp_t
      - Target: myapp_script_exec_t (or default script label)
      - Permission denied: execute, execute_no_trans (file/process class)
      - Cause: no domain transition or allow rule for executing the backup script
    """
    if not BACKUP_SCRIPT.is_file():
        return (
            jsonify(
                {
                    "status": "error",
                    "endpoint": "/run-script",
                    "path": str(BACKUP_SCRIPT),
                    "error": "backup script not found",
                }
            ),
            404,
        )

    try:
        result = subprocess.run(
            [str(BACKUP_SCRIPT)],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        logger.exception("Failed to execute backup script %s", BACKUP_SCRIPT)
        return (
            jsonify(
                with_selinux_error(
                    {
                        "status": "error",
                        "endpoint": "/run-script",
                        "path": str(BACKUP_SCRIPT),
                        "error": str(exc),
                        "selinux_hint": (
                            "Expected AVC: myapp_t -> file execute on backup.sh. "
                            "Policy needs domain_auto_trans or allow execute + transition."
                        ),
                    },
                    exc,
                )
            ),
            500,
        )

    if result.returncode != 0:
        return (
            jsonify(
                {
                    "status": "error",
                    "endpoint": "/run-script",
                    "returncode": result.returncode,
                    "stderr": result.stderr.strip(),
                    "stdout": result.stdout.strip(),
                }
            ),
            500,
        )

    logger.info("Executed backup script successfully")
    return jsonify(
        {
            "status": "ok",
            "endpoint": "/run-script",
            "path": str(BACKUP_SCRIPT),
            "stdout": result.stdout.strip(),
        }
    )


@app.route("/probe-backend", methods=["GET"])
def probe_backend():
    """
    Outbound TCP client to the local backend on port 8889.

    SELinux denial (before policy):
      - Source domain: myapp_t
      - Permissions: tcp_socket connect, name_connect on unreserved_port_t / node_t
    """
    try:
        with urllib.request.urlopen(BACKEND_HEALTH_URL, timeout=5) as resp:
            body = resp.read().decode("utf-8")
    except (OSError, urllib.error.URLError) as exc:
        logger.exception("Backend probe failed for %s", BACKEND_HEALTH_URL)
        return (
            jsonify(
                with_selinux_error(
                    {
                        "status": "error",
                        "endpoint": "/probe-backend",
                        "url": BACKEND_HEALTH_URL,
                        "error": str(exc),
                        "selinux_hint": (
                            "Expected AVC: myapp_t outbound tcp_socket connect/name_connect "
                            "to 127.0.0.1:8889."
                        ),
                    },
                    exc,
                )
            ),
            500,
        )

    logger.info("Backend probe succeeded")
    return jsonify(
        {
            "status": "ok",
            "endpoint": "/probe-backend",
            "url": BACKEND_HEALTH_URL,
            "backend_response": body.strip(),
        }
    )


@app.route("/notify-socket", methods=["GET"])
def notify_socket():
    """
    Unix stream client to /run/myapp/notify.sock (backend stub listener).

    SELinux denial (before policy):
      - Source domain: myapp_t
      - Target: myapp_var_run_t sock_file + myapp_backend_t unix_stream_socket peer
    """
    if not NOTIFY_SOCK.exists():
        return (
            jsonify(
                {
                    "status": "error",
                    "endpoint": "/notify-socket",
                    "path": str(NOTIFY_SOCK),
                    "error": "notify socket not found (is myapp-backend.service running?)",
                }
            ),
            503,
        )

    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(5)
        client.connect(str(NOTIFY_SOCK))
        client.sendall(b"ping\n")
        payload = client.recv(1024).decode("utf-8")
        client.close()
    except OSError as exc:
        logger.exception("Notify socket call failed for %s", NOTIFY_SOCK)
        return (
            jsonify(
                with_selinux_error(
                    {
                        "status": "error",
                        "endpoint": "/notify-socket",
                        "path": str(NOTIFY_SOCK),
                        "error": str(exc),
                        "selinux_hint": (
                            "Expected AVC: myapp_t -> myapp_var_run_t:sock_file write and "
                            "unix_stream_socket connectto to backend peer."
                        ),
                    },
                    exc,
                )
            ),
            500,
        )

    logger.info("Notify socket call succeeded")
    return jsonify(
        {
            "status": "ok",
            "endpoint": "/notify-socket",
            "path": str(NOTIFY_SOCK),
            "backend_response": payload.strip(),
        }
    )


@app.route("/rotate-log", methods=["GET"])
def rotate_log():
    """
    Simulate logrotate: rename data.log and create a fresh file.

    SELinux denial (before policy):
      - Source domain: myapp_t
      - Target: myapp_var_lib_t dir/file
      - Permissions: rename, unlink, create, write on dir/file
    """
    rotated = DATA_LOG_PATH.with_suffix(".log.1")
    try:
        if DATA_LOG_PATH.exists():
            if rotated.exists():
                rotated.unlink()
            DATA_LOG_PATH.rename(rotated)
        DATA_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        DATA_LOG_PATH.write_text("", encoding="utf-8")
    except OSError as exc:
        logger.exception("Log rotation failed at %s", DATA_LOG_PATH)
        return jsonify(with_selinux_error({"status": "error", "endpoint": "/rotate-log", "error": str(exc)}, exc)), 500

    if shutil.which("logrotate") and Path("/etc/logrotate.d/myapp").is_file():
        subprocess.run(["logrotate", "-f", "/etc/logrotate.d/myapp"], check=False, timeout=30)

    return jsonify(
        {
            "status": "ok",
            "endpoint": "/rotate-log",
            "rotated_to": str(rotated),
            "new_log": str(DATA_LOG_PATH),
        }
    )


if __name__ == "__main__":
    # Binding to 0.0.0.0:8888 may log tcp_socket name_bind AVC for myapp_t
    # until corenet_tcp_bind_all_unreserved_ports or port-specific rule is added.
    logger.info("Starting Order Processor on %s:%s", APP_HOST, APP_PORT)
    app.run(host=APP_HOST, port=APP_PORT, debug=False)
