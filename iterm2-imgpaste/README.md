# iterm2-imgpaste — Mac 剪贴板图片 → 远端 CLI agent

在 iTerm2 里按一个快捷键，把 **Mac 本地剪贴板里的图片**送进**远端 SSH 会话**里跑着的
CLI agent（Claude Code / Codex）输入框——不用手动 rsync、不用手敲路径。

## 用法
1. Mac 上复制/截图一张图片（截图到剪贴板：`Ctrl+Cmd+Shift+4`）
2. 在连着远端、跑着 agent 的 iTerm2 pane 里按 **Cmd+Shift+V**
3. 远端图片路径自动以「粘贴」形式进输入框 → Claude 当文件读图 / Codex 变 `[Image]` 附件 → 回车

> ⚠️ 若本机用 Karabiner 把 左Cmd↔左Opt 对调了，触发键的「Cmd」可能要按物理 Opt 键；
> daemon 对 **Command/Option 任一 + Shift + V** 都认，按哪个都触发。
> Raycast 等全局热键若占用了 ⌘⇧V，会在 iTerm2 之前拦截 → 需改键或解绑。

## 原理（数据流）
```
[Mac 剪贴板有图] --Cmd+Shift+V（iTerm2 Python API 守护脚本捕获）-->
  1) resolve_host.sh  : 当前 session 连的远端（穿本地 tmux 找 active pane，认 ssh 命令行 alias）
  2) grab_clipboard.sh: osascript 取剪贴板 PNG → 临时文件
  3) push_image.sh    : scp 推到 远端 ~/.cache/iclip/（鉴权 = 你的 SSH authorized_keys）
  4) async_send_text  : 远端绝对路径以 bracketed paste（\e[200~…\e[201~）注入当前 session
                        → 字节顺 SSH/tmux 流到远端 agent，被当成「粘贴了一张图」
```
不碰系统剪贴板同步、不开额外守护进程/端口、不自建鉴权——图片走普通 SSH，鉴权天然去中心化。

## 文件
- `iclip_daemon.py`   iTerm2 AutoLaunch 守护：捕获快捷键 + 编排下面四步 + 注入
- `grab_clipboard.sh` 取剪贴板图片（pngpaste 优先，无则 osascript/sips；无图则 graceful 空退出）
- `resolve_host.sh`   解析当前 iTerm2 session 最终连到的 ssh 别名（穿 tmux + 失准则 degrade）
- `push_image.sh`     scp 推送 + 远端建目录(0700) + 回显绝对路径
- `install.sh`        symlink daemon 到 iTerm2 AutoLaunch + 提示开 Python API（由 setup.sh 调）

## 安装（每台 Mac 一次）
1. `bash ~/.dotfiles/setup.sh`（或单独 `bash install.sh`）→ daemon 链进 iTerm2 AutoLaunch
2. iTerm2 → Settings → General → Magic → 勾 **Enable Python API**
3. iTerm2 → Scripts → AutoLaunch → `iclip_daemon.py` 跑一次（首次下载 Python Runtime + 授权）；之后随 iTerm2 自启

远端零安装（只要 SSH 可达；`push_image.sh` 会自动建 `~/.cache/iclip`）。

## 调试
- 日志：`~/Library/Logs/iclip-daemon.log`（operational 级，**不记按键内容**）
- 排查触发键：`ICLIP_DEBUG=1` 时把每次按键的 keycode/修饰键记进日志
- 触发了但提示「无远端」：当前在本地 pane 或检测失准（多跳/ProxyJump）→ 设计上跳过、不乱推
