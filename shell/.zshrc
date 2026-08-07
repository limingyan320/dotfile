# ============================================
# .zshrc — macOS 专用 (Zsh)
# ============================================

# --- macOS 专用 PATH ---
export PATH=$PATH:/usr/local/mysql/bin

# --- 键位模式（emacs，确保 Ctrl+A/E 等行编辑快捷键正常工作）---
bindkey -e

# --- Option+Left/Right 按词移动 ---
# iTerm2 / Terminal.app 常见会发送 xterm 风格的 Alt+Arrow 序列。
# 显式绑定后，zsh 命令行和 nvim :terminal 里的 shell 都能按词跳转。
for seq in $'\e[1;3D' $'\e[1;9D' $'\e\e[D'; do
    bindkey "$seq" backward-word
done
for seq in $'\e[1;3C' $'\e[1;9C' $'\e\e[C'; do
    bindkey "$seq" forward-word
done

# --- Zsh 补全 ---
autoload -Uz compinit
compinit
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' menu select

# --- Zsh 插件 ---
source ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh
source ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# --- 终端颜色 ---
export CLICOLOR=1
export LSCOLORS=gxfxcxdxbxegedabagacad

# --- Conda ---
# !! Contents within this block are managed by 'conda init' !!
__conda_setup="$('/Users/lumynous/miniconda3/bin/conda' 'shell.zsh' 'hook' 2> /dev/null)"
if [ $? -eq 0 ]; then
    eval "$__conda_setup"
else
    if [ -f "/Users/lumynous/miniconda3/etc/profile.d/conda.sh" ]; then
        . "/Users/lumynous/miniconda3/etc/profile.d/conda.sh"
    else
        export PATH="/Users/lumynous/miniconda3/bin:$PATH"
    fi
fi
unset __conda_setup

# --- macOS 专用函数 ---
# 切换深色/浅色模式
function dark() {
    osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to not dark mode'
}

# Shadowrocket 控制
function sr() {
    case $1 in
        toggle|t) shortcuts run "开关shadowrocket" ;;
        config|c) shortcuts run "规则代理" ;;
        global|p) shortcuts run "全局代理" ;;
        direct|d) shortcuts run "直连代理" ;;
        list|l)   shortcuts list | grep "SR" ;;
        *)        echo "用法: sr {toggle|config|global|direct|list}" ;;
    esac
}

# --- macOS 专用别名 ---
alias memo='open -a Notes'
alias gimme='open -a'
alias obs='open -a Obsidian'
alias v5="ssh -N -D 1080 administrator@192.168.100.127"
alias chrome='open -na "Google Chrome" --args --ignore-certificate-errors --user-data-dir=/tmp/chrome-insecure'
alias mirror='/Users/lumynous/UxPlay/build/uxplay -n kagami -nh -vsync no -vs "osxvideosink force-aspect-ratio=true"'



# Added by Antigravity
export PATH="/Users/lumynous/.antigravity/antigravity/bin:$PATH"
export PATH="$HOME/.local/bin:$PATH"

# --- 加载通用配置（必须放在末尾，让 Starship 作为最后设置 PROMPT 的人）---
source ~/.shared_rc
