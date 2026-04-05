#!/usr/bin/env bash
# ============================================
# install.sh — 一键安装 dotfiles（创建符号链接）
# 用法: bash ~/.dotfile/install.sh
# ============================================

set -e

# 自动检测脚本所在目录（不硬编码路径）
DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ============================================
# 第二步：检测包管理器并安装软件
# ============================================
detect_pkg_manager() {
    if command -v brew &>/dev/null; then echo "brew"
    elif [ -f /run/ostree-booted ]; then echo "rpm-ostree"
    elif command -v dnf &>/dev/null; then echo "dnf"
    elif command -v apt &>/dev/null; then echo "apt"
    else echo "none"
    fi
}

PKG_MANAGER="$(detect_pkg_manager)"
echo "检测到包管理器: $PKG_MANAGER"
echo ""
echo "--- 安装软件 ---"
echo ""

case "$PKG_MANAGER" in
    brew)
        for pkg in neovim tmux git; do
            if brew list "$pkg" &>/dev/null; then
                warn "$pkg 已安装，跳过"
            else
                info "正在安装 $pkg..."
                brew install "$pkg"
            fi
        done
        ;;
    rpm-ostree)
        NEED_INSTALL=()
        for pkg in neovim tmux git wl-clipboard bash-completion; do
            if rpm -q "$pkg" &>/dev/null; then
                warn "$pkg 已安装，跳过"
            else
                NEED_INSTALL+=("$pkg")
            fi
        done
        if [ ${#NEED_INSTALL[@]} -gt 0 ]; then
            info "正在通过 rpm-ostree 安装: ${NEED_INSTALL[*]}..."
            sudo rpm-ostree install --idempotent "${NEED_INSTALL[@]}"
            if ! sudo rpm-ostree apply-live 2>/dev/null; then
                warn "apply-live 失败，需要重启后生效: sudo systemctl reboot"
            fi
        fi
        ;;
    dnf)
        for pkg in neovim tmux git wl-clipboard bash-completion; do
            if rpm -q "$pkg" &>/dev/null; then
                warn "$pkg 已安装，跳过"
            else
                info "正在安装 $pkg..."
                sudo dnf install -y "$pkg"
            fi
        done
        ;;
    apt)
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
        ;;
    none)
        error "没有找到包管理器 (brew/rpm-ostree/dnf/apt)"
        error "请手动安装: neovim tmux git"
        error "安装后重新运行此脚本以创建符号链接"
        ;;
esac

# macOS: 安装 zsh 插件
if [ "$PLATFORM" = "macos" ]; then
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
fi

echo ""

# ============================================
# 第三步：安装 Nerd Font（用户目录，无需 sudo）
# ============================================
echo "--- 安装字体 ---"
echo ""

FONT_NAME="JetBrainsMono"
if [ "$PLATFORM" = "macos" ]; then
    FONT_DIR="$HOME/Library/Fonts"
else
    FONT_DIR="$HOME/.local/share/fonts"
fi

if ls "$FONT_DIR"/${FONT_NAME}*.ttf &>/dev/null; then
    warn "$FONT_NAME Nerd Font 已安装，跳过"
else
    info "正在安装 $FONT_NAME Nerd Font..."
    FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/${FONT_NAME}.tar.xz"
    TMP_DIR="$(mktemp -d)"
    curl -fsSL "$FONT_URL" -o "$TMP_DIR/${FONT_NAME}.tar.xz"
    mkdir -p "$FONT_DIR"
    tar -xf "$TMP_DIR/${FONT_NAME}.tar.xz" -C "$FONT_DIR" --wildcards '*.ttf'
    rm -rf "$TMP_DIR"
    # Linux 刷新字体缓存
    if [ "$PLATFORM" = "linux" ] && command -v fc-cache &>/dev/null; then
        fc-cache -f "$FONT_DIR"
    fi
    info "$FONT_NAME Nerd Font 安装完成"
fi

echo ""

# ============================================
# 第四步：创建符号链接
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
