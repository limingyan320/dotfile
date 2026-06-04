#!/usr/bin/env bash
# resolve_host.sh <iterm2-session-tty>
# 给定 iTerm2 当前 session 的 tty(/dev/ttysNNN 或 ttysNNN),解析它最终连到的
# ssh 目标【别名】(scp 能直接用的那个,如 ~/.ssh/config 里的 Host 名)。
#  - 若该 session 前台是本地 tmux 客户端,先穿过 tmux 找到 active pane 的 tty;
#  - 在目标 tty 上取 ssh 命令行,跳过带值 flag,抽出目标 host。
# 解析成功 → 打印 alias;否则不打印、退出 0(调用方据此 degrade,绝不乱推)。
set -u

norm_tty() { printf '%s' "${1#/dev/}"; }

# 从一条 ssh 命令行抽出目标 host(跳过带值 flag,取第一个非 flag 参数)
extract_ssh_alias() {
  # shellcheck disable=SC2086
  set -- $1
  [ "${1:-}" = "ssh" ] || return 1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; break ;;
      -*) case "$1" in
            -B|-b|-c|-D|-E|-e|-F|-I|-i|-J|-L|-l|-m|-O|-o|-p|-Q|-R|-S|-W|-w) shift 2 ;;
            *) shift ;;
          esac ;;
      *) printf '%s\n' "$1"; return 0 ;;
    esac
  done
  return 1
}

# 在某 tty 上找 ssh 命令行并抽 host
alias_from_tty() {
  local tty line
  tty="$(norm_tty "$1")"
  line="$(ps -t "$tty" -o command= 2>/dev/null | grep -m1 -E '^ssh( |$)')"
  [ -n "$line" ] || return 1
  extract_ssh_alias "$line"
}

# 该 tty 上是否有本地 tmux 客户端
is_tmux_on_tty() {
  ps -t "$(norm_tty "$1")" -o command= 2>/dev/null | grep -qE '(^|/| )tmux( |$)'
}

ITTY="$(norm_tty "${1:?usage: resolve_host.sh <session-tty>}")"

if is_tmux_on_tty "$ITTY"; then
  # 找 client_tty == /dev/$ITTY 的 tmux client → 它的 session → active window 的 active pane 的 tty
  sess="$(tmux list-clients -F '#{client_tty} #{session_name}' 2>/dev/null \
          | awk -v t="/dev/$ITTY" '$1==t{print $2; exit}')"
  if [ -n "$sess" ]; then
    ptty="$(tmux display-message -p -t "$sess" '#{pane_tty}' 2>/dev/null)"
    [ -n "$ptty" ] && alias_from_tty "$ptty" && exit 0
  fi
fi

# 非 tmux,或 tmux 解析失败:直接在 iTerm2 session tty 上找 ssh
alias_from_tty "$ITTY" && exit 0
exit 0
