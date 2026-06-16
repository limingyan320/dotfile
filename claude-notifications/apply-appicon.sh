#!/usr/bin/env bash
# ============================================
# claude-notifications/apply-appicon.sh   (macOS only)
# 把 assets/icon.png 做成 .icns，替换通知器 app bundle 的图标
# —— 也就是通知左侧那个小 app 图标（默认是橙色 Anthropic burst）。
# 然后 ad-hoc 重新签名 + 清通知图标缓存。
#
# 为什么需要单独一个脚本（而不是塞进 apply.sh）：
#   - 左侧图标不是 config.json 里的 appIcon，而是 ClaudeNotifier.app /
#     ClaudeNotifications.app 这两个 app bundle 的 AppIcon.icns。
#   - 这俩 bundle 由 claude-notifications-go 插件在每次安装/更新时重建，
#     所以本脚本要在【每次插件更新后】重跑一遍。
#   - ClaudeNotifier.app 带 Developer ID + hardened runtime 签名，
#     换图标会破坏签名，必须 ad-hoc 重新签，否则 macOS 拒绝启动。
#
# 用法:  bash claude-notifications/apply-appicon.sh
# ============================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_PNG="$HERE/assets/icon.png"

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}   $1"; }
skip() { echo -e "${YELLOW}[SKIP]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC}  $1"; }
head() { echo -e "${CYAN}==${NC} $1"; }

head "claude-notifications apply-appicon (左侧 app 图标)"

# ---- 平台 / 依赖检查 -------------------------------------------------------
if [ "$(uname)" != "Darwin" ]; then
    skip "非 macOS，左侧 app 图标机制不适用，跳过"
    exit 0
fi
for tool in sips iconutil codesign; do
    if ! command -v "$tool" &>/dev/null; then
        err "缺少 $tool（macOS 自带），无法继续"
        exit 0
    fi
done
if [ ! -f "$SRC_PNG" ]; then
    skip "assets/icon.png 不存在 —— 先放一张 PNG 再跑（apply.sh 同款）"
    exit 0
fi

# ---- 定位插件 root ---------------------------------------------------------
PLUGIN_ROOT=""
ROOT_PTR="$HOME/.claude/claude-notifications-go/plugin-root"
if [ -f "$ROOT_PTR" ]; then
    PLUGIN_ROOT="$(cat "$ROOT_PTR" 2>/dev/null)"
fi
if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT/bin" ]; then
    # 退路：取版本目录里最新的一个
    PLUGIN_ROOT="$(ls -d "$HOME"/.claude/plugins/cache/claude-notifications-go/claude-notifications-go/*/ 2>/dev/null | sort -V | tail -1)"
fi
if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT/bin" ]; then
    skip "找不到 claude-notifications-go 插件 bin/ 目录 —— 先装好插件"
    exit 0
fi
echo "  plugin: $PLUGIN_ROOT"
echo "  source: $SRC_PNG"
echo ""

# ---- 1. 从 icon.png 生成 AppIcon.icns -------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ICONSET="$TMP_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"

# 先压成 1024 方形 master（776x758 → 方形，肉眼无差）
MASTER="$TMP_DIR/master.png"
if ! sips -s format png -z 1024 1024 "$SRC_PNG" --out "$MASTER" >/dev/null 2>&1; then
    err "sips 生成方形 master 失败"
    exit 1
fi

# 各尺寸
declare -a SIZES=(16 32 64 128 256 512 1024)
for s in "${SIZES[@]}"; do
    sips -z "$s" "$s" "$MASTER" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
done
# Retina @2x 命名（指向同尺寸像素）
cp "$ICONSET/icon_32x32.png"     "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png"     "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png"   "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png"   "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
# iconutil 只认这些规范名，删掉非标准的 64/1024 1x
rm -f "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"

ICNS="$TMP_DIR/AppIcon.icns"
if ! iconutil -c icns "$ICONSET" -o "$ICNS" 2>/dev/null; then
    err "iconutil 打包 .icns 失败"
    exit 1
fi
ok "已生成 AppIcon.icns"

# ---- 2. 替换两个 bundle 的图标 + ad-hoc 重新签名 ---------------------------
applied=0
for APP in "$PLUGIN_ROOT/bin/ClaudeNotifier.app" "$PLUGIN_ROOT/bin/ClaudeNotifications.app"; do
    [ -d "$APP" ] || { skip "$(basename "$APP") 不存在，跳过"; continue; }
    RES="$APP/Contents/Resources"
    [ -d "$RES" ] || { skip "$(basename "$APP") 没有 Resources/，跳过"; continue; }

    cp "$ICNS" "$RES/AppIcon.icns" || { err "$(basename "$APP") 写入图标失败"; continue; }

    # 换了资源就破坏了原签名，ad-hoc 重新签（保留 bundle id，通知按 bundle id 走）
    if codesign --force --sign - "$APP" >/dev/null 2>&1; then
        ok "$(basename "$APP")：图标已换 + ad-hoc 重新签名"
    else
        skip "$(basename "$APP")：图标已换，但重新签名失败（可能仍能用）"
    fi
    applied=$((applied+1))
done

if [ "$applied" -eq 0 ]; then
    err "没有任何 bundle 被处理"
    exit 1
fi

# ---- 3. 清缓存 / 重注册，逼 macOS 刷新图标 ---------------------------------
# 通知左侧图标 = ClaudeNotifier.app 的 bundle 图标，macOS 用 iconservices 缓存
# 得很死，光 killall 守护进程往往不够，要连用户级 iconservices 缓存一起清。
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [ -x "$LSREG" ]; then
    "$LSREG" -f "$PLUGIN_ROOT/bin/ClaudeNotifier.app"     >/dev/null 2>&1
    "$LSREG" -f "$PLUGIN_ROOT/bin/ClaudeNotifications.app" >/dev/null 2>&1
fi
# 用户级 iconservices 缓存（无需 sudo）
USER_CACHE="$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null)"
if [ -n "$USER_CACHE" ] && [ -d "${USER_CACHE}com.apple.iconservices" ]; then
    rm -rf "${USER_CACHE}com.apple.iconservices" 2>/dev/null
fi
rm -rf "$HOME/Library/Caches/com.apple.iconservices"* 2>/dev/null
# 重启相关守护进程 / UI
killall usernoted Dock ControlCenter NotificationCenter >/dev/null 2>&1

echo ""
ok "完成。下一条通知就会用新图标。"
echo -e "${YELLOW}提示：${NC}macOS 对通知图标缓存很顽固。如果还是旧图标，注销/重登（或重启）一次即可。"
echo -e "${YELLOW}提示：${NC}插件每次更新都会重建 app bundle —— 更新后重跑本脚本。"
