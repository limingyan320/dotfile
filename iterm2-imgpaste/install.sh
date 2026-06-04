#!/usr/bin/env bash
# install.sh — 把 iclip daemon 接进 iTerm2(symlink 到 AutoLaunch),提示开 Python API。
# 由 setup.sh 在 macOS 上调用,也可单独跑。幂等。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
ok()   { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$1"; }

[ "$(uname -s)" = "Darwin" ] || { warn "非 macOS,iclip daemon 只在 Mac 侧装,跳过"; exit 0; }

# 1) 脚本可执行
chmod +x "$HERE"/*.sh 2>/dev/null

# 2) symlink daemon 进 iTerm2 AutoLaunch
AL="$HOME/Library/Application Support/iTerm2/Scripts/AutoLaunch"
mkdir -p "$AL"
ln -snf "$HERE/iclip_daemon.py" "$AL/iclip_daemon.py"
ok "daemon 已链接 → $AL/iclip_daemon.py"

# 3) 一次性手动步骤(GUI,无法可靠脚本化)
cat <<'EOF'

—— 一次性手动步骤(iTerm2 GUI)——
  1) iTerm2 → Settings(Cmd+,)→ General → Magic → 勾【Enable Python API】
  2) 顶部菜单 Scripts → AutoLaunch → iclip_daemon.py 跑一次
     (首次会提示下载 Python Runtime + 授权脚本控制 iTerm2,都同意)
     之后每次启动 iTerm2 会自动拉起。
  用法:在连了远端的 iTerm2 里复制一张图 → 按 Cmd+Shift+V
EOF
