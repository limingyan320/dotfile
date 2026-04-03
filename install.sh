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

# ============================================
# 第一步：检测平台
# ============================================
OS="$(uname -s)"
case "$OS" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="linux" ;;
    *)      error "不支持的系统: $OS"; exit 1 ;;
esac

echo "=============================="
echo " Dotfiles 安装"
echo "=============================="
echo ""
echo "检测到平台: $PLATFORM"
echo ""

# ============================================
# 第二步：安装包管理器和软件
# ============================================
echo "--- 安装软件 ---"
echo ""

if [ "$PLATFORM" = "macos" ]; then
    # macOS: 安装 Homebrew（如果没有）
    if ! command -v brew &>/dev/null; then
        info "正在安装 Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    else
        warn "Homebrew 已安装，跳过"
    fi

    # macOS: 安装软件
    for pkg in neovim tmux git; do
        if brew list "$pkg" &>/dev/null; then
            warn "$pkg 已安装，跳过"
        else
            info "正在安装 $pkg..."
            brew install "$pkg"
        fi
    done

    # macOS: 安装 zsh 插件
    mkdir -p "$HOME/.zsh"
    if [ ! -d "$HOME/.zsh/zsh-autosuggestions" ]; then
        info "正在安装 zsh-autosuggestions..."
        git clone https://github.com/zsh-users/zsh-autosuggestions "$HOME/.zsh/zsh-autosuggestions"
    else
        warn "zsh-autosuggestions 已安装，跳过"
    fi
    if [ ! -d "$HOME/.zsh/zsh-syntax-highlighting" ]; then
        info "正在安装 zsh-syntax-highlighting..."
        git clone https://github.com/zsh-users/zsh-syntax-highlighting "$HOME/.zsh/zsh-syntax-highlighting"
    else
        warn "zsh-syntax-highlighting 已安装，跳过"
    fi

elif [ "$PLATFORM" = "linux" ]; then
    # Linux/WSL: apt 安装
    info "正在更新软件包列表..."
    sudo apt update

    for pkg in neovim tmux git xclip bash-completion; do
        if dpkg -s "$pkg" &>/dev/null; then
            warn "$pkg 已安装，跳过"
        else
            info "正在安装 $pkg..."
            sudo apt install -y "$pkg"
        fi
    done
fi

echo ""

# ============================================
# 第三步：创建符号链接
# ============================================
echo "--- 创建符号链接 ---"
echo ""

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
