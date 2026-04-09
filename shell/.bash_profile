# ============================================
# .bash_profile — Linux / WSL 专用 (Bash Login Shell)
# ============================================

# SSH / login shell 默认优先读 .bash_profile，不一定自动读 .bashrc。
# 这里统一转发到 .bashrc，确保 .shared_rc 和 tmux 上下文同步 hook 始终生效。
if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
