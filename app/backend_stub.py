#!/opt/myapp/venv/bin/python
"""
Minimal backend for Tier 6 demo endpoints.

Runs as myapp (myapp_backend_t) with HTTP on :8889 and a Unix notify socket.
"""

from __future__ import annotations

import http.server
import os
import socket
import socketserver
import threading
from pathlib import Path

HTTP_HOST = os.environ.get("MYAPP_BACKEND_HOST", "127.0.0.1")
HTTP_PORT = int(os.environ.get("MYAPP_BACKEND_PORT", "8889"))
NOTIFY_SOCK = Path(os.environ.get("MYAPP_NOTIFY_SOCK", "/run/myapp/notify.sock"))


class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path in ("/", "/health"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok","service":"myapp-backend"}\n')
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, fmt: str, *args: object) -> None:
        return


def unix_listener(ready: threading.Event) -> None:
    NOTIFY_SOCK.parent.mkdir(parents=True, exist_ok=True)
    if NOTIFY_SOCK.exists():
        NOTIFY_SOCK.unlink()

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(NOTIFY_SOCK))
    server.listen(5)
    os.chmod(NOTIFY_SOCK, 0o666)
    ready.set()

    while True:
        conn, _addr = server.accept()
        with conn:
            conn.recv(1024)
            conn.sendall(b'{"status":"ok","channel":"notify"}\n')


def main() -> None:
    ready = threading.Event()
    listener = threading.Thread(target=unix_listener, args=(ready,), daemon=True)
    listener.start()
    if not ready.wait(timeout=10):
        raise RuntimeError(f"notify socket not ready at {NOTIFY_SOCK}")

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer((HTTP_HOST, HTTP_PORT), HealthHandler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    main()
