# ============================================
# .bashrc — Linux / WSL 专用 (Bash)
# ============================================

# 加载通用配置
source ~/.shared_rc

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

# --- Git 分支提示符 ---
parse_git_branch() {
    git branch 2>/dev/null | sed -n 's/* \(.*\)/ (\1)/p'
}
PS1='\[\e[36m\]\w\[\e[31m\]$(parse_git_branch)\[\e[0m\] $ '

