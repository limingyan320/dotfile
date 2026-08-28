#!/usr/bin/env bash
# ============================================
# setup.sh — 一键安装/同步 dotfiles
# 用法: bash ~/.dotfiles/setup.sh（重跑安全）
# ============================================
# 注意：本脚本故意不开 set -e。
# 软件 / 字体安装可能因网络失败，但符号链接步骤必须能跑完，
# 这样即便没网也能至少把配置链接好，等有网再补装软件。

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

has_real_command() {
    local resolved
    resolved="$(command -v -- "$1" 2>/dev/null || true)"
    case "$resolved" in
        /*) [ -x "$resolved" ] ;;
        *) return 1 ;;
    esac
}

# 某些 Linux 发行版默认把 Linuxbrew 放在 /usr/bin 后面；setup 期间也应
# 优先使用 brew 安装的软件，避免安装了新 Neovim 却继续检测到系统旧版。
HOMEBREW_BREW="$(command -v brew 2>/dev/null || true)"
if [ -z "$HOMEBREW_BREW" ]; then
    for HOMEBREW_CANDIDATE in \
        /opt/homebrew/bin/brew \
        /home/linuxbrew/.linuxbrew/bin/brew \
        /usr/local/bin/brew
    do
        if [ -x "$HOMEBREW_CANDIDATE" ]; then
            HOMEBREW_BREW="$HOMEBREW_CANDIDATE"
            break
        fi
    done
fi
if [ -n "$HOMEBREW_BREW" ]; then
    eval "$("$HOMEBREW_BREW" shellenv)"
fi
unset HOMEBREW_BREW HOMEBREW_CANDIDATE

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
# 第 1.5 步：可选代理（仅对本脚本进程生效，不写任何全局/系统配置）
# ============================================
# 通过 export http(s)_proxy 给本脚本的子进程（curl/git/npm/brew 及管道安装脚本）用，
# 脚本退出即失效，绝不影响全局环境。http 与 https 共用同一个代理，不做区分。
# 注意：经 sudo 调用的包管理器（apt/dnf）默认会丢弃这些环境变量，不受此代理影响。
echo ""
echo "--- 代理设置 ---"
echo "本脚本会从 GitHub 等境外站点下载内容。"
echo "如需走代理，输入 ip:端口（例如 127.0.0.1:7890），直接回车跳过："
printf "代理 (ip:端口): "
PROXY_INPUT=""
if [ -r /dev/tty ]; then
    read -r PROXY_INPUT < /dev/tty
else
    read -r PROXY_INPUT
fi

enable_proxy() {
    local addr="$1"
    # 容错：去掉用户可能误带的协议前缀和首尾空白
    addr="${addr#http://}"; addr="${addr#https://}"; addr="${addr#socks5://}"
    addr="${addr## }"; addr="${addr%% }"
    local url="http://$addr"
    info "测试代理 $addr 是否可达..."
    if curl -fsS --connect-timeout 6 --proxy "$url" -o /dev/null https://github.com 2>/dev/null; then
        export http_proxy="$url"  https_proxy="$url"  all_proxy="$url"
        export HTTP_PROXY="$url"  HTTPS_PROXY="$url"  ALL_PROXY="$url"
        info "代理可用，已为本次安装启用 $addr（http/https 通用，仅本进程，不影响全局）"
    else
        warn "代理 $addr 不可达，回退到直连（不使用代理）"
    fi
}

if [ -n "$PROXY_INPUT" ]; then
    enable_proxy "$PROXY_INPUT"
else
    info "未设置代理，直连下载"
fi

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
        for pkg in neovim tmux git fastfetch ripgrep yazi chafa; do
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
        for pkg in neovim tmux git wl-clipboard bash-completion fastfetch ripgrep yazi chafa; do
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
        for pkg in neovim tmux git wl-clipboard bash-completion fastfetch ripgrep yazi chafa; do
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
        sudo apt update || warn "apt update 失败（可能是网络/代理问题），继续尝试安装已缓存的包"
        # neovim 单独处理：live session 需要 0.12，老发行版 apt 仓库版本不足
        for pkg in tmux git xclip bash-completion ripgrep python3-tomli yazi chafa; do
            if dpkg -s "$pkg" &>/dev/null; then
                warn "$pkg 已安装，跳过"
            else
                info "正在安装 $pkg..."
                sudo apt install -y "$pkg" || warn "$pkg 安装失败，跳过（可能是网络问题）"
            fi
        done
        # fastfetch：Ubuntu 24.04+ / Debian 13+ 才进 apt 源，老版本 fallback 到 GitHub .deb
        if command -v fastfetch &>/dev/null; then
            warn "fastfetch 已安装，跳过"
        elif sudo apt install -y fastfetch 2>/dev/null; then
            info "fastfetch 通过 apt 安装完成"
        else
            info "apt 源无 fastfetch，改为下载 GitHub 发行包..."
            ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
            case "$ARCH" in
                amd64|x86_64) FF_ARCH="amd64" ;;
                arm64|aarch64) FF_ARCH="aarch64" ;;
                *) FF_ARCH="" ;;
            esac
            if [ -z "$FF_ARCH" ]; then
                warn "不支持的架构 $ARCH，跳过 fastfetch"
            else
                TMP_DEB="$(mktemp --suffix=.deb)"
                FF_URL="https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-${FF_ARCH}.deb"
                if curl -fsSL "$FF_URL" -o "$TMP_DEB" && sudo dpkg -i "$TMP_DEB"; then
                    info "fastfetch 安装完成"
                else
                    warn "fastfetch 下载/安装失败（网络问题），跳过"
                fi
                rm -f "$TMP_DEB"
            fi
        fi
        # neovim：按 CPU 架构下载 AppImage，避免 apt 仓库太旧
        NVIM_VERSION_LINE="$(nvim --version 2>/dev/null | head -1 || true)"
        if nvim --clean --headless '+if !has("nvim-0.12") | cquit | endif' +quit >/dev/null 2>&1; then
            warn "neovim $NVIM_VERSION_LINE 已满足版本要求，跳过"
        else
            ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
            case "$ARCH" in
                amd64|x86_64) NVIM_ARCH="x86_64" ;;
                arm64|aarch64) NVIM_ARCH="arm64" ;;
                *) NVIM_ARCH="" ;;
            esac
            if [ -z "$NVIM_ARCH" ]; then
                warn "不支持的架构 $ARCH，跳过 Neovim AppImage；可尝试 sudo apt install neovim"
            else
                NVIM_URL="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${NVIM_ARCH}.appimage"
                TMP_NVIM="$(mktemp)"
                info "正在下载 Neovim ${NVIM_ARCH} AppImage 到 ~/.local/bin/nvim（live session 需要 ≥0.12）..."
                mkdir -p "$HOME/.local/bin"
                if curl -fsSL "$NVIM_URL" -o "$TMP_NVIM" && chmod +x "$TMP_NVIM" && mv "$TMP_NVIM" "$HOME/.local/bin/nvim"; then
                    info "Neovim AppImage 安装完成（确保 ~/.local/bin 在 PATH 中）"
                else
                    warn "Neovim AppImage 下载/安装失败（网络/代理问题），请稍后手动安装："
                    warn "  curl -fsSL $NVIM_URL -o ~/.local/bin/nvim && chmod +x ~/.local/bin/nvim"
                fi
                rm -f "$TMP_NVIM"
            fi
        fi
        ;;
    none)
        error "没有找到包管理器 (brew/rpm-ostree/dnf/apt)"
        error "请手动安装: neovim tmux git ripgrep"
        error "安装后重新运行此脚本以创建符号链接"
        ;;
esac

echo "--- 安装 Neovim Treesitter 依赖 ---"
echo ""

if tree-sitter --version &>/dev/null; then
    warn "tree-sitter CLI 已安装，跳过"
elif command -v npm &>/dev/null; then
    info "正在通过 npm 安装 tree-sitter-cli（nvim-treesitter 编译 parser 需要）..."
    if npm install -g tree-sitter-cli; then
        info "tree-sitter CLI 安装完成"
    else
        warn "tree-sitter-cli npm 安装失败，nvim-treesitter parser 自动安装可能会报错"
    fi
else
    case "$PKG_MANAGER" in
        brew)
            info "正在安装 tree-sitter..."
            brew install tree-sitter || warn "tree-sitter 安装失败，nvim-treesitter parser 自动安装可能会报错"
            ;;
        rpm-ostree)
            info "正在通过 rpm-ostree 安装 tree-sitter-cli..."
            if sudo rpm-ostree install --idempotent tree-sitter-cli; then
                sudo rpm-ostree apply-live 2>/dev/null || warn "apply-live 失败，需要重启后生效: sudo systemctl reboot"
            else
                warn "tree-sitter-cli 安装失败，nvim-treesitter parser 自动安装可能会报错"
            fi
            ;;
        dnf)
            info "正在安装 tree-sitter-cli..."
            sudo dnf install -y tree-sitter-cli || warn "tree-sitter-cli 安装失败，nvim-treesitter parser 自动安装可能会报错"
            ;;
        apt)
            info "正在安装 tree-sitter-cli..."
            sudo apt install -y tree-sitter-cli || warn "tree-sitter-cli 安装失败，nvim-treesitter parser 自动安装可能会报错"
            ;;
        *)
            warn "未找到 npm 或可用包管理器，请手动安装 tree-sitter-cli"
            ;;
    esac
fi

echo ""

# 第 2.5 步,安装 Starship
echo "---安装 Starship---"
echo ""

if command -v starship &>/dev/null; then
    warn "Starship已安装,跳过"
else
    info "正在安装 Starship"
    if curl -sS https://starship.rs/install.sh | sh -s -- --yes; then
        info "Starship 安装完成"
    else
        warn "Starship 安装失败（网络/代理问题），跳过"
    fi
fi

echo ""

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
    if curl -fsSL "$FONT_URL" -o "$TMP_DIR/${FONT_NAME}.tar.xz"; then
        mkdir -p "$FONT_DIR"
        tar -xf "$TMP_DIR/${FONT_NAME}.tar.xz" -C "$TMP_DIR"
        find "$TMP_DIR" -name '*.ttf' -exec mv {} "$FONT_DIR/" \;
        # Linux 刷新字体缓存
        if [ "$PLATFORM" = "linux" ] && command -v fc-cache &>/dev/null; then
            fc-cache -f "$FONT_DIR"
        fi
        info "$FONT_NAME Nerd Font 安装完成"
    else
        warn "字体下载失败（网络/代理问题），跳过"
    fi
    rm -rf "$TMP_DIR"
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
link_file "$DOTFILES/tmux/.tmux-context.sh"      "$HOME/.tmux-context.sh"
link_file "$DOTFILES/tmux/open-context-pane.sh"  "$HOME/.tmux-open-context-pane.sh"
link_file "$DOTFILES/starship/starship.toml"     "$HOME/.config/starship.toml"
link_file "$DOTFILES/fastfetch/config.jsonc"     "$HOME/.config/fastfetch/config.jsonc"
link_file "$DOTFILES/fastfetch/logos"            "$HOME/.config/fastfetch/logos"
link_file "$DOTFILES/fastfetch/presets"          "$HOME/.config/fastfetch/presets"
for skill_dir in "$DOTFILES"/claude-skills/*; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"
    link_file "$skill_dir" "$HOME/.claude/skills/$skill_name"
done
# 自动发现并链接全部 Codex skills；新增目录无需再单独写 ln -s
for skill_dir in "$DOTFILES"/codex-skills/*; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"
    link_file "$skill_dir" "$HOME/.codex/skills/$skill_name"
done

# --- 平台专属链接 ---
if [ "$PLATFORM" = "macos" ]; then
    link_file "$DOTFILES/shell/.zshrc"           "$HOME/.zshrc"
    # Karabiner 必须链接整个目录而不是单个 json：GUI 保存时是"写临时文件再替换"，
    # 链接单文件会被替换成普通文件，目录级链接则不受影响
    link_file "$DOTFILES/karabiner"              "$HOME/.config/karabiner"
elif [ "$PLATFORM" = "linux" ]; then
    link_file "$DOTFILES/shell/.bash_profile"    "$HOME/.bash_profile"
    link_file "$DOTFILES/shell/.bashrc"          "$HOME/.bashrc"
fi

echo ""

# --- 提示创建 secrets 文件 ---
if [ ! -f "$HOME/.secrets" ]; then
    echo -e "${YELLOW}[提示]${NC} 建议创建 ~/.secrets 存放 API key 等敏感信息（不会进入 git）"
    echo "  例如: echo 'export ANTHROPIC_AUTH_TOKEN=\"xxx\"' >> ~/.secrets"
fi

echo ""

# ============================================
# Raycast 配置迁移
# ============================================
if [ "$PLATFORM" = "macos" ]; then
    echo "--- Raycast 配置迁移 ---"
    echo ""
    warn "Raycast hotkeys / aliases / preferences 不由 setup.sh 自动导入"
    echo "  如需迁移 m4 Raycast extension 快捷键，请在 Raycast 里手动运行 Import Settings & Data"
    echo "  并导入私下保存的 .rayconfig；详细步骤见 $DOTFILES/raycast/README.md"
    echo ""
fi

# ============================================
# Codex CLI 通知
# ============================================
echo "--- Codex CLI 通知 ---"
echo ""

if has_real_command codex; then
    info "同步 Codex 原生通知配置..."
    bash "$DOTFILES/codex-notifications/apply.sh" || warn "codex-notifications/apply.sh 有异常退出码，但已尽力处理"
    if [ "$PLATFORM" = "macos" ]; then
        info "安装 Codex 本地通知接收器..."
        bash "$DOTFILES/codex-notifications/install-listener.sh" || warn "Codex listener 安装有异常退出码，但已尽力处理"
    fi
else
    warn "codex CLI 未找到，跳过 Codex 通知配置（装好 codex 后重跑 setup.sh）"
fi

echo ""

# ============================================
# Claude Code 插件
# ============================================
echo "--- Claude Code 插件 ---"
echo ""

if has_real_command claude; then
    CLAUDE_NOTIFY_BIN="$HOME/.claude/plugins/marketplaces/claude-notifications-go/bin/claude-notifications"
    if [ -f "$CLAUDE_NOTIFY_BIN" ]; then
        warn "claude-notifications-go 已安装，跳过"
    else
        info "正在安装 claude-notifications-go..."
        if curl -fsSL https://raw.githubusercontent.com/777genius/claude-notifications-go/main/bin/bootstrap.sh | bash; then
            info "claude-notifications-go 安装完成"
        else
            warn "claude-notifications-go 安装失败（网络/代理问题），跳过"
        fi
    fi

    # 把 dotfiles/claude-notifications/ 里的自定义音效、图标、标题同步进 config
    # apply.sh 内部已经宽容处理各种缺失/不合法场景，不会 block 本脚本
    info "同步自定义通知资源..."
    bash "$DOTFILES/claude-notifications/apply.sh" || warn "apply.sh 有异常退出码，但已尽力处理"
else
    warn "claude CLI 未找到，跳过 claude-notifications-go 安装（装好 claude 后重跑 install.sh）"
fi

echo ""

# ============================================
# iTerm2 剪贴板图片 → 远端 agent(iclip)
# ============================================
echo "--- iTerm2 图片粘贴(iclip)---"
echo ""

if [ "$PLATFORM" = "macos" ]; then
    bash "$DOTFILES/iterm2-imgpaste/install.sh" || warn "iclip install.sh 有异常退出码，但已尽力处理"
    bash "$DOTFILES/nvim-background/install.sh" || warn "Nvim background helper 安装有异常退出码，但已尽力处理"
else
    warn "iclip 的 Mac 侧 daemon 只装在 macOS；Linux 仅作被推送端（push 时自动建 ~/.cache/iclip），无需配置"
    warn "iTerm2 renderer 只在 macOS 安装；Nvim 背景面板和颜色调节仍可使用"
fi

echo ""
echo "安装完成!"
