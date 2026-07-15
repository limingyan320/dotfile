#!/usr/bin/env bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/com.lumynous.codex-notify-listener.plist"
PORT="${CODEX_NOTIFY_LISTEN_PORT:-47789}"
PYTHON_BIN="$(command -v python3)"

if [ -z "$PYTHON_BIN" ]; then
    echo "[SKIP] python3 未找到，跳过 Codex listener 安装"
    exit 0
fi

mkdir -p "$PLIST_DIR"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.lumynous.codex-notify-listener</string>
  <key>ProgramArguments</key>
  <array>
    <string>${PYTHON_BIN}</string>
    <string>${HERE}/listener.py</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CODEX_NOTIFY_LISTEN_HOST</key>
    <string>127.0.0.1</string>
    <key>CODEX_NOTIFY_LISTEN_PORT</key>
    <string>${PORT}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
PLIST

launchctl unload "$PLIST_PATH" >/dev/null 2>&1 || true
pkill -f "$HERE/popup.swift" >/dev/null 2>&1 || true
launchctl load "$PLIST_PATH" >/dev/null 2>&1 || true

echo "[OK] Codex 本地通知接收器已安装: $PLIST_PATH"
