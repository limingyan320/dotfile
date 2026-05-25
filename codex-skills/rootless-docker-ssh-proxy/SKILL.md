---
name: rootless-docker-ssh-proxy
description: Use when configuring or debugging proxy settings for rootless Docker where the upstream HTTP/HTTPS proxy is exposed on the host through SSH reverse forwarding and is only reachable as 127.0.0.1:<port>. Covers Docker daemon pulls, docker run containers, and BuildKit/docker build proxy behavior.
metadata:
  short-description: Configure rootless Docker with an SSH reverse-forwarded proxy
---

# Rootless Docker SSH Proxy

## Purpose

Use this skill when a machine can reach the internet only through a proxy forwarded from another machine, typically through SSH reverse forwarding:

```text
127.0.0.1:<UPSTREAM_PROXY_PORT> on this host -> SSH reverse tunnel -> proxy on another machine
```

Rootless Docker often cannot use that loopback proxy directly. Containers see `127.0.0.1` as the container itself, and rootless `dockerd` may run under rootlesskit with host-loopback access disabled.

The reliable pattern is to create a Docker-reachable local bridge:

```text
<HOST_REACHABLE_IP>:<BRIDGE_PROXY_PORT> -> 127.0.0.1:<UPSTREAM_PROXY_PORT>
```

Then configure Docker daemon, Docker client proxy injection, and BuildKit to use the bridge address.

## Variables

Choose these per machine. Do not reuse concrete ports or IPs from another host.

```bash
export UPSTREAM_PROXY_HOST=127.0.0.1
export UPSTREAM_PROXY_PORT=<ssh-reverse-forwarded-proxy-port>
export UPSTREAM_PROXY="http://${UPSTREAM_PROXY_HOST}:${UPSTREAM_PROXY_PORT}"

export HOST_REACHABLE_IP=<host-ip-reachable-from-rootless-docker>
export BRIDGE_PROXY_PORT=<free-port-for-docker-reachable-proxy-bridge>
export BRIDGE_PROXY="http://${HOST_REACHABLE_IP}:${BRIDGE_PROXY_PORT}"

export NO_PROXY_LIST="localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,.local,.internal"
```

Find candidate values:

```bash
ip -4 -brief addr
ss -ltnp | rg "127\\.0\\.0\\.1:${UPSTREAM_PROXY_PORT}|:${BRIDGE_PROXY_PORT}"
```

## Investigate First

Confirm rootless Docker and current proxy state before editing:

```bash
docker context ls
docker info | rg -i 'context|rootless|proxy|docker root dir'
systemctl --user status docker --no-pager
systemctl --user show docker --property=Environment --property=FragmentPath --property=DropInPaths --no-pager
```

Search for existing proxy configuration:

```bash
rg -n 'proxy|Proxy|HTTP_PROXY|HTTPS_PROXY|NO_PROXY|httpProxy|httpsProxy|noProxy' \
  ~/.docker ~/.config/systemd/user /etc/systemd/system /etc/docker 2>/dev/null
```

Check Buildx:

```bash
docker buildx ls
docker buildx inspect 2>/dev/null
```

Rootless Docker usually uses:

```text
~/.config/systemd/user/docker.service
~/.config/systemd/user/docker.service.d/*.conf
~/.docker/config.json
/run/user/$UID/docker.sock
```

## Create A Proxy Bridge

Prefer a user-level TCP forwarder from the host-reachable address to the upstream loopback proxy.

If `socat` exists, use it in a user service:

```bash
socat TCP-LISTEN:${BRIDGE_PROXY_PORT},bind=${HOST_REACHABLE_IP},reuseaddr,fork TCP:${UPSTREAM_PROXY_HOST}:${UPSTREAM_PROXY_PORT}
```

If `socat` is not installed, create `~/.local/bin/tcp-forward.py`:

```python
#!/usr/bin/env python3
import argparse
import select
import socket
import socketserver
import threading


class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 128


class ForwardHandler(socketserver.BaseRequestHandler):
    def handle(self):
        upstream = socket.create_connection((self.server.target_host, self.server.target_port), timeout=10)
        with upstream:
            sockets = [self.request, upstream]
            while True:
                readable, _, errored = select.select(sockets, [], sockets, 60)
                if errored:
                    return
                for src in readable:
                    dst = upstream if src is self.request else self.request
                    data = src.recv(65536)
                    if not data:
                        return
                    dst.sendall(data)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", required=True)
    parser.add_argument("--listen-port", required=True, type=int)
    parser.add_argument("--target-host", required=True)
    parser.add_argument("--target-port", required=True, type=int)
    args = parser.parse_args()

    server = ThreadingTCPServer((args.listen_host, args.listen_port), ForwardHandler)
    server.target_host = args.target_host
    server.target_port = args.target_port

    stopper = threading.Event()

    def stop(*_):
        stopper.set()
        server.shutdown()

    import signal

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    with server:
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.5}, daemon=True)
        thread.start()
        stopper.wait()


if __name__ == "__main__":
    main()
```

Create `~/.config/systemd/user/docker-proxy-forwarder.service`:

```ini
[Unit]
Description=Forward container-reachable Docker proxy to SSH reverse proxy
After=default.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 %h/.local/bin/tcp-forward.py --listen-host HOST_REACHABLE_IP --listen-port BRIDGE_PROXY_PORT --target-host 127.0.0.1 --target-port UPSTREAM_PROXY_PORT
Restart=always
RestartSec=2
NoNewPrivileges=true

[Install]
WantedBy=default.target
```

Replace `HOST_REACHABLE_IP`, `BRIDGE_PROXY_PORT`, and `UPSTREAM_PROXY_PORT` with machine-specific values before starting the service.

## Configure Docker

Configure the rootless Docker daemon in `~/.config/systemd/user/docker.service.d/http-proxy.conf`:

```ini
[Unit]
Wants=docker-proxy-forwarder.service
After=docker-proxy-forwarder.service

[Service]
Environment="HTTP_PROXY=http://HOST_REACHABLE_IP:BRIDGE_PROXY_PORT"
Environment="HTTPS_PROXY=http://HOST_REACHABLE_IP:BRIDGE_PROXY_PORT"
Environment="NO_PROXY=localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,.local,.internal"
```

Configure Docker client proxy injection in `~/.docker/config.json`:

```json
{
  "auths": {},
  "currentContext": "rootless",
  "proxies": {
    "default": {
      "httpProxy": "http://HOST_REACHABLE_IP:BRIDGE_PROXY_PORT",
      "httpsProxy": "http://HOST_REACHABLE_IP:BRIDGE_PROXY_PORT",
      "noProxy": "localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,.local,.internal"
    }
  }
}
```

Apply:

```bash
chmod +x ~/.local/bin/tcp-forward.py
python3 -m py_compile ~/.local/bin/tcp-forward.py
python3 -m json.tool ~/.docker/config.json >/dev/null

systemctl --user daemon-reload
systemctl --user enable --now docker-proxy-forwarder.service
systemctl --user restart docker.service
```

## Buildx

Prefer the active rootless builder:

```bash
docker buildx ls
```

If a builder points to `/var/run/docker.sock`, it is rootful and may fail on a rootless-only machine. Remove or ignore it. Current builds should use the `rootless*` builder.

If creating a `docker-container` builder, set its proxy environment to `http://HOST_REACHABLE_IP:BRIDGE_PROXY_PORT`, not `127.0.0.1:<UPSTREAM_PROXY_PORT>`.

## Validate

Validate the upstream proxy from the host:

```bash
curl -I --max-time 10 --proxy "http://127.0.0.1:${UPSTREAM_PROXY_PORT}" https://registry-1.docker.io/v2/
```

Validate the Docker-reachable bridge:

```bash
curl -I --max-time 10 --proxy "http://${HOST_REACHABLE_IP}:${BRIDGE_PROXY_PORT}" https://registry-1.docker.io/v2/
ss -ltnp | rg ":${UPSTREAM_PROXY_PORT}|:${BRIDGE_PROXY_PORT}"
```

Validate daemon proxy:

```bash
docker info | rg -i 'proxy|rootless|context'
docker pull alpine:3.20
```

Validate container proxy injection:

```bash
docker run --rm curlimages/curl:8.10.1 -I --max-time 20 https://registry-1.docker.io/v2/
```

Validate BuildKit:

```bash
docker build --no-cache -t proxy-build-test - <<'EOF'
FROM curlimages/curl:8.10.1
RUN env | grep -i proxy
RUN curl -I --max-time 20 https://registry-1.docker.io/v2/
EOF

docker rmi proxy-build-test
```

Expected results:

- Registry checks usually return HTTP `401`, which means the proxy path worked and Docker Registry requires authentication.
- `docker info` shows daemon `HTTP Proxy` and `HTTPS Proxy` as the bridge proxy.
- `docker run` and `docker build` show `HTTP_PROXY` / `HTTPS_PROXY` as the bridge proxy.

## Pitfalls

- Do not set container or BuildKit proxy to `127.0.0.1:<UPSTREAM_PROXY_PORT>`.
- Do not assume the rootless daemon can use `127.0.0.1:<UPSTREAM_PROXY_PORT>`.
- BusyBox `wget` can be misleading for HTTPS proxy validation; prefer `curl`.
- If `HOST_REACHABLE_IP`, `UPSTREAM_PROXY_PORT`, or `BRIDGE_PROXY_PORT` changes, update both the forwarder service and Docker proxy config.
- Binding `HOST_REACHABLE_IP:BRIDGE_PROXY_PORT` may expose the proxy bridge to the LAN. If this is unacceptable, use firewall rules or a different SSH/GatewayPorts design.
