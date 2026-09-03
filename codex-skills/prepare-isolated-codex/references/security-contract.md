# Security Contract

## Fixed Boundary

- OCI worker root filesystem is read-only.
- All Linux capabilities are dropped and `no-new-privileges` is enabled.
- PID, memory, CPU, shared-memory, and temporary-filesystem budgets are explicit.
- Only declared bind mounts exist. Docker socket, host home, SSH keys, sudo
  credentials, and unrelated paths are absent.
- Workspace access is explicitly `ro` or `rw`.
- Workspace must be a task directory. It cannot be the whole host home, an
  ancestor of the home, or contain the host-side sandbox bundle.
- Codex authentication and config are read-only submounts; mutable Codex state
  uses a dedicated directory.
- Devices are absent unless explicitly selected.
- Inner Codex sandbox bypass requires a successful attestation for the exact
  config hash and image ID.

The worker runs as UID 0 because its purpose is to give Codex root-like control
over the isolated task environment. That UID has no Linux capabilities, cannot
write the image root filesystem, and has no container-engine socket, host SSH
keys, host home, or sudo credentials. Root in the worker is not host root.

## Isolation Grades

- `strong`: Linux rootless engine and the fixed boundary pass.
- `vm-isolated`: Linux containers run inside a macOS or Windows container VM.
  Host filesystem exposure still depends on declared bind mounts.
- `degraded`: Linux rootful engine. It is rejected unless
  `runtime.allow_degraded` is explicitly true.

The grade describes privilege containment, not the trustworthiness of a base
image or the application dependencies inside it.

The worker must read a Codex credential to call the model. A worker with network
access can therefore potentially disclose that credential; container isolation
does not make a malicious base image or repository safe. Prefer a dedicated,
revocable credential with the narrowest practical scope and pin trusted images.
`network: none` is useful for boundary verification or offline shell work, but a
normal Codex run needs a route to its configured model endpoint. SMTP
credentials are different: they are never mounted or injected into the worker.

Online verification's doctor and model-roundtrip containers force the workspace
mount to read-only, regardless of the eventual worker's declared write mode.

## Network Semantics

`none` disables container networking. `bridge` gives the worker ordinary OCI
bridge networking. Setting `network.proxy_url_env` injects proxy variables but does
not prove that direct egress is impossible. A project requiring allowlisted-only
egress must provide and verify an external gateway/sidecar; do not describe a
plain proxy variable as an enforced network boundary.

## Failure Semantics

Environment failures are terminal for the current run. After one bounded
diagnostic, the worker emits a blocked event; the host supervisor stops it and
notifies the owner. Secrets used to notify the owner stay on the host.
