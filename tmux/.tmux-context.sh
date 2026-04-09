#!/usr/bin/env bash

__dotfiles_b64() {
    if command -v base64 >/dev/null 2>&1; then
        printf '%s' "$1" | base64 | tr -d '\r\n'
    else
        printf '%s' "$1"
    fi
}

__dotfiles_tmux_set_title() {
    [ -n "${TMUX:-}" ] || return 0
    printf '\033]2;%s\033\\' "$1"
}

__dotfiles_tmux_sync_context() {
    [ -n "${TMUX:-}" ] || return 0
    case $- in
        *i*) ;;
        *) return 0 ;;
    esac

    local host path_b64 identity
    host="$(hostname 2>/dev/null || printf 'unknown-host')"
    path_b64="$(__dotfiles_b64 "${PWD:-$HOME}")"

    if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_CLIENT:-}" ]; then
        identity="${LOGNAME:-${USER:-unknown}}@${host}"
        __dotfiles_tmux_set_title "dotctx ssh ${identity} ${path_b64}"
    else
        __dotfiles_tmux_set_title "dotctx local ${host} ${path_b64}"
    fi
}
