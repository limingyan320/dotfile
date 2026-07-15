#!/usr/bin/env python3
import json
import os
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import notify as notify_backend


HERE = Path(__file__).resolve().parent
HOST = os.environ.get("CODEX_NOTIFY_LISTEN_HOST", "127.0.0.1")
PORT = int(os.environ.get("CODEX_NOTIFY_LISTEN_PORT", "47789"))
MAX_BODY_BYTES = 1024 * 1024
ACK_TTL_SECONDS = 60 * 60
MAX_POPUP_SLOTS = 8


class PopupRegistry:
    def __init__(self):
        self.lock = threading.Lock()
        self.active = {}
        self.acknowledged = {}

    @staticmethod
    def _stop_process(process):
        if not process or process.poll() is not None:
            return
        try:
            process.terminate()
        except OSError:
            pass

    def _cleanup(self):
        now = time.monotonic()
        self.active = {
            key: value
            for key, value in self.active.items()
            if value["process"].poll() is None
        }
        self.acknowledged = {
            key: timestamp
            for key, timestamp in self.acknowledged.items()
            if now - timestamp < ACK_TTL_SECONDS
        }

    def _next_slot(self):
        used = {value["slot"] for value in self.active.values()}
        for slot in range(MAX_POPUP_SLOTS):
            if slot not in used:
                return slot
        return len(self.active) % MAX_POPUP_SLOTS

    def show(self, payload):
        notification_id = str(payload.get("notification-id") or "")
        if not notification_id:
            return False
        with self.lock:
            self._cleanup()
            if notification_id in self.acknowledged or notification_id in self.active:
                return True
            slot = self._next_slot()
            process = notify_backend.launch_macos_notification(payload, slot=slot)
            if process is None:
                return False
            self.active[notification_id] = {
                "process": process,
                "slot": slot,
                "created_at": time.monotonic(),
            }
            return True

    def dismiss(self, notification_id):
        if not notification_id:
            return False
        with self.lock:
            self._cleanup()
            self.acknowledged[notification_id] = time.monotonic()
            item = self.active.pop(notification_id, None)
            if item:
                self._stop_process(item["process"])
            return True

    def snapshot(self):
        with self.lock:
            self._cleanup()
            return {
                "active": sorted(self.active),
                "acknowledged": len(self.acknowledged),
            }

    def close(self):
        with self.lock:
            for item in self.active.values():
                self._stop_process(item["process"])
            self.active.clear()


REGISTRY = PopupRegistry()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def _send_json(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path != "/health":
            self.send_response(404)
            self.end_headers()
            return
        self._send_json(200, REGISTRY.snapshot())

    def do_POST(self):
        if self.path not in {"/notify", "/dismiss"}:
            self.send_response(404)
            self.end_headers()
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_response(400)
            self.end_headers()
            return
        if length <= 0 or length > MAX_BODY_BYTES:
            self.send_response(413)
            self.end_headers()
            return

        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except Exception:
            self.send_response(400)
            self.end_headers()
            return

        if not isinstance(payload, dict):
            self.send_response(400)
            self.end_headers()
            return

        if self.path == "/dismiss":
            REGISTRY.dismiss(str(payload.get("notification-id") or ""))
            self.send_response(204)
            self.end_headers()
            return

        if not REGISTRY.show(payload):
            self.send_response(500)
            self.end_headers()
            return

        self.send_response(204)
        self.end_headers()


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)

    def stop_server(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop_server)
    signal.signal(signal.SIGINT, stop_server)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        REGISTRY.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
