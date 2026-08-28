#!/usr/bin/env bash
# Link the iTerm2 helper that applies Nvim background settings to the active session.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
ok()   { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$1"; }

[ "$(uname -s)" = "Darwin" ] || { warn "非 macOS，跳过 iTerm2 Nvim background helper"; exit 0; }

AUTOLAUNCH="$HOME/Library/Application Support/iTerm2/Scripts/AutoLaunch"
mkdir -p "$AUTOLAUNCH"
ln -snf "$HERE/iterm_background_daemon.py" "$AUTOLAUNCH/dotfiles_nvim_background.py"
ok "background helper 已链接 → $AUTOLAUNCH/dotfiles_nvim_background.py"

cat <<'EOF'
  首次安装后在 iTerm2 菜单运行一次：
  Scripts → AutoLaunch → dotfiles_nvim_background.py
  Python API 已为 iclip 启用时不需要修改其他设置。
  helper 仅在 iTerm2 位于前台时响应；SSH bridge 默认使用 127.0.0.1:47790。
EOF
