#!/usr/bin/env bash
# ============================================
# codex-notifications/apply.sh
# 把仓库内的 Codex 原生 notify 配置合并进
# ~/.codex/config.toml
# ============================================
#
# 用法:
#   bash codex-notifications/apply.sh
#
# 设计原则:
#   - 使用 Codex 原生 notify 机制，不依赖第三方插件
#   - 只管理 notify / tui.notifications 相关项
#   - 其余 ~/.codex/config.toml 配置尽量保留

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY_SCRIPT="$HERE/notify.py"
TITLES_FILE="$HERE/titles.json"
CONFIG_DIR="$HOME/.codex"
CONFIG_PATH="$CONFIG_DIR/config.toml"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
skip()  { echo -e "${YELLOW}[SKIP]${NC} $1"; }
err()   { echo -e "${RED}[ERR]${NC} $1"; }
head()  { echo -e "${CYAN}==${NC} $1"; }

find_toml_python() {
    local candidate
    for candidate in \
        python3 \
        python3.14 \
        python3.13 \
        python3.12 \
        python3.11 \
        python \
        /opt/homebrew/bin/python3 \
        /usr/local/bin/python3
    do
        if [ -x "$candidate" ]; then
            :
        else
            command -v "$candidate" >/dev/null 2>&1 || continue
        fi
        if "$candidate" - <<'PY' >/dev/null 2>&1
import tomllib
PY
        then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

head "codex-notifications apply"
echo "  source: $HERE"
echo "  target: $CONFIG_PATH"
echo ""

if ! command -v python3 &>/dev/null; then
    err "需要 python3，跳过"
    exit 0
fi

if [ ! -f "$NOTIFY_SCRIPT" ]; then
    err "notify.py 不存在，跳过"
    exit 0
fi

TOML_PYTHON="$(find_toml_python)"
if [ -z "$TOML_PYTHON" ]; then
    err "需要一个支持 tomllib 的 Python（>= 3.11）来更新 config.toml，跳过"
    exit 0
fi

if [ ! -f "$TITLES_FILE" ]; then
    skip "titles.json 不存在，将由 notify.py 使用内置标题"
fi

mkdir -p "$CONFIG_DIR"

"$TOML_PYTHON" - "$CONFIG_PATH" "$NOTIFY_SCRIPT" <<'PY'
import copy
import json
import math
import os
import re
import sys
import tomllib

GREEN = "\033[0;32m"
YELLOW = "\033[0;33m"
RED = "\033[0;31m"
NC = "\033[0m"


def ok(msg):
    print(f"{GREEN}[OK]{NC}   {msg}")


def skip(msg):
    print(f"{YELLOW}[SKIP]{NC} {msg}")


def err(msg):
    print(f"{RED}[ERR]{NC}  {msg}")


config_path, notify_script = sys.argv[1], sys.argv[2]
desired_notify = ["python3", notify_script]
desired_events = ["agent-turn-complete", "approval-requested"]


def load_config(path):
    if not os.path.exists(path):
        return {}
    try:
        raw = open(path, "rb").read()
    except OSError as e:
        err(f"无法读取 config.toml: {e}")
        sys.exit(2)
    if not raw.strip():
        return {}
    try:
        cfg = tomllib.loads(raw.decode("utf-8"))
    except UnicodeDecodeError as e:
        err(f"config.toml 不是合法 UTF-8: {e}")
        sys.exit(2)
    except tomllib.TOMLDecodeError as e:
        err(f"config.toml 不是合法 TOML: {e}")
        err("不做任何修改以免破坏现有配置")
        sys.exit(2)
    if not isinstance(cfg, dict):
        err("config.toml 根节点不是 table，不做修改")
        sys.exit(2)
    return cfg


bare_key_re = re.compile(r"^[A-Za-z0-9_-]+$")


def format_key(key):
    if bare_key_re.match(key):
        return key
    return json.dumps(key, ensure_ascii=False)


def format_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if not math.isfinite(value):
            raise TypeError("TOML 不支持 NaN/Infinity")
        return repr(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[" + ", ".join(format_value(v) for v in value) + "]"
    raise TypeError(f"暂不支持写回类型: {type(value).__name__}")


def dump_table(lines, path, table):
    scalars = []
    subtables = []
    for key, value in table.items():
        if isinstance(value, dict):
            subtables.append((key, value))
        else:
            scalars.append((key, value))

    if path and (scalars or not subtables):
        lines.append("[" + ".".join(format_key(part) for part in path) + "]")

    for key, value in scalars:
        lines.append(f"{format_key(key)} = {format_value(value)}")

    if scalars and subtables:
        lines.append("")

    for idx, (key, value) in enumerate(subtables):
        dump_table(lines, path + [key], value)
        if idx != len(subtables) - 1:
            lines.append("")


def dump_toml(data):
    lines = []
    scalars = []
    subtables = []
    for key, value in data.items():
        if isinstance(value, dict):
            subtables.append((key, value))
        else:
            scalars.append((key, value))

    for key, value in scalars:
        lines.append(f"{format_key(key)} = {format_value(value)}")

    if scalars and subtables:
        lines.append("")

    for idx, (key, value) in enumerate(subtables):
        dump_table(lines, [key], value)
        if idx != len(subtables) - 1:
            lines.append("")

    return "\n".join(lines).rstrip() + "\n"


cfg = load_config(config_path)
before = copy.deepcopy(cfg)
changes = []

cfg["notify"] = desired_notify
if before.get("notify") != desired_notify:
    changes.append(f"notify ← {desired_notify}")

tui = cfg.get("tui")
if tui is None:
    tui = {}
    cfg["tui"] = tui
elif not isinstance(tui, dict):
    err("config.toml 里的 tui 不是 table，不做修改")
    sys.exit(2)

tui_before = before.get("tui")
tui_before_notifications = tui_before.get("notifications") if isinstance(tui_before, dict) else None
tui["notifications"] = desired_events
if tui_before_notifications != desired_events:
    changes.append(f"tui.notifications ← {desired_events}")

if not changes:
    skip("Codex 通知配置已是最新，无需修改")
    sys.exit(0)

try:
    rendered = dump_toml(cfg)
except TypeError as e:
    err(f"当前 config.toml 含有暂不支持的复杂类型，未写回: {e}")
    sys.exit(2)

tmp_path = config_path + ".tmp"
try:
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write(rendered)
    os.replace(tmp_path, config_path)
except OSError as e:
    err(f"写回 config.toml 失败: {e}")
    try:
        os.remove(tmp_path)
    except OSError:
        pass
    sys.exit(2)

print("")
ok(f"已应用 {len(changes)} 项变更:")
for item in changes:
    print(f"     - {item}")
PY

rc=$?
echo ""
if [ $rc -eq 0 ]; then
    ok "完成"
elif [ $rc -eq 2 ]; then
    err "config.toml 有问题，未做任何修改"
else
    err "异常退出 (code=$rc)"
fi
exit $rc
