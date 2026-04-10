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

# --- Conda (Linux / Bash) ---
# 覆盖系统默认 ~/.bashrc 后，保留常见 Conda 安装位置的初始化能力。
if [ -z "${CONDA_EXE:-}" ]; then
    __dotfiles_conda_root=""
    for __dotfiles_conda_candidate in \
        "/opt/conda" \
        "$HOME/miniconda3" \
        "$HOME/anaconda3" \
        "$HOME/miniforge3" \
        "$HOME/mambaforge"
    do
        if [ -x "$__dotfiles_conda_candidate/bin/conda" ]; then
            __dotfiles_conda_root="$__dotfiles_conda_candidate"
            break
        fi
    done

    if [ -n "$__dotfiles_conda_root" ]; then
        __conda_setup="$("$__dotfiles_conda_root/bin/conda" 'shell.bash' 'hook' 2> /dev/null)"
        if [ $? -eq 0 ]; then
            eval "$__conda_setup"
        elif [ -f "$__dotfiles_conda_root/etc/profile.d/conda.sh" ]; then
            . "$__dotfiles_conda_root/etc/profile.d/conda.sh"
        else
            case ":$PATH:" in
                *":$__dotfiles_conda_root/bin:"*) ;;
                *) export PATH="$__dotfiles_conda_root/bin:$PATH" ;;
            esac
        fi
        unset __conda_setup
    fi

    unset __dotfiles_conda_candidate
    unset __dotfiles_conda_root
fi

# --- 加载通用配置（必须放在末尾，让 Starship 作为最后设置 PROMPT 的人）---
source ~/.shared_rc
