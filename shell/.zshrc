# ============================================
# .zshrc — macOS 专用 (Zsh)
# ============================================

# 加载通用配置
source ~/.shared_rc

# --- macOS 专用 PATH ---
export PATH=$PATH:/usr/local/mysql/bin

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

# --- Git 分支提示符 ---
autoload -Uz vcs_info
precmd() { vcs_info }
zstyle ':vcs_info:git:*' formats ' (%b)'
setopt PROMPT_SUBST
PROMPT='%F{cyan}%~%f%F{red}${vcs_info_msg_0_}%f $ '

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

# conda 环境显示在提示符前
PROMPT='${CONDA_DEFAULT_ENV:+($CONDA_DEFAULT_ENV) }'$PROMPT

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

# Added by Antigravity
export PATH="/Users/lumynous/.antigravity/antigravity/bin:$PATH"
