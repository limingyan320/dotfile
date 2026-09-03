from __future__ import annotations

import importlib.util
import socket
import threading
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "isolated_codex.py"
SPEC = importlib.util.spec_from_file_location("isolated_codex", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
isolated_codex = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(isolated_codex)


class HttpConnectSocketTest(unittest.TestCase):
    def test_connect_proxy_tunnel_supports_basic_auth(self) -> None:
        client, server = socket.socketpair()
        received = bytearray()

        def proxy() -> None:
            try:
                while not received.endswith(b"\r\n\r\n"):
                    received.extend(server.recv(1))
                server.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            finally:
                server.close()

        worker = threading.Thread(target=proxy)
        worker.start()
        with mock.patch.object(
            isolated_codex.socket,
            "create_connection",
            return_value=client,
        ):
            tunnel = isolated_codex.http_connect_socket(
                "http://user:pass@proxy.example:8080",
                "smtp.gmail.com",
                465,
                1,
            )
        worker.join(timeout=1)
        self.assertFalse(worker.is_alive())
        self.assertIs(tunnel, client)
        self.assertIn(b"CONNECT smtp.gmail.com:465 HTTP/1.1", received)
        self.assertIn(b"Proxy-Authorization: Basic", received)
        tunnel.close()

    def test_connect_proxy_rejects_non_success_status(self) -> None:
        client, server = socket.socketpair()

        def proxy() -> None:
            try:
                request = bytearray()
                while not request.endswith(b"\r\n\r\n"):
                    request.extend(server.recv(1))
                server.sendall(b"HTTP/1.1 403 Forbidden\r\n\r\n")
            finally:
                server.close()

        worker = threading.Thread(target=proxy)
        worker.start()
        with mock.patch.object(
            isolated_codex.socket,
            "create_connection",
            return_value=client,
        ):
            with self.assertRaisesRegex(
                isolated_codex.UserError,
                "CONNECT failed",
            ):
                isolated_codex.http_connect_socket(
                    "http://proxy.example:8080",
                    "smtp.gmail.com",
                    465,
                    1,
                )
        worker.join(timeout=1)
        self.assertFalse(worker.is_alive())


if __name__ == "__main__":
    unittest.main()
