#!/usr/bin/env bash
# push_image.sh <ssh-target> <local-png>
# 把本地 PNG scp 到远端 ~/.cache/iclip/,在 stdout 打印【远端绝对路径】。
# 失败时打印原因到 stderr 并以非 0 退出。鉴权完全走 SSH 自己(authorized_keys)。
set -u

TARGET="${1:?usage: push_image.sh <ssh-target> <local-png>}"
SRC="${2:?usage: push_image.sh <ssh-target> <local-png>}"

[ -s "$SRC" ] || { echo "push_image: 本地文件为空/不存在: $SRC" >&2; exit 1; }

BASE="iclip-$(date +%Y%m%d-%H%M%S)-$$.png"

# 工具连接:禁掉该 Host 配的所有端口转发(避免与已有会话抢端口/拖慢),batch 限时。
SSHO=(-o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 \
      -o ServerAliveInterval=5 -o ServerAliveCountMax=2)

# 一次 ssh:建/锁目录(0700,靠目录权限保护图片) + 清理 7 天前旧图 + 回显远端 $HOME
HOME_REMOTE=$(ssh "${SSHO[@]}" "$TARGET" \
  'umask 077; d=$HOME/.cache/iclip; mkdir -p "$d"; chmod 700 "$d"; find "$d" -type f -mtime +7 -delete 2>/dev/null; printf "%s" "$HOME"' \
  2>/dev/null)
[ -n "$HOME_REMOTE" ] || { echo "push_image: ssh 失败/无法连到 $TARGET" >&2; exit 1; }

scp "${SSHO[@]}" -q "$SRC" "$TARGET:.cache/iclip/$BASE" >/dev/null 2>&1 \
  || { echo "push_image: scp 失败 ($TARGET)" >&2; exit 1; }

printf '%s/.cache/iclip/%s\n' "$HOME_REMOTE" "$BASE"
