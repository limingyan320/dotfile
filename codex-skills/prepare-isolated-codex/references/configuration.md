# Bundle Configuration

`sandbox.json` is intentionally explicit and machine-local. It may contain
paths and email addresses, but never passwords or API tokens.

## Image

```json
{
  "image": {
    "source": "image",
    "base": "registry.example/task-image:pinned-version",
    "dockerfile": null,
    "build_context": null,
    "platform": null,
    "injection": "layer",
    "codex_version": "0.147.0"
  }
}
```

`source` is `image` or `dockerfile`. `preinstalled` skips Codex binary injection
but still builds a minimal derivative layer containing the boundary verifier and
`contact-owner` helper.

## Codex Config And Authentication

Without `--codex-config`, `init` creates a minimal worker config for the standard
provider. It deliberately does not clone the host config because that can carry
machine-local hook paths, notify commands, MCP servers, provider URLs, and other
unrelated authority. Supply a dedicated portable config when the worker needs a
custom provider or model. Keep `hooks = false` unless the worker image and task
explicitly require audited hooks.

The auth file is mounted read-only. For an online bundle, `verify` runs
`codex doctor --json` and a minimal model roundtrip inside the exact
image/network boundary. Raw diagnostic output is not printed because transport
errors can contain partially redacted credential material. These checks consume
a small model request and must pass before an unattended launch.

## Dependency Probes

Host probes run before launch. Probes with `continuous: true` run periodically
while the container is alive.

```json
{
  "name": "SSH target",
  "type": "command",
  "argv": ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "gpu", "true"],
  "timeout_seconds": 10,
  "continuous": true
}
```

Other forms:

```json
{"name":"proxy","type":"tcp","host":"127.0.0.1","port":7890,"timeout_seconds":3,"continuous":true}
{"name":"endpoint","type":"http","url":"https://example.com/health","allowed_status":[200],"timeout_seconds":5,"continuous":true}
```

Continuous probes stop a run after one failure by default. For endpoints where
an isolated transport reset is expected, set `failure_threshold` from 2 through
5. Only consecutive failures count; a successful probe resets the counter.
Preflight still fails immediately, so this does not permit launching with a
known-broken dependency.

Commands are argv arrays, never shell strings.

An online (`bridge`) unattended bundle must include at least one container-scope
command probe with `continuous: true`. It should exercise the real proxy or
model endpoint over TLS from inside the selected task image, not merely test
host connectivity. `verify` refuses to attest an online bundle without this
guard. The selected image must therefore contain the probe command.

## SMTP Notification

```json
{
  "type": "smtp",
  "host": "smtp.gmail.com",
  "port": 465,
  "security": "ssl",
  "username_env": "CODEX_ALERT_SMTP_USERNAME",
  "password_env": "CODEX_ALERT_SMTP_PASSWORD",
  "from_env": "CODEX_ALERT_SMTP_FROM",
  "proxy_url_env": "HTTPS_PROXY",
  "to": ["owner@example.com"]
}
```

For Gmail, use an account-authorized SMTP credential such as an app password,
not the normal account password. Export secrets only in the host supervisor's
environment. The worker never receives them. `notify-test` must pass before an
unattended run.

When the host cannot reach SMTP directly, optional `proxy_url_env` names a host
environment variable containing an `http://` CONNECT proxy. The host notifier
uses that tunnel for SMTP and TLS; the proxy setting is not an SMTP credential
and need not be injected into the worker unless its own network also requires
the same proxy.

Every alert is first written to `<bundle>/runtime/notifications/`. SMTP delivery
status is added to that record. This preserves the incident when email delivery
also fails.

SMTP environment-variable names are rejected if they also appear in
`environment` or `environment_from_host`. This prevents an alert credential
from being accidentally passed into the worker.

Do not put task credentials directly in `environment`, because `sandbox.json`
is a regular file. Name them in `environment_from_host` so the supervisor reads
them at launch. Notification credential names remain forbidden there because
they are host-supervisor-only.

A `command` notification channel executes its declared argv on the host and
appends the spool JSON path as the final argument. Treat that command as trusted
host code; prefer a small fixed notifier script rather than a shell interpreter.

## Proxy Reachability

`network.proxy_url_env` names a host environment variable whose value is
injected as the worker's proxy URL. That URL must be reachable from inside the
container. In particular, host `127.0.0.1` refers to the container after
injection and usually will not work. Use the platform's documented host gateway,
a LAN address, or an external proxy, and declare a continuous TCP/HTTP probe.
Proxy variables configure clients; they do not enforce proxy-only egress.

Online workers must also have a CA trust store. Common Linux locations are
detected automatically; set `network.ca_bundle` to an absolute container path
for a project-specific location. The runner does not silently install CA files
because dependency composition belongs to the selected task image.

## Additional Mounts And GPU

```json
{"source":"/host/data","target":"/data","mode":"ro"}
```

Additional mounts default conceptually to read-only; set `rw` only deliberately.
NVIDIA devices are strings accepted by the container engine, preferably stable
UUIDs. An empty device list means no GPU access.

Schema v1 supports Docker with a Linux container backend. Docker Desktop on
Windows/macOS and Docker Engine on Linux are supported deployment classes;
native Windows containers and Podman are not claimed by this version.
