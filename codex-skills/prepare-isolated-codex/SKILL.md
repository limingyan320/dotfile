---
name: prepare-isolated-codex
description: Prepare, verify, launch, monitor, and resume an externally isolated OCI container for unattended Codex work. Use when the user wants Codex to work inside a disposable or long-running container, asks for an isolated/root-capable agent environment, wants a portable sandbox on Linux, macOS, Windows, or WSL, or needs fail-fast owner notification for an unattended run. The base image is resolved from the user's explicit choice, target platform, project, and task capabilities; this skill never assumes a fixed Ubuntu, CUDA, Python, or Node image.
---

# Prepare Isolated Codex

Generate a project-specific container bundle with a declared image, mounts,
devices, network, credentials, resource limits, failure policy, and host-side
notification channel. The bundle is the executable isolation boundary; this
skill is the planner and operator.

## Non-Negotiable Model

Do not select a base image inside the generic runner. Resolve it before `init`:

1. Use an image or Dockerfile explicitly requested by the user.
2. Otherwise inspect the project runtime, lockfiles, documented environment,
   hardware requirements, and host/container architecture.
3. Prefer an existing project image when it satisfies the task.
4. Present the inferred image and material tradeoffs before building it.
5. If several materially different images remain plausible, ask the user. Do
   not silently choose Ubuntu, CUDA, Python, Node, or `latest`.

Read [references/image-resolution.md](references/image-resolution.md) when
selecting an image. Read [references/security-contract.md](references/security-contract.md)
before weakening a default boundary. Read [references/configuration.md](references/configuration.md)
when adding mounts, GPU devices, dependency probes, proxies, or notifications.

## Workflow

Set the CLI path once:

```bash
ISOLATED_CODEX_SKILL="${CODEX_HOME:-$HOME/.codex}/skills/prepare-isolated-codex"
ISOLATED_CODEX="python3 $ISOLATED_CODEX_SKILL/scripts/isolated_codex.py"
```

1. Inspect the target repository instructions and task requirements.
2. Run host capability discovery:

   ```bash
   $ISOLATED_CODEX doctor
   ```

3. Resolve an explicit base image or Dockerfile, then initialize a bundle:

   ```bash
   $ISOLATED_CODEX init \
     --bundle <bundle-directory> \
     --workspace <project-directory> \
     --base-image <resolved-image> \
     --network <none|bridge>
   ```

   Use `--dockerfile` plus `--build-context` for a project image. Use
   `--injection preinstalled` only when the selected image already contains a
   compatible `codex` binary. Otherwise the generated thin layer injects the
   pinned Codex CLI without changing the task image's package manager.
   If the worker uses a custom model provider, pass a dedicated portable
   `--codex-config`; the generated minimal config intentionally does not inherit
   host providers, hooks, MCP servers, notify commands, or machine-local paths.

4. Edit `<bundle>/sandbox.json` for explicit mounts, GPU devices, host
   dependency checks, proxy variables, limits, and notification channels. An
   online unattended worker must declare a continuous container-scope probe for
   its actual proxy or model endpoint; `verify` rejects the bundle otherwise.
5. Run the complete gate:

   ```bash
   $ISOLATED_CODEX doctor --bundle <bundle-directory>
   $ISOLATED_CODEX build --bundle <bundle-directory>
   $ISOLATED_CODEX verify --bundle <bundle-directory>
   ```

   For online bundles, `verify` runs a redacted `codex doctor` check and a
   timeout-bounded minimal model roundtrip inside the exact boundary. It refuses
   failed authentication/provider reachability and never prints raw diagnostics.

6. Test owner notification before leaving a run unattended:

   ```bash
   $ISOLATED_CODEX notify-test --bundle <bundle-directory>
   ```

7. Launch only after `verify` records a matching image/config attestation:

   ```bash
   $ISOLATED_CODEX run --bundle <bundle-directory>
   $ISOLATED_CODEX run --bundle <bundle-directory> \
     --mode interactive --prompt-file <spec-file>
   $ISOLATED_CODEX run --bundle <bundle-directory> \
     --mode exec --prompt-file <spec-file>
   ```

   An interactive prompt file is mounted into the container control directory
   and becomes the session objective. Use a project wrapper script when operators
   should not need to know the generic Python runner or bundle paths.

Use `status`, `stop`, and `shell` for inspection and recovery. For an SSH
session, keep the host supervisor in `tmux`, `screen`, a service manager, or an
equivalent persistent terminal. The supervisor, not the container, owns alerts.

## Fail Fast And Contact The Owner

Unattended Codex must not repeatedly fight infrastructure failures. Declare
known dependencies in `failure_policy.preflight` and set `continuous: true` for
dependencies that the host should keep monitoring. Examples include an SSH
probe, proxy TCP endpoint, model endpoint, registry, GPU precondition, or free
disk check.

The launcher also injects a fail-fast instruction. If Codex discovers an
undeclared environmental blocker, it must run:

```bash
contact-owner <code> <summary> [detail]
```

Examples: `ssh_unreachable`, `proxy_unavailable`, `dns_failure`,
`credential_missing`, `permission_denied`, `gpu_mismatch`, or `disk_full`.
`contact-owner` writes a structured event and exits with code 86. The host
supervisor stops the container and sends the configured notification. It also
alerts on an unexplained non-zero container exit.

Never mount SMTP credentials into the worker. Gmail SMTP is one supported host
channel; keep its username and app password in environment variables or another
host secret provider. The host always writes a local notification spool record,
including when SMTP itself is unavailable.

## Boundary Rules

- Never mount the Docker/Podman socket, host SSH directory, whole host home,
  sudo credentials, or unrelated project trees.
- Mount each path explicitly with `ro` or `rw`; default additional mounts to
  `ro`.
- Keep the image root filesystem read-only, drop all capabilities, enable
  `no-new-privileges`, and retain PID/resource limits unless the task proves a
  concrete need.
- Default devices to none. Select GPU devices explicitly; never infer permission
  to use every visible device.
- Inject authentication read-only and keep Codex runtime state in a dedicated
  bundle directory.
- Never render injected credential values in commands or failure details. The
  runner must redact sensitive environment values before reporting a subprocess
  error.
- Prefer a dedicated Git worktree for unattended writes. An `rw` bind mount
  allows the container to modify or delete that mounted tree.
- Do not enable Codex's internal sandbox bypass unless the current configuration
  and exact image have a valid `verify` attestation. The runner enforces this.
- Report the detected isolation grade: Linux rootless is `strong`; Linux
  containers inside a macOS/Windows VM are `vm-isolated`; Linux rootful is
  `degraded` and requires explicit opt-in.
- Native Windows containers are unsupported. On Windows use Linux containers
  through Docker Desktop or run from WSL2.

## Completion Evidence

Before calling the environment ready, report:

- selected image/Dockerfile and why it matches the task;
- host platform, engine, architecture, and isolation grade;
- writable and read-only mounts;
- network/proxy and device policy;
- successful `doctor`, `build`, `verify`, and `notify-test` results;
- exact launch/resume command and location of blocked-event/notification logs.
