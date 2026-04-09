#!/usr/bin/env bash

set -u

action="${1:-}"
pane_id="${2:-}"

if [ -z "$action" ] || [ -z "$pane_id" ]; then
    echo "usage: $0 <split-h|split-v|split-left|split-up|new-window> <pane-id>" >&2
    exit 1
fi

tmux_fmt() {
    tmux display-message -p -t "$pane_id" "$1"
}

decode_base64() {
    if command -v base64 >/dev/null 2>&1; then
        if printf '%s' "$1" | base64 -d >/dev/null 2>&1; then
            printf '%s' "$1" | base64 -d
            return
        fi
        if printf '%s' "$1" | base64 -D >/dev/null 2>&1; then
            printf '%s' "$1" | base64 -D
            return
        fi
    fi
    return 1
}

quote_sh() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

pane_title="$(tmux_fmt '#{pane_title}')"
local_path="$(tmux_fmt '#{pane_current_path}')"
session_target="$(tmux_fmt '#{session_id}')"
window_target="$(tmux_fmt '#{window_id}')"

if [ -z "$local_path" ]; then
    local_path="$HOME"
fi

split_args=()
case "$action" in
    split-h) split_args=(-h) ;;
    split-v) split_args=(-v) ;;
    split-left) split_args=(-hb) ;;
    split-up) split_args=(-vb) ;;
    new-window) ;;
    *)
        echo "unknown action: $action" >&2
        exit 1
        ;;
esac

new_window() {
    if tmux new-window -a -t "$window_target" "$@"; then
        exit 0
    fi

    exec tmux new-window -t "$session_target" "$@"
}

case "$pane_title" in
    dotctx\ ssh\ *)
        rest="${pane_title#dotctx ssh }"
        ssh_target="${rest%% *}"
        encoded_path="${rest#"$ssh_target" }"
        if [ -n "$ssh_target" ] && [ -n "$encoded_path" ]; then
            if remote_path="$(decode_base64 "$encoded_path" 2>/dev/null)"; then
                remote_cmd="cd $(quote_sh "$remote_path") && exec \${SHELL:-/bin/sh} -l"
                ssh_cmd="ssh -t $(quote_sh "$ssh_target") $(quote_sh "$remote_cmd")"
                if [ "$action" = "new-window" ]; then
                    new_window "$ssh_cmd"
                else
                    exec tmux split-window "${split_args[@]}" -t "$pane_id" "$ssh_cmd"
                fi
            fi
        fi
        ;;
esac

if [ "$action" = "new-window" ]; then
    new_window -c "$local_path"
else
    exec tmux split-window "${split_args[@]}" -t "$pane_id" -c "$local_path"
fi
