#!/opt/myapp/venv/bin/python
"""
Order Processor App - Flask service designed to trigger SELinux AVC denials.

When running under myapp_t in permissive mode, denied operations are logged to
audit.log but still succeed. In enforcing mode (after AI policy is applied),
these endpoints should work without new AVC denials.
"""

from __future__ import annotations

import logging
import subprocess
import sys
import shutil
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

DATA_LOG_PATH = Path("/var/myapp/data.log")
BACKUP_SCRIPT = Path("/opt/myapp/bin/backup.sh")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("myapp")

app = Flask(__name__)


@app.route("/", methods=["GET"])
def health_check():
    """Simple health check - should not trigger SELinux denials."""
    return jsonify(
        {
            "status": "ok",
            "service": "order-processor",
            "port": APP_PORT,
        }
    )


@app.route("/save-log", methods=["GET"])
def save_log():
    """
    Attempt to append a timestamp to /var/myapp/data.log.

    SELinux denial (before policy):
      - Source domain: myapp_t (Flask/python3 process)
      - Target context: typically var_t or an unlabeled path under /var/myapp
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
                {
                    "status": "error",
                    "endpoint": "/save-log",
                    "path": str(DATA_LOG_PATH),
                    "error": str(exc),
                    "selinux_hint": (
                        "Expected AVC: myapp_t -> file write on /var/myapp/data.log. "
                        "Policy needs allow myapp_t myapp_var_lib_t:file { write append open };"
                    ),
                }
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
                {
                    "status": "error",
                    "endpoint": "/run-script",
                    "path": str(BACKUP_SCRIPT),
                    "error": str(exc),
                    "selinux_hint": (
                        "Expected AVC: myapp_t -> file execute on backup.sh. "
                        "Policy needs domain_auto_trans or allow execute + transition."
                    ),
                }
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
        return jsonify({"status": "error", "endpoint": "/rotate-log", "error": str(exc)}), 500

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
