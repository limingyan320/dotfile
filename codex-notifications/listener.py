#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


HERE = Path(__file__).resolve().parent
NOTIFY_SCRIPT = HERE / "notify.py"
HOST = os.environ.get("CODEX_NOTIFY_LISTEN_HOST", "127.0.0.1")
PORT = int(os.environ.get("CODEX_NOTIFY_LISTEN_PORT", "47789"))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_POST(self):
        if self.path != "/notify":
            self.send_response(404)
            self.end_headers()
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_response(400)
            self.end_headers()
            return

        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except Exception:
            self.send_response(400)
            self.end_headers()
            return

        env = os.environ.copy()
        env["CODEX_NOTIFY_SKIP_FORWARD"] = "1"
        try:
            subprocess.Popen(
                ["python3", str(NOTIFY_SCRIPT), json.dumps(payload, ensure_ascii=False)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=env,
                start_new_session=True,
            )
        except OSError:
            self.send_response(500)
            self.end_headers()
            return

        self.send_response(204)
        self.end_headers()


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
