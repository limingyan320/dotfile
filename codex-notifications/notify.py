#!/usr/bin/env python3
import json
import os
import platform
import shutil
import socket
import subprocess
import sys
import urllib.error
import urllib.request
from html import escape
from pathlib import Path


HERE = Path(__file__).resolve().parent
TITLES_FILE = HERE / "titles.json"
MACOS_POPUP_SCRIPT = HERE / "popup.swift"
ICON_CANDIDATES = [
    HERE / "icon.png",
    HERE / "icon.jpg",
    HERE.parent / "claude-notifications" / "assets" / "icon.png",
    HERE.parent / "claude-notifications" / "assets" / "icon.jpg",
]
DEFAULT_TITLES = {
    "agent-turn-complete": "(๑•̀ㅂ•́)و✧ 主人,沈什已经完成任务了喵！",
    "approval-requested": "(｡•́︿•̀｡) Codex 需要你确认",
}


def load_titles():
    if not TITLES_FILE.is_file():
        return DEFAULT_TITLES
    try:
        data = json.loads(TITLES_FILE.read_text(encoding="utf-8"))
    except Exception:
        return DEFAULT_TITLES
    if not isinstance(data, dict):
        return DEFAULT_TITLES
    merged = dict(DEFAULT_TITLES)
    for key, value in data.items():
        if isinstance(key, str) and isinstance(value, str):
            merged[key] = value
    return merged


def trim(text, limit):
    text = " ".join(str(text).split())
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "…"


def build_body(payload):
    event_type = payload.get("type", "codex")
    candidates = [
        payload.get("last-assistant-message"),
        payload.get("message"),
        payload.get("reason"),
        payload.get("command"),
    ]
    body = next((trim(item, 160) for item in candidates if isinstance(item, str) and item.strip()), "")
    if not body:
        if event_type == "approval-requested":
            body = "需要你回到终端确认后继续执行。"
        elif event_type == "agent-turn-complete":
            body = "当前回合已结束。"
        else:
            body = f"事件: {event_type}"

    location_lines = []
    hostname = trim(socket.gethostname(), 48)
    if hostname:
        location_lines.append(f"机器: {hostname}")

    cwd = payload.get("cwd")
    if isinstance(cwd, str) and cwd.strip():
        location_lines.append(f"路径: {trim(cwd, 140)}")

    if location_lines:
        body = f"{body}\n" + "\n".join(location_lines)
    return body


def dump_debug_payload(payload):
    debug_path = os.environ.get("CODEX_NOTIFY_DEBUG_LOG")
    if not debug_path:
        return
    try:
        Path(debug_path).write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    except OSError:
        pass


def find_icon():
    for path in ICON_CANDIDATES:
        if path.is_file():
            return path
    return None


def forward_to_local_listener(payload):
    if os.environ.get("CODEX_NOTIFY_SKIP_FORWARD") == "1":
        return False
    if not os.environ.get("SSH_CONNECTION"):
        return False

    port = os.environ.get("CODEX_NOTIFY_LISTEN_PORT", "47789")
    url = os.environ.get("CODEX_NOTIFY_FORWARD_URL", f"http://127.0.0.1:{port}/notify")
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=0.4) as resp:
            return 200 <= resp.status < 300
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


def notify_macos_popup(title, body, icon_path):
    if not MACOS_POPUP_SCRIPT.is_file():
        return False
    cmd = ["swift", str(MACOS_POPUP_SCRIPT), title, body]
    if icon_path:
        cmd.append(str(icon_path))
    try:
        subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        return False
    return True


def notify_linux(title, body):
    cmd = shutil.which("notify-send")
    if not cmd:
        return False
    result = subprocess.run([cmd, "-a", "Codex", title, body], check=False)
    return result.returncode == 0


def notify_macos(title, body):
    icon_path = find_icon()
    if notify_macos_popup(title, body, icon_path):
        return True

    cmd = shutil.which("osascript")
    if not cmd:
        return False
    # Pass title/body via argv so AppleScript does not need to parse escaped
    # Unicode content from the inline script source.
    result = subprocess.run(
        [
            cmd,
            "-e",
            "on run argv",
            "-e",
            "display notification (item 2 of argv) with title (item 1 of argv)",
            "-e",
            "end run",
            title,
            body,
        ],
        check=False,
    )
    return result.returncode == 0


def notify_windows(title, body):
    cmd = shutil.which("powershell.exe") or shutil.which("pwsh.exe")
    if not cmd:
        return False

    toast_xml = (
        "<toast>"
        "<visual><binding template=\"ToastGeneric\">"
        f"<text>{escape(title)}</text>"
        f"<text>{escape(body)}</text>"
        "</binding></visual>"
        "</toast>"
    )
    ps = f"""
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] > $null
$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml({json.dumps(toast_xml)})
$toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
$notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Codex")
$notifier.Show($toast)
""".strip()
    result = subprocess.run([cmd, "-NoProfile", "-Command", ps], check=False)
    return result.returncode == 0


def is_wsl():
    if os.environ.get("WSL_DISTRO_NAME"):
        return True
    release = platform.release().lower()
    version = platform.version().lower()
    return "microsoft" in release or "microsoft" in version


def main():
    if len(sys.argv) < 2:
        return 0

    try:
        payload = json.loads(sys.argv[1])
    except json.JSONDecodeError:
        return 0
    if not isinstance(payload, dict):
        return 0

    dump_debug_payload(payload)

    if forward_to_local_listener(payload):
        return 0

    titles = load_titles()
    event_type = str(payload.get("type", "codex"))
    title = titles.get(event_type, f"Codex: {event_type}")
    body = build_body(payload)

    ok = False
    system = platform.system()
    if is_wsl():
        ok = notify_windows(title, body) or notify_linux(title, body)
    elif system == "Darwin":
        ok = notify_macos(title, body)
    elif system == "Windows":
        ok = notify_windows(title, body)
    else:
        ok = notify_linux(title, body)

    if not ok:
        print(f"[Codex] {title}: {body}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
