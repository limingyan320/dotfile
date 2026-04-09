#!/usr/bin/env bash
# ============================================
# claude-notifications/apply.sh
# 把 assets/ 下的音频 / icon.png 和 titles.json 合并进
# ~/.claude/claude-notifications-go/config.json
# ============================================
#
# 用法:
#   1. 往 assets/ 里放音频（文件名必须是 status key，例如 task_complete.mp3）
#      支持: mp3 / wav / aiff / ogg / flac
#   2. 可选: 放一张 icon.png 当通知图标
#   3. 可选: 编辑 titles.json 改每个状态的标题
#   4. bash apply.sh
#
# 设计原则 (宽容 > 严格):
#   - 任何单项不合法只跳过那一项，其他照常处理
#   - config.json 不存在/语法错 → 打印原因，return 0（不影响调用方）
#   - 最终只会在【原始 JSON 有效】的前提下原子写回
#
# 生成的路径是本机绝对路径，所以 config.json 本身不进 git。

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$HERE/assets"
TITLES_FILE="$HERE/titles.json"
CONFIG_PATH="$HOME/.claude/claude-notifications-go/config.json"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
skip()  { echo -e "${YELLOW}[SKIP]${NC} $1"; }
err()   { echo -e "${RED}[ERR]${NC} $1"; }
head()  { echo -e "${CYAN}==${NC} $1"; }

head "claude-notifications apply"
echo "  source: $HERE"
echo "  target: $CONFIG_PATH"
echo ""

# ---- 前置检查 --------------------------------------------------------------

if ! command -v python3 &>/dev/null; then
    err "需要 python3 (macOS/Linux 通常自带)，跳过"
    exit 0
fi

if [ ! -f "$CONFIG_PATH" ]; then
    skip "config.json 不存在 —— 请先装好 claude-notifications-go 插件"
    skip "  首次使用流程：在 Claude Code 里跑 /claude-notifications-go:settings，然后重新执行本脚本"
    exit 0
fi

# ---- 执行合并 --------------------------------------------------------------
# 把所有校验、合并、写回逻辑交给 python 处理。python 会用 exit code 区分:
#   0 = 正常完成（哪怕有 skip）
#   2 = config.json 本身有问题，不做任何改动
#   其他 = 未预期异常

python3 - "$CONFIG_PATH" "$ASSETS_DIR" "$TITLES_FILE" <<'PY'
import json
import os
import sys

GREEN = "\033[0;32m"
YELLOW = "\033[0;33m"
RED = "\033[0;31m"
NC = "\033[0m"


def ok(msg):   print(f"{GREEN}[OK]{NC}   {msg}")
def skip(msg): print(f"{YELLOW}[SKIP]{NC} {msg}")
def err(msg):  print(f"{RED}[ERR]{NC}  {msg}")


config_path, assets_dir, titles_file = sys.argv[1], sys.argv[2], sys.argv[3]

# --- 校验 config.json ---
try:
    with open(config_path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
except json.JSONDecodeError as e:
    err(f"config.json 不是合法 JSON: 第 {e.lineno} 行第 {e.colno} 列 — {e.msg}")
    err("不做任何修改以免破坏现有配置")
    sys.exit(2)
except OSError as e:
    err(f"无法读取 config.json: {e}")
    sys.exit(2)

if not isinstance(cfg, dict):
    err("config.json 根节点不是 object，不做修改")
    sys.exit(2)

statuses = cfg.get("statuses")
if not isinstance(statuses, dict) or not statuses:
    err("config.json 缺少 statuses 或不是 object，不做修改")
    sys.exit(2)

known_keys = set(statuses.keys())
changes = []

# --- 1. assets/ 下的音频文件 → sound ---
AUDIO_EXTS = (".mp3", ".wav", ".aiff", ".ogg", ".flac")
if os.path.isdir(assets_dir):
    for fname in sorted(os.listdir(assets_dir)):
        if fname.startswith("."):
            continue
        path = os.path.join(assets_dir, fname)
        if not os.path.isfile(path):
            continue

        lower = fname.lower()
        # 处理音频
        if lower.endswith(AUDIO_EXTS):
            key = os.path.splitext(fname)[0]
            if key not in known_keys:
                skip(f"assets/{fname}: status '{key}' 不在 config.statuses 里")
                continue
            if not os.access(path, os.R_OK):
                skip(f"assets/{fname}: 文件不可读（权限问题）")
                continue
            if os.path.getsize(path) == 0:
                skip(f"assets/{fname}: 文件为空")
                continue
            statuses[key]["sound"] = path
            changes.append(f"sound   [{key}] ← {fname}")
            continue

        # 处理 icon.png （下面单独处理，这里排除它不报警）
        if fname == "icon.png":
            continue

        # 其他未知文件
        skip(f"assets/{fname}: 不是支持的音频格式（{'/'.join(AUDIO_EXTS)}）也不是 icon.png")

else:
    skip(f"assets/ 目录不存在")

# --- 2. icon.png → appIcon ---
icon_path = os.path.join(assets_dir, "icon.png")
if os.path.isfile(icon_path):
    if not os.access(icon_path, os.R_OK):
        skip("assets/icon.png: 不可读（权限问题）")
    else:
        try:
            with open(icon_path, "rb") as f:
                magic = f.read(8)
            if magic[:8] != b"\x89PNG\r\n\x1a\n":
                skip("assets/icon.png: 不是合法的 PNG（魔数不匹配）")
            else:
                notif = cfg.setdefault("notifications", {})
                desktop = notif.setdefault("desktop", {})
                if not isinstance(desktop, dict):
                    skip("config.notifications.desktop 不是 object，icon 跳过")
                else:
                    desktop["appIcon"] = icon_path
                    changes.append("appIcon ← icon.png")
        except OSError as e:
            skip(f"assets/icon.png: 读取失败 — {e}")

# --- 3. titles.json → title ---
if os.path.isfile(titles_file):
    try:
        with open(titles_file, "r", encoding="utf-8") as f:
            titles = json.load(f)
    except json.JSONDecodeError as e:
        err(f"titles.json 语法错: 第 {e.lineno} 行第 {e.colno} 列 — {e.msg}")
        err("跳过 titles 部分，其他继续")
        titles = None
    except OSError as e:
        err(f"titles.json 读取失败: {e}")
        titles = None

    if isinstance(titles, dict):
        for key, title in titles.items():
            if not isinstance(title, str):
                skip(f"titles.json: '{key}' 的值不是字符串，跳过")
                continue
            if key not in known_keys:
                skip(f"titles.json: status '{key}' 不在 config.statuses 里")
                continue
            statuses[key]["title"] = title
            changes.append(f"title   [{key}] ← {title}")
    elif titles is not None:
        err("titles.json 根节点不是 object，跳过")

# --- 4. 原子写回 ---
if not changes:
    skip("没有任何可应用的变更（assets/ 空、titles.json 无命中）")
    sys.exit(0)

tmp_path = config_path + ".tmp"
try:
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    os.replace(tmp_path, config_path)
except OSError as e:
    err(f"写回 config.json 失败: {e}")
    try:
        os.remove(tmp_path)
    except OSError:
        pass
    sys.exit(2)

print("")
ok(f"已应用 {len(changes)} 项变更:")
for c in changes:
    print(f"     - {c}")
PY

rc=$?
echo ""
if [ $rc -eq 0 ]; then
    ok "完成"
elif [ $rc -eq 2 ]; then
    err "config.json 有问题，未做任何修改"
else
    err "异常退出 (code=$rc)"
fi
exit $rc
