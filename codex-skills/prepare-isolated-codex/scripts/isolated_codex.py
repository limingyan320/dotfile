#!/usr/bin/env python3
"""Generate and supervise an externally isolated Codex OCI worker."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import email.message
import hashlib
import json
import os
import pathlib
import platform
import re
import shlex
import shutil
import smtplib
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Sequence, Tuple


SKILL_ROOT = pathlib.Path(__file__).resolve().parents[1]
ASSETS = SKILL_ROOT / "assets"
SCHEMA_VERSION = 1
BLOCKED_EXIT = 86


class UserError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise UserError(message)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def atomic_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def load_json(path: pathlib.Path) -> Dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        fail("cannot read %s: %s" % (path, exc))
    if not isinstance(value, dict):
        fail("expected a JSON object: %s" % path)
    return value


def sensitive_environment_name(name: str) -> bool:
    return bool(
        re.search(
            r"(?:^|_)(?:AUTH|CREDENTIAL|PASSWORD|SECRET|TOKEN)(?:_|$)|API_KEY",
            name.upper(),
        )
    )


def redact_sensitive_text(value: str) -> str:
    redacted = value
    for name, secret in os.environ.items():
        if sensitive_environment_name(name) and len(secret) >= 4:
            redacted = redacted.replace(secret, "<redacted>")
    return redacted


def display_command(command: Sequence[str]) -> str:
    displayed = [str(item) for item in command]
    for index, item in enumerate(displayed):
        if index > 0 and displayed[index - 1] in {"--env", "-e"} and "=" in item:
            name, _value = item.split("=", 1)
            if sensitive_environment_name(name):
                displayed[index] = "%s=<redacted>" % name
    return redact_sensitive_text(shlex.join(displayed))


def run_checked(
    command: Sequence[str],
    *,
    capture: bool = False,
    timeout: Optional[float] = None,
    input_text: Optional[str] = None,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            list(command),
            check=True,
            text=True,
            input=input_text,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            timeout=timeout,
        )
    except FileNotFoundError:
        fail("required command is missing: %s" % command[0])
    except subprocess.TimeoutExpired:
        fail("command timed out: %s" % display_command(command))
    except subprocess.CalledProcessError as exc:
        detail = redact_sensitive_text((exc.stderr or exc.stdout or "").strip())
        fail(
            "command failed (%s): %s%s"
            % (
                exc.returncode,
                display_command(command),
                "\n" + detail if detail else "",
            )
        )


def command_output(command: Sequence[str], timeout: float = 20) -> str:
    return run_checked(command, capture=True, timeout=timeout).stdout.strip()


def slug(value: str) -> str:
    result = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    if not result:
        fail("bundle name does not contain a usable ASCII identifier")
    return result[:48]


def expanded_path(value: str) -> pathlib.Path:
    return pathlib.Path(os.path.expandvars(os.path.expanduser(value))).resolve()


def contains_path(parent: pathlib.Path, child: pathlib.Path) -> bool:
    return parent == child or parent in child.parents


def bundle_path(raw: str) -> pathlib.Path:
    return expanded_path(raw)


def config_path(bundle: pathlib.Path) -> pathlib.Path:
    return bundle / "sandbox.json"


def load_config(bundle: pathlib.Path) -> Dict[str, Any]:
    config = load_json(config_path(bundle))
    validate_config(config, bundle)
    return config


def config_digest(config: Dict[str, Any]) -> str:
    encoded = json.dumps(
        config, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def detect_codex_version() -> str:
    output = command_output(["codex", "--version"])
    match = re.search(r"(\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?)", output)
    if not match:
        fail("cannot parse Codex version from: %s" % output)
    return match.group(1)


def docker_facts(engine: str) -> Dict[str, Any]:
    if shutil.which(engine) is None:
        fail("container engine is not installed: %s" % engine)
    version = load_embedded_json(
        command_output([engine, "version", "--format", "{{json .}}"]),
        "container engine version",
    )
    security = load_embedded_json(
        command_output([engine, "info", "--format", "{{json .SecurityOptions}}"]),
        "container engine security options",
    )
    server = version.get("Server") or {}
    client = version.get("Client") or {}
    host_system = platform.system()
    release_text = ""
    try:
        release_text = pathlib.Path("/proc/version").read_text(
            encoding="utf-8", errors="ignore"
        )
    except OSError:
        pass
    is_wsl = bool(os.environ.get("WSL_INTEROP")) or "microsoft" in release_text.lower()
    rootless = any("rootless" in str(item).lower() for item in security or [])
    server_os = str(server.get("Os") or "")
    if host_system == "Linux" and rootless and not is_wsl:
        grade = "strong"
    elif (host_system in {"Darwin", "Windows"} or is_wsl) and server_os == "linux":
        grade = "vm-isolated"
    else:
        grade = "degraded"
    return {
        "host_system": host_system,
        "host_release": platform.release(),
        "host_machine": platform.machine(),
        "wsl": is_wsl,
        "engine": engine,
        "engine_context": command_output([engine, "context", "show"]),
        "engine_client": client.get("Version"),
        "engine_server": server.get("Version"),
        "engine_server_os": server_os,
        "engine_server_arch": server.get("Arch"),
        "rootless": rootless,
        "security_options": security,
        "isolation_grade": grade,
    }


def load_embedded_json(text: str, label: str) -> Any:
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        fail("invalid JSON from %s: %s" % (label, exc))


def validate_config(config: Dict[str, Any], bundle: pathlib.Path) -> None:
    if config.get("schema_version") != SCHEMA_VERSION:
        fail("unsupported sandbox.json schema_version")
    for key in ("name", "runtime", "image", "workspace", "auth", "network"):
        if key not in config:
            fail("sandbox.json is missing %s" % key)
    runtime = config["runtime"]
    image = config["image"]
    workspace = config["workspace"]
    if runtime.get("engine") != "docker":
        fail("runtime.engine must be docker; Podman is not supported by schema v1")
    if not re.fullmatch(r"[a-f0-9]{10}", str(runtime.get("instance_id") or "")):
        fail("runtime.instance_id must be a 10-character lowercase hex identifier")
    resources = runtime.get("resources") or {}
    for key in ("cpus", "pids_limit"):
        try:
            if float(resources.get(key, 0)) <= 0:
                raise ValueError
        except (TypeError, ValueError):
            fail("runtime.resources.%s must be positive" % key)
    for key in ("memory", "shm_size", "tmp_size"):
        if not isinstance(resources.get(key), str) or not resources[key].strip():
            fail("runtime.resources.%s must be a non-empty engine size" % key)
    policy = config.get("failure_policy", {})
    try:
        poll_interval = float(policy.get("poll_interval_seconds", 5))
    except (TypeError, ValueError):
        fail("failure_policy.poll_interval_seconds must be numeric")
    if not 1 <= poll_interval <= 30:
        fail("failure_policy.poll_interval_seconds must be between 1 and 30")
    if workspace.get("mode") not in {"ro", "rw"}:
        fail("workspace.mode must be ro or rw")
    workspace_path = expanded_path(workspace["path"])
    if not workspace_path.is_dir():
        fail("workspace does not exist: %s" % workspace["path"])
    home = expanded_path("~")
    if workspace_path == pathlib.Path("/") or contains_path(workspace_path, home):
        fail("workspace must be a task directory, not the host home or its ancestor")
    resolved_bundle = bundle.resolve()
    if contains_path(workspace_path, resolved_bundle) or contains_path(
        resolved_bundle, workspace_path
    ):
        fail("bundle and workspace must not contain one another")
    if image.get("source") not in {"image", "dockerfile"}:
        fail("image.source must be image or dockerfile")
    if image.get("injection") not in {"layer", "preinstalled"}:
        fail("image.injection must be layer or preinstalled")
    if image["source"] == "image" and not image.get("base"):
        fail("image.base is required for image source")
    if image["source"] == "dockerfile":
        for key in ("dockerfile", "build_context"):
            path = expanded_path(str(image.get(key) or ""))
            if not path.exists():
                fail("image.%s does not exist: %s" % (key, path))
    if config["network"].get("mode") not in {"none", "bridge"}:
        fail("network.mode must be none or bridge")
    ca_bundle = config["network"].get("ca_bundle")
    if ca_bundle is not None and (
        not isinstance(ca_bundle, str) or not ca_bundle.startswith("/")
    ):
        fail("network.ca_bundle must be null or an absolute container path")
    auth_paths = []
    for key in ("file", "config_file"):
        path = expanded_path(str(config["auth"].get(key) or ""))
        if not path.is_file():
            fail("auth.%s does not exist: %s" % (key, path))
        auth_paths.append(path)
        if workspace["mode"] == "rw" and contains_path(workspace_path, path):
            fail("auth.%s must be outside a writable workspace" % key)
    protected_targets = (
        "/workspace",
        "/codex-home",
        "/codex-control",
        "/bin",
        "/dev",
        "/etc",
        "/proc",
        "/run",
        "/sbin",
        "/sys",
        "/tmp",
        "/usr",
        "/var/run",
    )
    engine_socket_paths = {
        expanded_path("/var/run/docker.sock"),
        expanded_path("/run/docker.sock"),
    }
    forbidden_sources = {
        pathlib.Path("/"),
        home,
        expanded_path("~/.ssh"),
        *engine_socket_paths,
    }
    mounts = config.get("mounts", [])
    if not isinstance(mounts, list):
        fail("mounts must be an array")
    for mount in mounts:
        if not isinstance(mount, dict):
            fail("every additional mount must be an object")
        if mount.get("mode") not in {"ro", "rw"}:
            fail("mount mode must be ro or rw")
        source = expanded_path(str(mount.get("source") or ""))
        target = str(mount.get("target") or "")
        target_path = pathlib.PurePosixPath(target)
        protected_target = any(
            target_path == pathlib.PurePosixPath(item)
            or pathlib.PurePosixPath(item) in target_path.parents
            for item in protected_targets
        )
        ssh_home = expanded_path("~/.ssh")
        forbidden_source_tree = (
            source == home
            or source in home.parents
            or source == ssh_home
            or ssh_home in source.parents
            or source.name in {"docker.sock", "podman.sock"}
            or any(contains_path(source, path) for path in engine_socket_paths)
        )
        exposes_auth = any(
            contains_path(source, path) for path in auth_paths
        )
        exposes_bundle = contains_path(source, resolved_bundle) or contains_path(
            resolved_bundle, source
        )
        if (
            not source.exists()
            or not target.startswith("/")
            or target == "/"
            or ".." in target_path.parts
            or protected_target
            or source in forbidden_sources
            or forbidden_source_tree
            or exposes_auth
            or exposes_bundle
            or target in {"/var/run/docker.sock", "/run/docker.sock"}
            or "," in str(source)
            or "," in target
        ):
            fail("invalid additional mount: %s -> %s" % (source, target))
    environment = config.get("environment", {})
    environment_from_host = config.get("environment_from_host", [])
    if not isinstance(environment, dict) or not isinstance(environment_from_host, list):
        fail("environment must be an object and environment_from_host an array")
    if not all(isinstance(key, str) and key for key in environment_from_host):
        fail("environment_from_host entries must be non-empty names")
    reserved_environment = {
        "HOME",
        "CODEX_HOME",
        "ISOLATED_CODEX_CONTROL",
        "ISOLATED_CODEX_NETWORK_MODE",
    }
    reserved_overrides = reserved_environment.intersection(
        set(environment) | set(environment_from_host)
    )
    if reserved_overrides:
        fail(
            "worker environment cannot override control variables: %s"
            % ", ".join(sorted(reserved_overrides))
        )
    stored_secrets = [
        key
        for key in environment
        if re.search(r"(?:PASSWORD|PASSWD|TOKEN|SECRET|API_?KEY|PRIVATE_?KEY)", key, re.I)
    ]
    if stored_secrets:
        fail(
            "do not store worker secrets in sandbox.json; use environment_from_host: %s"
            % ", ".join(sorted(stored_secrets))
        )
    notification_secret_names = set()
    notifications = config.get("notifications", {})
    channels = notifications.get("channels", [])
    if not isinstance(channels, list):
        fail("notifications.channels must be an array")
    for channel in channels:
        notification_secret_names.update(validate_notification_channel(channel))
    leaked = notification_secret_names.intersection(
        set(environment)
        | set(environment_from_host)
        | {str(config["network"].get("proxy_url_env") or "")}
    )
    if leaked:
        fail(
            "notification secrets must remain host-only, but worker environment includes: %s"
            % ", ".join(sorted(leaked))
        )
    for probe in config.get("failure_policy", {}).get("preflight", []):
        validate_probe(probe)
    if not (bundle / "runtime").is_dir():
        (bundle / "runtime").mkdir(parents=True, exist_ok=True)


def validate_probe(probe: Dict[str, Any]) -> None:
    if not probe.get("name"):
        fail("every dependency probe needs a name")
    if probe.get("scope", "host") not in {"host", "container"}:
        fail("probe scope must be host or container")
    kind = probe.get("type")
    if kind == "command":
        argv = probe.get("argv")
        if not isinstance(argv, list) or not argv or not all(
            isinstance(item, str) and item for item in argv
        ):
            fail("command probe argv must be a non-empty string array")
    elif kind == "tcp":
        if probe.get("scope", "host") != "host":
            fail("tcp probes currently support host scope only")
        if not probe.get("host") or not isinstance(probe.get("port"), int):
            fail("tcp probe requires host and integer port")
    elif kind == "http":
        if probe.get("scope", "host") != "host" or not probe.get("url"):
            fail("http probes currently require host scope and url")
    else:
        fail("probe type must be command, tcp, or http")
    threshold = probe.get("failure_threshold", 1)
    if (
        not isinstance(threshold, int)
        or isinstance(threshold, bool)
        or not 1 <= threshold <= 5
    ):
        fail("probe failure_threshold must be an integer between 1 and 5")


def validate_notification_channel(channel: Dict[str, Any]) -> set[str]:
    if not isinstance(channel, dict):
        fail("every notification channel must be an object")
    kind = channel.get("type")
    if kind == "command":
        argv = channel.get("argv")
        if not isinstance(argv, list) or not argv or not all(
            isinstance(item, str) and item for item in argv
        ):
            fail("notification command argv must be a non-empty string array")
        return set()
    if kind != "smtp":
        fail("notification channel type must be smtp or command")
    if not channel.get("host") or not channel.get("to"):
        fail("SMTP notification requires host and recipients")
    if channel.get("security", "ssl") not in {"ssl", "starttls"}:
        fail("SMTP security must be ssl or starttls")
    proxy_url_env = channel.get("proxy_url_env")
    if proxy_url_env is not None and (
        not isinstance(proxy_url_env, str) or not proxy_url_env
    ):
        fail("SMTP proxy_url_env must be a non-empty environment variable name")
    secret_names = set()
    for key in ("username_env", "password_env"):
        value = channel.get(key)
        if not isinstance(value, str) or not value:
            fail("SMTP notification requires %s" % key)
        secret_names.add(value)
    if channel.get("from_env"):
        secret_names.add(str(channel["from_env"]))
    return secret_names


def require_unattended_guards(config: Dict[str, Any]) -> None:
    if config["network"].get("mode") != "bridge":
        return
    probes = config.get("failure_policy", {}).get("preflight", [])
    if not any(
        probe.get("scope") == "container" and probe.get("continuous") is True
        for probe in probes
    ):
        fail(
            "bridge networking requires a continuous container-scoped dependency probe "
            "before verify"
        )


def generated_image(config: Dict[str, Any]) -> str:
    return "isolated-codex-%s-%s:local" % (
        slug(config["name"]),
        config["runtime"]["instance_id"],
    )


def generated_base_image(config: Dict[str, Any]) -> str:
    return "isolated-codex-%s-%s-base:local" % (
        slug(config["name"]),
        config["runtime"]["instance_id"],
    )


def image_exists(engine: str, image: str) -> bool:
    return subprocess.run(
        [engine, "image", "inspect", image],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0


def image_id(engine: str, image: str) -> str:
    return command_output([engine, "image", "inspect", "--format", "{{.Id}}", image])


def cmd_doctor(args: argparse.Namespace) -> None:
    engine = "docker"
    config = None
    bundle = None
    if args.bundle:
        bundle = bundle_path(args.bundle)
        config = load_config(bundle)
        engine = config["runtime"]["engine"]
    facts = docker_facts(engine)
    facts["status"] = "passed"
    if config:
        if facts["isolation_grade"] == "degraded" and not config["runtime"].get(
            "allow_degraded", False
        ):
            fail("rootful/degraded isolation is not allowed by sandbox.json")
        facts["bundle"] = str(bundle)
        facts["config_sha256"] = config_digest(config)
        facts["image"] = generated_image(config)
        facts["image_present"] = image_exists(engine, generated_image(config))
        facts["notification_channels"] = len(
            config.get("notifications", {}).get("channels", [])
        )
        facts["external_notification_required"] = config.get(
            "notifications", {}
        ).get("require_external", True)
        probe_results = []
        for probe in config.get("failure_policy", {}).get("preflight", []):
            if probe.get("scope", "host") == "container":
                probe_results.append(
                    {"name": probe["name"], "status": "deferred_until_verify"}
                )
            else:
                ok, detail = execute_host_probe(probe)
                probe_results.append(
                    {"name": probe["name"], "status": "passed" if ok else "failed", "detail": detail}
                )
                if not ok:
                    fail("dependency probe failed: %s: %s" % (probe["name"], detail))
        facts["dependency_probes"] = probe_results
    print(json.dumps(facts, ensure_ascii=False, indent=2))


def cmd_init(args: argparse.Namespace) -> None:
    bundle = bundle_path(args.bundle)
    if config_path(bundle).exists() and not args.force:
        fail("bundle already exists; pass --force to replace sandbox.json")
    workspace = expanded_path(args.workspace)
    if not workspace.is_dir():
        fail("workspace does not exist: %s" % workspace)
    if bool(args.base_image) == bool(args.dockerfile):
        fail("specify exactly one of --base-image or --dockerfile")
    auth_root = pathlib.Path(os.environ.get("CODEX_HOME", "~/.codex")).expanduser()
    auth_file = expanded_path(args.auth_file or str(auth_root / "auth.json"))
    if not auth_file.is_file():
        fail("Codex auth file does not exist; pass --auth-file")
    bundle.mkdir(parents=True, exist_ok=True)
    generated_config = bundle / "config" / "codex-config.toml"
    generated_config.parent.mkdir(parents=True, exist_ok=True)
    if args.codex_config:
        codex_config = expanded_path(args.codex_config)
        if not codex_config.is_file():
            fail("Codex config does not exist: %s" % codex_config)
    else:
        if not generated_config.exists():
            generated_config.write_text(
                'disable_response_storage = true\n\n[projects."/workspace"]\ntrust_level = "trusted"\n\n[features]\ngoals = true\nhooks = false\n',
                encoding="utf-8",
            )
        codex_config = generated_config
    source = "image" if args.base_image else "dockerfile"
    instance_id = hashlib.sha256(str(bundle).encode("utf-8")).hexdigest()[:10]
    dockerfile = expanded_path(args.dockerfile) if args.dockerfile else None
    build_context = (
        expanded_path(args.build_context)
        if args.build_context
        else dockerfile.parent if dockerfile else None
    )
    required = args.require_command or ["sh"]
    config = {
        "schema_version": SCHEMA_VERSION,
        "name": args.name or bundle.name,
        "runtime": {
            "engine": args.engine,
            "instance_id": instance_id,
            "allow_degraded": bool(args.allow_degraded),
            "container_name": "isolated-codex-%s-%s"
            % (slug(args.name or bundle.name), instance_id),
            "resources": {
                "cpus": args.cpus,
                "memory": args.memory,
                "pids_limit": args.pids_limit,
                "shm_size": args.shm_size,
                "tmp_size": args.tmp_size,
            },
        },
        "image": {
            "source": source,
            "base": args.base_image,
            "dockerfile": str(dockerfile) if dockerfile else None,
            "build_context": str(build_context) if build_context else None,
            "platform": args.platform,
            "injection": args.injection,
            "codex_version": args.codex_version or detect_codex_version(),
            "bootstrap_image": args.bootstrap_image,
            "required_commands": required,
        },
        "workspace": {"path": str(workspace), "mode": args.workspace_mode},
        "mounts": [],
        "devices": {"nvidia": []},
        "auth": {"file": str(auth_file), "config_file": str(codex_config)},
        "network": {
            "mode": args.network,
            "name": None,
            "proxy_url_env": args.proxy_url_env,
            "no_proxy": "localhost,127.0.0.1",
            "ca_bundle": None,
        },
        "environment": {},
        "environment_from_host": [],
        "codex": {
            "bypass_inner_sandbox": True,
            "search": bool(args.search),
            "extra_args": [],
        },
        "failure_policy": {
            "preflight": [],
            "poll_interval_seconds": 5,
            "codex_doctor_timeout_seconds": 45,
            "model_smoke_timeout_seconds": 45,
            "notify_on_nonzero_exit": True,
            "notify_on_success": False,
        },
        "notifications": {"require_external": True, "channels": []},
    }
    for path in (
        bundle / "runtime" / "codex-home",
        bundle / "runtime" / "control",
        bundle / "runtime" / "notifications",
    ):
        path.mkdir(parents=True, exist_ok=True)
    atomic_json(config_path(bundle), config)
    print("created %s" % config_path(bundle))
    print("base image resolution remains explicit: %s" % (args.base_image or dockerfile))
    print("configure notifications, then run doctor, build, verify, and notify-test")


def build_base(config: Dict[str, Any]) -> str:
    image = config["image"]
    engine = config["runtime"]["engine"]
    platform_args = ["--platform", image["platform"]] if image.get("platform") else []
    if image["source"] == "image":
        return image["base"]
    base_tag = generated_base_image(config)
    command = [
        engine,
        "build",
        *platform_args,
        "--file",
        image["dockerfile"],
        "--tag",
        base_tag,
        image["build_context"],
    ]
    run_checked(command)
    return base_tag


def cmd_build(args: argparse.Namespace) -> None:
    bundle = bundle_path(args.bundle)
    config = load_config(bundle)
    facts = docker_facts(config["runtime"]["engine"])
    if facts["isolation_grade"] == "degraded" and not config["runtime"].get(
        "allow_degraded", False
    ):
        fail("refusing to build under degraded/rootful isolation")
    base = build_base(config)
    image = config["image"]
    engine = config["runtime"]["engine"]
    dockerfile = (
        ASSETS / "Containerfile"
        if image["injection"] == "layer"
        else ASSETS / "Containerfile.preinstalled"
    )
    command = [engine, "build"]
    if image.get("platform"):
        command += ["--platform", image["platform"]]
    command += [
        "--file",
        str(dockerfile),
        "--build-arg",
        "BASE_IMAGE=%s" % base,
        "--tag",
        generated_image(config),
    ]
    if image["injection"] == "layer":
        command += [
            "--build-arg",
            "CODEX_VERSION=%s" % image["codex_version"],
            "--build-arg",
            "CODEX_BOOTSTRAP_IMAGE=%s" % image["bootstrap_image"],
        ]
    command.append(str(SKILL_ROOT))
    run_checked(command)
    print(
        json.dumps(
            {
                "status": "passed",
                "base": base,
                "image": generated_image(config),
                "image_id": image_id(engine, generated_image(config)),
            },
            indent=2,
        )
    )


def mount_arg(source: pathlib.Path, target: str, mode: str) -> str:
    value = "type=bind,src=%s,dst=%s" % (source, target)
    if mode == "ro":
        value += ",readonly"
    return value


def common_run_args(
    config: Dict[str, Any],
    bundle: pathlib.Path,
    name: str,
    *,
    workspace_mode_override: Optional[str] = None,
) -> List[str]:
    engine = config["runtime"]["engine"]
    resources = config["runtime"]["resources"]
    args = [
        engine,
        "run",
        "--rm",
        "--name",
        name,
        "--hostname",
        "isolated-codex",
        "--read-only",
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges",
        "--pids-limit",
        str(resources["pids_limit"]),
        "--cpus",
        str(resources["cpus"]),
        "--memory",
        str(resources["memory"]),
        "--shm-size",
        str(resources["shm_size"]),
        "--tmpfs",
        "/tmp:rw,nosuid,nodev,size=%s" % resources["tmp_size"],
        "--tmpfs",
        "/run:rw,nosuid,nodev,size=64m",
        "--user",
        "0:0",
        "--workdir",
        "/workspace",
    ]
    image = config["image"]
    if image.get("platform"):
        args += ["--platform", image["platform"]]
    network = config["network"]
    if network["mode"] == "none":
        args += ["--network", "none"]
    elif network.get("name"):
        args += ["--network", network["name"]]
    workspace = expanded_path(config["workspace"]["path"])
    state = bundle / "runtime" / "codex-home"
    control = bundle / "runtime" / "control"
    auth = expanded_path(config["auth"]["file"])
    codex_config = expanded_path(config["auth"]["config_file"])
    args += [
        "--mount",
        mount_arg(
            workspace,
            "/workspace",
            workspace_mode_override or config["workspace"]["mode"],
        ),
        "--mount",
        mount_arg(state, "/codex-home", "rw"),
        "--mount",
        mount_arg(control, "/codex-control", "rw"),
        "--mount",
        mount_arg(auth, "/codex-home/auth.json", "ro"),
        "--mount",
        mount_arg(codex_config, "/codex-home/config.toml", "ro"),
    ]
    for item in config.get("mounts", []):
        args += [
            "--mount",
            mount_arg(
                expanded_path(item["source"]), item["target"], item.get("mode", "ro")
            ),
        ]
    devices = config.get("devices", {}).get("nvidia", [])
    if devices:
        # Docker parses --gpus values as CSV. Literal quotes keep a multi-device
        # request in one field when subprocess bypasses shell quote handling.
        args += ["--gpus", '\"device=%s\"' % ",".join(devices)]
    environment = {
        "HOME": "/codex-home",
        "CODEX_HOME": "/codex-home",
        "ISOLATED_CODEX_CONTROL": "/codex-control",
        "ISOLATED_CODEX_INJECTION": image["injection"],
        "ISOLATED_CODEX_NETWORK_MODE": network["mode"],
    }
    environment.update(
        {str(key): str(value) for key, value in config.get("environment", {}).items()}
    )
    for key in config.get("environment_from_host", []):
        if key not in os.environ:
            fail("required host environment variable is missing: %s" % key)
        environment[key] = os.environ[key]
    proxy_env = network.get("proxy_url_env")
    if proxy_env:
        value = os.environ.get(proxy_env)
        if not value:
            fail("proxy environment variable is missing: %s" % proxy_env)
        for key in (
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "ALL_PROXY",
            "http_proxy",
            "https_proxy",
            "all_proxy",
        ):
            environment[key] = value
        environment["NO_PROXY"] = network.get("no_proxy", "")
        environment["no_proxy"] = network.get("no_proxy", "")
    for key, value in sorted(environment.items()):
        args += ["--env", "%s=%s" % (key, value)]
    return args


def cmd_verify(args: argparse.Namespace) -> None:
    bundle = bundle_path(args.bundle)
    config = load_config(bundle)
    require_unattended_guards(config)
    engine = config["runtime"]["engine"]
    facts = docker_facts(engine)
    if facts["isolation_grade"] == "degraded" and not config["runtime"].get(
        "allow_degraded", False
    ):
        fail("refusing degraded/rootful isolation")
    image = generated_image(config)
    if not image_exists(engine, image):
        fail("generated image is missing; run build first")
    name = "%s-verify-%s" % (config["runtime"]["container_name"], os.getpid())
    command = common_run_args(config, bundle, name)
    command += [
        image,
        "/usr/local/bin/verify-boundary",
        config["workspace"]["mode"],
        config["network"]["mode"],
        config["network"].get("ca_bundle") or "",
        *config["image"].get("required_commands", []),
    ]
    run_checked(command)
    for probe in config.get("failure_policy", {}).get("preflight", []):
        ok, detail = execute_probe(probe, config, bundle)
        if not ok:
            fail("dependency probe failed: %s: %s" % (probe["name"], detail))
    codex_health = verify_codex_health(config, bundle)
    attestation = {
        "schema_version": 1,
        "verified_at": utc_now(),
        "config_sha256": config_digest(config),
        "image": image,
        "image_id": image_id(engine, image),
        "isolation_grade": facts["isolation_grade"],
        "codex_health": codex_health,
    }
    atomic_json(bundle / "runtime" / "verification.json", attestation)
    print(json.dumps({"status": "passed", **attestation}, indent=2))


def execute_host_probe(probe: Dict[str, Any]) -> Tuple[bool, str]:
    timeout = float(probe.get("timeout_seconds", 10))
    try:
        if probe["type"] == "command":
            result = subprocess.run(
                probe["argv"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=timeout,
            )
            detail = (result.stderr or result.stdout or "").strip()[-1000:]
            return result.returncode == 0, detail or "exit %s" % result.returncode
        if probe["type"] == "tcp":
            with socket.create_connection(
                (probe["host"], int(probe["port"])), timeout=timeout
            ):
                return True, "connected"
        allowed = probe.get("allowed_status", [200])
        request = urllib.request.Request(probe["url"], method="GET")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status = int(response.status)
        return status in allowed, "HTTP %s" % status
    except (OSError, subprocess.TimeoutExpired, urllib.error.URLError) as exc:
        return False, str(exc)


def execute_probe(
    probe: Dict[str, Any],
    config: Dict[str, Any],
    bundle: pathlib.Path,
    container_name: Optional[str] = None,
) -> Tuple[bool, str]:
    if probe.get("scope", "host") == "host":
        return execute_host_probe(probe)
    timeout = float(probe.get("timeout_seconds", 10))
    engine = config["runtime"]["engine"]
    if container_name:
        command = [engine, "exec", container_name, *probe["argv"]]
    else:
        name = "%s-probe-%s" % (config["runtime"]["container_name"], os.getpid())
        command = common_run_args(config, bundle, name) + [
            generated_image(config),
            *probe["argv"],
        ]
    try:
        result = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
        detail = (result.stderr or result.stdout or "").strip()[-1000:]
        return result.returncode == 0, detail or "exit %s" % result.returncode
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, str(exc)


def run_ephemeral_container(
    config: Dict[str, Any],
    bundle: pathlib.Path,
    suffix: str,
    argv: Sequence[str],
    timeout: float,
) -> subprocess.CompletedProcess[str]:
    engine = config["runtime"]["engine"]
    name = "%s-%s-%s" % (config["runtime"]["container_name"], suffix, os.getpid())
    command = common_run_args(
        config, bundle, name, workspace_mode_override="ro"
    ) + [generated_image(config), *argv]
    try:
        return subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        stop_container(engine, name)
        fail("container %s check timed out after %ss" % (suffix, int(timeout)))
    except OSError as exc:
        stop_container(engine, name)
        fail("container %s check could not run: %s" % (suffix, exc))


def verify_codex_health(config: Dict[str, Any], bundle: pathlib.Path) -> Dict[str, str]:
    if config["network"].get("mode") == "none":
        return {"status": "skipped", "reason": "network disabled"}
    policy = config.get("failure_policy", {})
    doctor = run_ephemeral_container(
        config,
        bundle,
        "doctor",
        ["codex", "doctor", "--json"],
        float(policy.get("codex_doctor_timeout_seconds", 45)),
    )
    try:
        report = json.loads(doctor.stdout)
    except json.JSONDecodeError:
        fail("container Codex doctor did not return valid JSON")
    checks = report.get("checks") or {}
    failures = []
    for check_id in ("auth.credentials", "network.provider_reachability"):
        check = checks.get(check_id) or {}
        if check.get("status") != "ok":
            failures.append("%s: %s" % (check_id, check.get("summary") or "failed"))
    websocket = checks.get("network.websocket_reachability") or {}
    if websocket.get("status") == "fail":
        failures.append(
            "network.websocket_reachability: %s"
            % (websocket.get("summary") or "failed")
        )
    if failures:
        fail(
            "container Codex health check failed: %s. Check the worker-specific "
            "Codex config, credential, proxy, and CA trust."
            % "; ".join(failures)
        )
    marker = "ISOLATED_CODEX_VERIFY_%s" % hashlib.sha256(
        (config_digest(config) + utc_now()).encode("utf-8")
    ).hexdigest()[:16].upper()
    smoke = run_ephemeral_container(
        config,
        bundle,
        "model-smoke",
        [
            "codex",
            "exec",
            "--ephemeral",
            "--dangerously-bypass-approvals-and-sandbox",
            "-C",
            "/workspace",
            "Reply with exactly: %s" % marker,
        ],
        float(policy.get("model_smoke_timeout_seconds", 45)),
    )
    if smoke.returncode != 0 or marker not in smoke.stdout:
        fail(
            "container Codex model smoke test failed. Check the worker-specific "
            "Codex config, credential, provider, proxy, and CA trust."
        )
    return {"status": "passed", "doctor": "passed", "model_roundtrip": "passed"}


def notification_event(
    bundle: pathlib.Path,
    config: Dict[str, Any],
    code: str,
    summary: str,
    detail: str,
    severity: str = "error",
) -> Tuple[pathlib.Path, int, List[str]]:
    event = {
        "schema_version": 1,
        "created_at": utc_now(),
        "bundle": str(bundle),
        "sandbox": config["name"],
        "severity": severity,
        "code": code,
        "summary": summary,
        "detail": detail,
        "deliveries": [],
    }
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    path = bundle / "runtime" / "notifications" / (stamp + ".json")
    atomic_json(path, event)
    delivered = 0
    errors: List[str] = []
    for index, channel in enumerate(config.get("notifications", {}).get("channels", [])):
        try:
            if channel.get("type") == "smtp":
                send_smtp(channel, event)
            elif channel.get("type") == "command":
                argv = channel.get("argv")
                if not isinstance(argv, list) or not argv:
                    fail("notification command channel requires argv")
                run_checked([*argv, str(path)], timeout=float(channel.get("timeout_seconds", 20)))
            else:
                fail("unsupported notification channel type: %s" % channel.get("type"))
            event["deliveries"].append({"channel": index, "status": "delivered"})
            delivered += 1
        except Exception as exc:  # preserve every notification failure in the spool
            message = "channel %s: %s" % (index, exc)
            errors.append(message)
            event["deliveries"].append(
                {"channel": index, "status": "failed", "error": str(exc)}
            )
        atomic_json(path, event)
    return path, delivered, errors


def env_secret(channel: Dict[str, Any], key: str) -> str:
    variable = channel.get(key)
    if not variable or not os.environ.get(variable):
        fail("SMTP secret environment variable is missing: %s" % (variable or key))
    return os.environ[variable]


def smtp_proxy_url(channel: Dict[str, Any]) -> str | None:
    variable = channel.get("proxy_url_env")
    if not variable:
        return None
    value = os.environ.get(variable)
    if not value:
        fail("SMTP proxy environment variable is missing: %s" % variable)
    return value


def http_connect_socket(
    proxy_url: str,
    host: str,
    port: int,
    timeout: float,
) -> socket.socket:
    parsed = urllib.parse.urlsplit(proxy_url)
    if parsed.scheme != "http" or not parsed.hostname:
        fail("SMTP proxy must be an http:// URL")
    proxy_port = parsed.port or 80
    connection = socket.create_connection((parsed.hostname, proxy_port), timeout=timeout)
    connection.settimeout(timeout)
    try:
        headers = [
            "CONNECT %s:%s HTTP/1.1" % (host, port),
            "Host: %s:%s" % (host, port),
            "Proxy-Connection: Keep-Alive",
        ]
        if parsed.username is not None:
            username = urllib.parse.unquote(parsed.username)
            password = urllib.parse.unquote(parsed.password or "")
            credentials = base64.b64encode(
                (username + ":" + password).encode("utf-8")
            ).decode("ascii")
            headers.append("Proxy-Authorization: Basic " + credentials)
        connection.sendall(("\r\n".join(headers) + "\r\n\r\n").encode("ascii"))
        response = bytearray()
        while not response.endswith(b"\r\n\r\n"):
            chunk = connection.recv(1)
            if not chunk:
                fail("SMTP proxy closed the CONNECT response")
            response.extend(chunk)
            if len(response) > 65_536:
                fail("SMTP proxy returned oversized CONNECT headers")
        status_line = bytes(response).split(b"\r\n", 1)[0].decode(
            "ascii", errors="replace"
        )
        parts = status_line.split(" ", 2)
        if len(parts) < 2 or parts[1] != "200":
            fail("SMTP proxy CONNECT failed: %s" % status_line)
        return connection
    except Exception:
        connection.close()
        raise


class ProxySMTP(smtplib.SMTP):
    def __init__(self, proxy_url: str, *args: Any, **kwargs: Any):
        self._proxy_url = proxy_url
        super().__init__(*args, **kwargs)

    def _get_socket(self, host: str, port: int, timeout: float) -> socket.socket:
        return http_connect_socket(self._proxy_url, host, port, timeout)


class ProxySMTPSSL(smtplib.SMTP_SSL):
    def __init__(self, proxy_url: str, *args: Any, **kwargs: Any):
        self._proxy_url = proxy_url
        super().__init__(*args, **kwargs)

    def _get_socket(self, host: str, port: int, timeout: float) -> socket.socket:
        connection = http_connect_socket(self._proxy_url, host, port, timeout)
        try:
            return self.context.wrap_socket(connection, server_hostname=host)
        except Exception:
            connection.close()
            raise


def send_smtp(channel: Dict[str, Any], event: Dict[str, Any]) -> None:
    username = env_secret(channel, "username_env")
    password = env_secret(channel, "password_env")
    from_address = (
        env_secret(channel, "from_env") if channel.get("from_env") else username
    )
    recipients = channel.get("to") or []
    if not recipients:
        fail("SMTP channel has no recipients")
    message = email.message.EmailMessage()
    message["Subject"] = "[Codex %s] %s: %s" % (
        event["severity"].upper(),
        event["code"],
        event["summary"],
    )
    message["From"] = from_address
    message["To"] = ", ".join(recipients)
    message.set_content(
        "Sandbox: %s\nTime: %s\nCode: %s\nSummary: %s\n\n%s\n"
        % (
            event["sandbox"],
            event["created_at"],
            event["code"],
            event["summary"],
            event["detail"],
        )
    )
    host = channel["host"]
    port = int(channel.get("port", 465))
    security = channel.get("security", "ssl")
    timeout = float(channel.get("timeout_seconds", 20))
    context = ssl.create_default_context()
    proxy_url = smtp_proxy_url(channel)
    if security == "ssl":
        if proxy_url:
            smtp_client: smtplib.SMTP = ProxySMTPSSL(
                proxy_url,
                host,
                port,
                timeout=timeout,
                context=context,
            )
        else:
            smtp_client = smtplib.SMTP_SSL(
                host,
                port,
                timeout=timeout,
                context=context,
            )
        with smtp_client as smtp:
            smtp.login(username, password)
            smtp.send_message(message)
    else:
        if proxy_url:
            smtp_client = ProxySMTP(proxy_url, host, port, timeout=timeout)
        else:
            smtp_client = smtplib.SMTP(host, port, timeout=timeout)
        with smtp_client as smtp:
            if security == "starttls":
                smtp.starttls(context=context)
            smtp.login(username, password)
            smtp.send_message(message)


def cmd_notify_test(args: argparse.Namespace) -> None:
    bundle = bundle_path(args.bundle)
    config = load_config(bundle)
    channels = config.get("notifications", {}).get("channels", [])
    if config.get("notifications", {}).get("require_external", True) and not channels:
        fail("external notification is required but no channel is configured")
    path, delivered, errors = notification_event(
        bundle,
        config,
        "notification_test",
        "Isolated Codex notification test",
        "This verifies the host-side owner contact path before an unattended run.",
        "info",
    )
    if channels and delivered == 0:
        fail("notification test failed: %s; spool: %s" % ("; ".join(errors), path))
    if config.get("notifications", {}).get("require_external", True) and delivered == 0:
        fail("no external notification was delivered; spool: %s" % path)
    atomic_json(
        bundle / "runtime" / "notification-verification.json",
        {
            "schema_version": 1,
            "verified_at": utc_now(),
            "config_sha256": config_digest(config),
            "delivered_channels": delivered,
            "spool": str(path),
        },
    )
    print(json.dumps({"status": "passed", "delivered": delivered, "spool": str(path)}, indent=2))


def require_attestations(bundle: pathlib.Path, config: Dict[str, Any]) -> None:
    require_unattended_guards(config)
    verify = load_json(bundle / "runtime" / "verification.json")
    digest = config_digest(config)
    engine = config["runtime"]["engine"]
    if verify.get("config_sha256") != digest:
        fail("sandbox config changed after verify; run verify again")
    if verify.get("image_id") != image_id(engine, generated_image(config)):
        fail("sandbox image changed after verify; run verify again")
    if config.get("notifications", {}).get("require_external", True):
        notification = load_json(bundle / "runtime" / "notification-verification.json")
        if notification.get("config_sha256") != digest or int(
            notification.get("delivered_channels", 0)
        ) < 1:
            fail("external notification has not passed for the current config")


def clear_blocked(bundle: pathlib.Path) -> None:
    blocked = bundle / "runtime" / "control" / "blocked"
    if blocked.exists():
        shutil.rmtree(blocked)


def read_blocked(bundle: pathlib.Path) -> Optional[Dict[str, str]]:
    return read_blocked_from_control(bundle / "runtime" / "control")


def read_blocked_from_control(control: pathlib.Path) -> Optional[Dict[str, str]]:
    blocked = control / "blocked"
    if not (blocked / "ready").exists():
        return None
    result = {}
    for key in ("code", "summary", "detail", "container_time"):
        try:
            result[key] = (blocked / key).read_text(encoding="utf-8")
        except OSError:
            result[key] = ""
    return result


def stop_container(engine: str, name: str) -> None:
    subprocess.run(
        [engine, "stop", "--time", "5", name],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def codex_args(config: Dict[str, Any], mode: str) -> List[str]:
    args = ["codex"]
    if mode == "exec":
        args.append("exec")
    if config["codex"].get("bypass_inner_sandbox", True):
        args.append("--dangerously-bypass-approvals-and-sandbox")
    if config["codex"].get("search", False) and mode != "exec":
        args.append("--search")
    args += ["-C", "/workspace"]
    args += [str(item) for item in config["codex"].get("extra_args", [])]
    return args


def supervise(
    bundle: pathlib.Path,
    config: Dict[str, Any],
    command: List[str],
    *,
    interactive: bool,
    stdin_file: Optional[pathlib.Path] = None,
) -> int:
    engine = config["runtime"]["engine"]
    name = config["runtime"]["container_name"]
    if subprocess.run(
        [engine, "container", "inspect", name],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0:
        fail("container already exists; inspect or stop it first: %s" % name)
    for probe in config.get("failure_policy", {}).get("preflight", []):
        ok, detail = execute_probe(probe, config, bundle)
        if not ok:
            path, _, _ = notification_event(
                bundle,
                config,
                "dependency_unavailable",
                "Preflight failed: %s" % probe["name"],
                detail,
            )
            fail("preflight failed and owner contact was spooled at %s" % path)
    clear_blocked(bundle)
    control = bundle / "runtime" / "control"
    shutil.copyfile(ASSETS / "fail-fast.md", control / "fail-fast.md")
    docker_command = common_run_args(config, bundle, name)
    if interactive:
        if not sys.stdin.isatty() or not sys.stdout.isatty():
            fail("interactive mode requires a TTY; use --mode exec for automation")
        docker_command.append("-it")
    elif stdin_file:
        docker_command.append("-i")
    docker_command += [generated_image(config), *command]
    stdin_handle = stdin_file.open("r", encoding="utf-8") if stdin_file else None
    interrupted = False
    notified = False
    try:
        process = subprocess.Popen(docker_command, stdin=stdin_handle)
        interval = max(
            1, int(config.get("failure_policy", {}).get("poll_interval_seconds", 5))
        )
        consecutive_probe_failures: Dict[int, int] = {}
        next_probe = time.monotonic() + interval
        while process.poll() is None:
            blocked = read_blocked(bundle)
            if blocked and not notified:
                stop_container(engine, name)
                notification_event(
                    bundle,
                    config,
                    blocked.get("code") or "worker_blocked",
                    blocked.get("summary") or "Codex requested owner contact",
                    blocked.get("detail") or "",
                )
                notified = True
            if time.monotonic() >= next_probe:
                for probe_index, probe in enumerate(
                    config.get("failure_policy", {}).get("preflight", [])
                ):
                    if not probe.get("continuous", False):
                        continue
                    ok, detail = execute_probe(probe, config, bundle, name)
                    if ok:
                        consecutive_probe_failures[probe_index] = 0
                        continue
                    failure_count = (
                        consecutive_probe_failures.get(probe_index, 0) + 1
                    )
                    consecutive_probe_failures[probe_index] = failure_count
                    threshold = int(probe.get("failure_threshold", 1))
                    if failure_count >= threshold:
                        stop_container(engine, name)
                        notification_event(
                            bundle,
                            config,
                            "dependency_unavailable",
                            "Runtime dependency failed: %s" % probe["name"],
                            "%s consecutive failures; %s" % (failure_count, detail),
                        )
                        notified = True
                        break
                next_probe = time.monotonic() + interval
            time.sleep(0.25)
        return_code = int(process.returncode or 0)
    except KeyboardInterrupt:
        interrupted = True
        stop_container(engine, name)
        return_code = 130
    finally:
        if stdin_handle:
            stdin_handle.close()
    blocked = read_blocked(bundle)
    if blocked and not notified:
        notification_event(
            bundle,
            config,
            blocked.get("code") or "worker_blocked",
            blocked.get("summary") or "Codex requested owner contact",
            blocked.get("detail") or "",
        )
        notified = True
    if (
        return_code != 0
        and not interrupted
        and not notified
        and config.get("failure_policy", {}).get("notify_on_nonzero_exit", True)
    ):
        notification_event(
            bundle,
            config,
            "container_exit_nonzero",
            "Isolated Codex exited unexpectedly",
            "container=%s exit_code=%s" % (name, return_code),
        )
    if return_code == 0 and config.get("failure_policy", {}).get(
        "notify_on_success", False
    ):
        notification_event(
            bundle,
            config,
            "run_completed",
            "Isolated Codex completed",
            "container=%s" % name,
            "info",
        )
    return return_code


def prepare_task_prompt(bundle: pathlib.Path, prompt_file: str) -> pathlib.Path:
    prompt = expanded_path(prompt_file)
    if not prompt.is_file():
        fail("prompt file does not exist: %s" % prompt)
    combined = bundle / "runtime" / "control" / "current-prompt.md"
    combined.parent.mkdir(parents=True, exist_ok=True)
    combined.write_text(
        (ASSETS / "fail-fast.md").read_text(encoding="utf-8")
        + "\n\n# Task\n\n"
        + prompt.read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    return combined


def cmd_run(args: argparse.Namespace) -> None:
    bundle = bundle_path(args.bundle)
    config = load_config(bundle)
    require_attestations(bundle, config)
    mode = args.mode
    combined = prepare_task_prompt(bundle, args.prompt_file) if args.prompt_file else None
    if mode == "exec":
        if combined is None:
            fail("exec mode requires --prompt-file")
        command = codex_args(config, "exec") + ["-"]
        raise SystemExit(
            supervise(bundle, config, command, interactive=False, stdin_file=combined)
        )
    instruction = "Before working, read /codex-control/fail-fast.md and obey it for this session."
    if combined is not None:
        instruction = (
            "Before working, read /codex-control/current-prompt.md completely. "
            "Treat its Task section as this session's objective and pursue it until complete or blocked."
        )
    command = codex_args(config, "interactive") + [instruction]
    raise SystemExit(supervise(bundle, config, command, interactive=True))


def cmd_shell(args: argparse.Namespace) -> None:
    bundle = bundle_path(args.bundle)
    config = load_config(bundle)
    require_attestations(bundle, config)
    raise SystemExit(supervise(bundle, config, ["/bin/sh"], interactive=True))


def cmd_status(args: argparse.Namespace) -> None:
    bundle = bundle_path(args.bundle)
    config = load_config(bundle)
    engine = config["runtime"]["engine"]
    name = config["runtime"]["container_name"]
    result = subprocess.run(
        [engine, "container", "inspect", "--format", "{{json .State}}", name],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    state = json.loads(result.stdout) if result.returncode == 0 else None
    print(
        json.dumps(
            {
                "container": name,
                "state": state,
                "blocked": read_blocked(bundle),
                "verification": load_optional_json(
                    bundle / "runtime" / "verification.json"
                ),
                "notification_verification": load_optional_json(
                    bundle / "runtime" / "notification-verification.json"
                ),
            },
            ensure_ascii=False,
            indent=2,
        )
    )


def load_optional_json(path: pathlib.Path) -> Optional[Dict[str, Any]]:
    return load_json(path) if path.is_file() else None


def cmd_stop(args: argparse.Namespace) -> None:
    bundle = bundle_path(args.bundle)
    config = load_config(bundle)
    stop_container(config["runtime"]["engine"], config["runtime"]["container_name"])
    print("stop requested")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    doctor = subparsers.add_parser("doctor", help="inspect host and bundle capabilities")
    doctor.add_argument("--bundle")
    doctor.set_defaults(func=cmd_doctor)

    init = subparsers.add_parser("init", help="create an explicit project bundle")
    init.add_argument("--bundle", required=True)
    init.add_argument("--workspace", required=True)
    init.add_argument("--name")
    source = init.add_mutually_exclusive_group(required=True)
    source.add_argument("--base-image")
    source.add_argument("--dockerfile")
    init.add_argument("--build-context")
    init.add_argument("--platform")
    init.add_argument("--injection", choices=("layer", "preinstalled"), default="layer")
    init.add_argument("--codex-version")
    init.add_argument("--bootstrap-image", default="node:22-bookworm-slim")
    init.add_argument("--auth-file")
    init.add_argument("--codex-config")
    init.add_argument("--engine", choices=("docker",), default="docker")
    init.add_argument("--network", choices=("none", "bridge"), required=True)
    init.add_argument("--proxy-url-env")
    init.add_argument("--workspace-mode", choices=("ro", "rw"), default="rw")
    init.add_argument("--require-command", action="append")
    init.add_argument("--cpus", type=float, default=2.0)
    init.add_argument("--memory", default="4g")
    init.add_argument("--pids-limit", type=int, default=512)
    init.add_argument("--shm-size", default="1g")
    init.add_argument("--tmp-size", default="1g")
    init.add_argument("--allow-degraded", action="store_true")
    init.add_argument("--search", action="store_true")
    init.add_argument("--force", action="store_true")
    init.set_defaults(func=cmd_init)

    for name, function, help_text in (
        ("build", cmd_build, "build the selected task image plus Codex control layer"),
        ("verify", cmd_verify, "verify the exact image and isolation boundary"),
        ("notify-test", cmd_notify_test, "test host-side owner notification"),
        ("status", cmd_status, "show worker and attestation state"),
        ("stop", cmd_stop, "stop the current worker"),
        ("shell", cmd_shell, "open an interactive shell inside the verified boundary"),
    ):
        command = subparsers.add_parser(name, help=help_text)
        command.add_argument("--bundle", required=True)
        command.set_defaults(func=function)

    run = subparsers.add_parser("run", help="launch and supervise Codex")
    run.add_argument("--bundle", required=True)
    run.add_argument("--mode", choices=("interactive", "exec"), default="interactive")
    run.add_argument("--prompt-file")
    run.set_defaults(func=cmd_run)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.func(args)
        return 0
    except UserError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
