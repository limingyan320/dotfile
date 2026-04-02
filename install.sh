#!/usr/bin/env bash
# ============================================
# install.sh — 一键安装 dotfiles（创建符号链接）
# 用法: bash ~/.dotfiles/install.sh
# ============================================

set -e

DOTFILES="$HOME/.dotfiles"

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[SKIP]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 创建符号链接，已存在则备份
link_file() {
    local src="$1"
    local dst="$2"

    if [ ! -e "$src" ]; then
        error "$src 不存在，跳过"
        return
    fi

    # 如果目标已经是正确的符号链接，跳过
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
        warn "$dst 已链接，跳过"
        return
    fi

    # 如果目标存在（文件或旧链接），备份
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        local backup="${dst}.backup.$(date +%Y%m%d%H%M%S)"
        warn "$dst 已存在，备份到 $backup"
        mv "$dst" "$backup"
    fi

    # 确保父目录存在
    mkdir -p "$(dirname "$dst")"

    ln -s "$src" "$dst"
    info "$dst → $src"
}

echo "=============================="
echo " Dotfiles 安装"
echo "=============================="
echo ""

# 检测平台
OS="$(uname -s)"
case "$OS" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="linux" ;;
    *)      error "不支持的系统: $OS"; exit 1 ;;
esac

echo "检测到平台: $PLATFORM"
echo ""

# --- 通用链接 ---
link_file "$DOTFILES/shell/.shared_rc"          "$HOME/.shared_rc"
link_file "$DOTFILES/nvim/.config/nvim"          "$HOME/.config/nvim"
link_file "$DOTFILES/tmux/.tmux.conf"            "$HOME/.tmux.conf"

# --- 平台专属链接 ---
if [ "$PLATFORM" = "macos" ]; then
    link_file "$DOTFILES/shell/.zshrc"           "$HOME/.zshrc"
elif [ "$PLATFORM" = "linux" ]; then
    link_file "$DOTFILES/shell/.bashrc"          "$HOME/.bashrc"
fi

echo ""

# --- 提示创建 secrets 文件 ---
if [ ! -f "$HOME/.secrets" ]; then
    echo -e "${YELLOW}[提示]${NC} 建议创建 ~/.secrets 存放 API key 等敏感信息（不会进入 git）"
    echo "  例如: echo 'export ANTHROPIC_AUTH_TOKEN=\"xxx\"' >> ~/.secrets"
fi

echo ""
echo "安装完成!"
