#!/usr/bin/env python3
import argparse
import contextlib
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

try:
    import fcntl
except ImportError:  # pragma: no cover - native Windows fallback
    fcntl = None


STATE_VERSION = 1
READY = "ready"
WORKING = "working"
IDLE = "idle"


def _debug(message):
    path = os.environ.get("CODEX_AGENT_STATE_DEBUG_LOG")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(f"{time.time():.3f} {message}\n")
    except OSError:
        pass


def normalize_server(server):
    value = os.path.expanduser(str(server or "").strip())
    return os.path.abspath(value) if value else ""


def session_dir():
    configured = os.environ.get("DOTFILES_NVIM_SESSION_DIR")
    if configured:
        return Path(configured).expanduser()
    state_home = os.environ.get("XDG_STATE_HOME")
    if state_home:
        return Path(state_home).expanduser() / "nvim" / "sessions"
    return Path.home() / ".local" / "state" / "nvim" / "sessions"


def status_dir():
    return session_dir() / "agent-status"


def state_path(server):
    server = normalize_server(server)
    digest = hashlib.sha256(server.encode("utf-8")).hexdigest()
    return status_dir() / f"{digest}.json"


def _read_json(path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return {}
    return data if isinstance(data, dict) else {}


def read_state(server):
    server = normalize_server(server)
    if not server:
        return {}
    data = _read_json(state_path(server))
    if data.get("nvim_server") != server:
        return {}
    return data


def _write_state(path, state):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        path.parent.chmod(0o700)
    except OSError:
        pass
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(
            json.dumps(state, ensure_ascii=False, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        temporary.chmod(0o600)
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except OSError:
            pass


@contextlib.contextmanager
def _state_lock(server):
    directory = status_dir()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_path = state_path(server).with_suffix(".lock")
    with open(lock_path, "a+", encoding="utf-8") as handle:
        if fcntl is not None:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            if fcntl is not None:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _event_fields(payload):
    session_id = payload.get("session_id") or payload.get("thread-id") or ""
    turn_id = payload.get("turn_id") or payload.get("turn-id") or ""
    cwd = payload.get("cwd") or os.getcwd()
    return str(session_id), str(turn_id), str(cwd)


def _notification_id(server, session_id, turn_id):
    identity = "\0".join(
        [socket.gethostname(), normalize_server(server), session_id, turn_id]
    )
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()[:32]


def _query_nvim(server, expression):
    nvim = os.environ.get("NVIM_BIN") or shutil.which("nvim")
    if not nvim or not server:
        return ""
    try:
        result = subprocess.run(
            [nvim, "--server", server, "--remote-expr", expression],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=0.7,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def _nvim_observes_codex(server):
    value = _query_nvim(
        server,
        "luaeval('_G.dotfiles_codex_is_observed and "
        "_G.dotfiles_codex_is_observed() or false')",
    ).lower()
    return value in {"1", "true", "v:true"}


def _session_label(server, cwd):
    value = _query_nvim(server, 'get(g:, "dotfiles_session_name", "")')
    value = " ".join(value.split())
    if value:
        return value[:80]
    path = Path(cwd).expanduser()
    label = path.name or str(path)
    return label[:80]


def _listener_url(path):
    explicit = os.environ.get("CODEX_NOTIFY_LISTENER_URL")
    if explicit:
        return explicit.rstrip("/") + path

    forward = os.environ.get("CODEX_NOTIFY_FORWARD_URL")
    if forward:
        parsed = urllib.parse.urlsplit(forward)
        return urllib.parse.urlunsplit(
            (parsed.scheme, parsed.netloc, path, "", "")
        )

    port = os.environ.get("CODEX_NOTIFY_LISTEN_PORT", "47789")
    return f"http://127.0.0.1:{port}{path}"


def _post_listener(path, payload):
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        _listener_url(path),
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=0.5) as response:
            return 200 <= response.status < 300
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


def _dismiss(notification_id):
    if not notification_id:
        return False
    return _post_listener("/dismiss", {"notification-id": notification_id})


def record_working(payload, server=None):
    server = normalize_server(server or os.environ.get("NVIM"))
    if not server:
        return {}
    session_id, turn_id, cwd = _event_fields(payload)
    previous_notification = ""
    with _state_lock(server):
        current = read_state(server)
        if current.get("state") == READY and current.get("unread"):
            previous_notification = str(current.get("notification_id") or "")
        state = {
            "version": STATE_VERSION,
            "nvim_server": server,
            "state": WORKING,
            "unread": False,
            "session_id": session_id,
            "turn_id": turn_id,
            "notification_id": _notification_id(server, session_id, turn_id),
            "session_label": _session_label(server, cwd),
            "cwd": cwd,
            "notified": False,
            "updated_at": time.time(),
        }
        if current.get("seen_turn_id"):
            state["seen_turn_id"] = current["seen_turn_id"]
        _write_state(state_path(server), state)
    if previous_notification:
        _dismiss(previous_notification)
    return state


def record_completion(payload, mark_notified=False, server=None, observed=None):
    server = normalize_server(server or os.environ.get("NVIM"))
    if not server:
        return {"should_notify": mark_notified, "state": {}}

    session_id, turn_id, cwd = _event_fields(payload)
    notification_id = _notification_id(server, session_id, turn_id)
    label = _session_label(server, cwd)
    if observed is None:
        observed = _nvim_observes_codex(server)

    should_notify = False
    dismiss_id = ""
    stale = False
    with _state_lock(server):
        current = read_state(server)
        current_turn = str(current.get("turn_id") or "")
        seen_turn = str(current.get("seen_turn_id") or "")

        if (
            current.get("state") == WORKING
            and current_turn
            and turn_id
            and current_turn != turn_id
        ):
            stale = True
            state = current
        elif turn_id and seen_turn == turn_id:
            state = current
        elif (
            current.get("state") == IDLE
            and turn_id
            and current_turn == turn_id
        ):
            state = current
        elif observed:
            dismiss_id = str(current.get("notification_id") or "")
            state = {
                "version": STATE_VERSION,
                "nvim_server": server,
                "state": IDLE,
                "unread": False,
                "session_id": session_id,
                "turn_id": turn_id,
                "seen_turn_id": turn_id,
                "notification_id": notification_id,
                "session_label": label,
                "cwd": cwd,
                "notified": False,
                "updated_at": time.time(),
            }
            _write_state(state_path(server), state)
        elif current.get("state") == READY and current_turn == turn_id:
            state = current
            if mark_notified and not current.get("notified"):
                state["notified"] = True
                state["updated_at"] = time.time()
                should_notify = True
                _write_state(state_path(server), state)
        else:
            state = {
                "version": STATE_VERSION,
                "nvim_server": server,
                "state": READY,
                "unread": True,
                "session_id": session_id,
                "turn_id": turn_id,
                "notification_id": notification_id,
                "session_label": label,
                "cwd": cwd,
                "notified": bool(mark_notified),
                "updated_at": time.time(),
            }
            if current.get("seen_turn_id"):
                state["seen_turn_id"] = current["seen_turn_id"]
            should_notify = bool(mark_notified)
            _write_state(state_path(server), state)

    if dismiss_id:
        _dismiss(dismiss_id)
    return {
        "should_notify": should_notify and not stale,
        "state": state,
        "stale": stale,
    }


def prepare_notification(payload):
    enriched = dict(payload)
    if enriched.get("type") != "agent-turn-complete":
        return enriched

    server = normalize_server(os.environ.get("NVIM"))
    session_id, turn_id, cwd = _event_fields(enriched)
    if not server:
        enriched["notification-id"] = _notification_id("", session_id, turn_id)
        enriched.setdefault("nvim-session", _session_label("", cwd))
        return enriched

    result = record_completion(enriched, mark_notified=True, server=server)
    if not result.get("should_notify"):
        return None
    state = result["state"]
    enriched["notification-id"] = state["notification_id"]
    enriched["nvim-server"] = server
    enriched["nvim-session"] = state.get("session_label") or _session_label(server, cwd)
    return enriched


def acknowledge(server=None):
    server = normalize_server(server or os.environ.get("NVIM"))
    if not server:
        return {}
    notification_id = ""
    with _state_lock(server):
        state = read_state(server)
        if state.get("state") != READY or not state.get("unread"):
            return state
        notification_id = str(state.get("notification_id") or "")
        state["state"] = IDLE
        state["unread"] = False
        state["seen_turn_id"] = str(state.get("turn_id") or "")
        state["updated_at"] = time.time()
        _write_state(state_path(server), state)
    _dismiss(notification_id)
    return state


def mark_idle_if_working(server=None, turn_id="", reason="terminal-idle"):
    server = normalize_server(server or os.environ.get("NVIM"))
    turn_id = str(turn_id or "")
    if not server or not turn_id:
        return {}

    with _state_lock(server):
        state = read_state(server)
        if (
            state.get("state") != WORKING
            or str(state.get("turn_id") or "") != turn_id
        ):
            return state
        state["state"] = IDLE
        state["unread"] = False
        state["ended_reason"] = str(reason or "terminal-idle")
        state["updated_at"] = time.time()
        _write_state(state_path(server), state)
    return state


def clear(server=None):
    server = normalize_server(server or os.environ.get("NVIM"))
    if not server:
        return False
    notification_id = ""
    with _state_lock(server):
        state = read_state(server)
        notification_id = str(state.get("notification_id") or "")
        try:
            state_path(server).unlink()
        except FileNotFoundError:
            pass
    _dismiss(notification_id)
    return True


def handle_hook(payload):
    event = payload.get("hook_event_name")
    if event == "UserPromptSubmit":
        return record_working(payload)
    if event == "Stop":
        return record_completion(payload, mark_notified=False).get("state", {})
    return {}


def _load_stdin_json():
    try:
        data = json.load(sys.stdin)
    except (ValueError, OSError):
        return {}
    return data if isinstance(data, dict) else {}


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("hook")
    for name in ("ack", "clear", "inspect"):
        command = subparsers.add_parser(name)
        command.add_argument("--server", default=os.environ.get("NVIM", ""))
    idle = subparsers.add_parser("idle")
    idle.add_argument("--server", default=os.environ.get("NVIM", ""))
    idle.add_argument("--turn-id", required=True)
    idle.add_argument("--reason", default="terminal-idle")
    args = parser.parse_args()

    try:
        if args.command == "hook":
            handle_hook(_load_stdin_json())
        elif args.command == "ack":
            acknowledge(args.server)
        elif args.command == "idle":
            mark_idle_if_working(args.server, args.turn_id, args.reason)
        elif args.command == "clear":
            clear(args.server)
        elif args.command == "inspect":
            print(json.dumps(read_state(args.server), ensure_ascii=False, indent=2))
    except Exception as error:  # Hooks must never block the Codex turn.
        _debug(f"{args.command}: {error!r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
