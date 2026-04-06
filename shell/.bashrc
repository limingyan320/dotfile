# ============================================
# .bashrc — Linux / WSL 专用 (Bash)
# ============================================

# --- Bash 补全 ---
if [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
elif [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
fi

# --- 终端颜色 ---
export CLICOLOR=1
alias ls='ls --color=auto'
alias grep='grep --color=auto'

# --- 加载通用配置（必须放在末尾，让 Starship 作为最后设置 PROMPT 的人）---
source ~/.shared_rc
