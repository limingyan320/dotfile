# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Cross-platform dotfiles synced via git, targeting macOS (zsh), Linux (Debian/Fedora/Bazzite), and WSL (bash). The repo lives at `~/.dotfile/` and uses symlinks to place config files in their expected locations.

## Architecture

```
shell/.shared_rc     <- 跨平台通用配置（别名、PATH、环境变量），被 .zshrc 和 .bashrc source
shell/.zshrc         <- macOS 专用：zsh 补全、插件、conda、macOS 函数（dark, sr）
shell/.bashrc        <- Linux/WSL 专用：bash 补全、PS1 提示符
shell/.bash_profile  <- Linux/WSL 的 login shell 入口，统一转发到 .bashrc，保证 SSH 登录也加载 .shared_rc
nvim/.config/nvim/   <- Neovim 配置，跨平台通用，使用 lazy.nvim 管理插件
tmux/.tmux.conf      <- tmux 配置，跨平台通用，剪贴板自动检测 (pbcopy/wl-copy/xclip/clip.exe)
kitty/kitty.conf     <- Kitty 可选终端配置；为 Nvim 背景 adapter 开启同用户 remote-control socket 和动态透明度
fastfetch/           <- fastfetch 配置、raw logo 和 preset；setup.sh 链到 ~/.config/fastfetch/
codex-notifications/ <- Codex notify + lifecycle hooks；记录每个 Nvim session 的 working/ready/seen，macOS listener 按 turn ID 管理可联动关闭的 Swift 弹窗；SSH 远端经反向转发回 Mac；apply.sh 合并 ~/.codex/config.toml / hooks.json
claude-notifications/<- claude-notifications-go 插件的自定义资源（音效/图标/标题），apply.sh 合并进 ~/.claude/claude-notifications-go/config.json
claude-skills/       <- Claude Code 用户级 skill（如 nvim-quickref），setup.sh 把每个子目录链到 ~/.claude/skills/
codex-skills/        <- Codex 专用 skill（如 nvim-quickref），setup.sh 把每个子目录链到 ~/.codex/skills/
karabiner/           <- (macOS) Karabiner-Elements 键盘映射（Caps Lock 层、双 Shift 切输入法、外设键盘左 Cmd⇄左 Option；内置键盘保持原生）；setup.sh 把整个目录链到 ~/.config/karabiner（必须目录级链接，GUI 保存会替换单文件 symlink）；automatic_backups/ 已 gitignore
raycast/             <- (macOS) Raycast extension hotkeys / aliases / preferences 的官方 .rayconfig 手动迁移说明；不 symlink Raycast 数据库
iterm2-imgpaste/     <- (macOS) iTerm2 快捷键把 Mac 剪贴板图片 push 到远端 SSH 会话、以 bracketed paste 注入 agent 输入框；setup.sh 调 install.sh 把 daemon 链到 iTerm2 AutoLaunch
nvim-background/     <- (macOS, optional) Nvim 通用背景面板的 iTerm2 renderer；Kitty renderer 直接位于 Nvim 配置中，不依赖此 helper
setup.sh             <- 一键安装/同步脚本，自动检测包管理器 (brew/rpm-ostree/dnf/apt) 和平台，重跑安全
```

**Shell 配置层级**: macOS `.zshrc -> .shared_rc -> .secrets`；Linux/WSL `.bash_profile -> .bashrc -> .shared_rc -> .secrets`

**敏感信息**: API key 等存放在 `~/.secrets`（已 gitignore），由 `.shared_rc` 自动加载。绝不要把 token 写入本仓库的文件。

## Key Commands

```bash
# 新机器安装（或任意机器重新同步）
git clone <repo-url> ~/.dotfile
bash ~/.dotfile/setup.sh

# 日常同步（任意一台机器改了配置后）
cd ~/.dotfile && git add -A && git commit -m "描述" && git push

# 另一台机器拉取
cd ~/.dotfile && git pull
```

## Platform Differences

- **包管理器**: setup.sh 自动检测 brew/rpm-ostree/dnf/apt，找不到则提示手动安装
- **剪贴板**: tmux.conf 逐级检测 — macOS (pbcopy)、Wayland (wl-copy)、X11 (xclip)、WSL (clip.exe)
- **Shell**: macOS 链接 `.zshrc`，Linux/WSL 链接 `.bash_profile` + `.bashrc`，通用配置在 `.shared_rc`
- **nvim / tmux**: 完全跨平台，不需要区分
- **支持的发行版**: macOS、Debian/Ubuntu、Fedora/RHEL/Bazzite、WSL

## Conventions

- 通用配置加在 `shell/.shared_rc`，平台专属配置加在对应的 shell 文件
- nvim 插件通过 lazy.nvim 管理，`lazy-lock.json` 锁定版本需要一起提交
- 新增配置工具时在 `setup.sh` 里添加对应的 `link_file` 调用
- setup.sh 自动检测自身所在目录，不要硬编码 DOTFILES 路径
- codex-notifications 的通知脚本、agent 状态桥、标题映射和 macOS listener/popup 放在 `codex-notifications/`；`~/.codex/config.toml`、`~/.codex/hooks.json` 与 `~/Library/LaunchAgents/com.lumynous.codex-notify-listener.plist` 由脚本在本机生成，不直接进 git
- claude-notifications 的自定义资源（音频、icon.png、titles.json）放在 `claude-notifications/`，改完跑 `bash claude-notifications/apply.sh` 即生效；`~/.claude/claude-notifications-go/config.json` 由脚本在本机生成，不进 git
- Raycast 不由 symlink 管理全量数据库；迁移 extension hotkeys / aliases / preferences 时使用官方 `.rayconfig` Export / Import，`.rayconfig` 虽加密但仍视为私密备份，不提交 git
- fastfetch 的 preset / logo / `ff` 选择逻辑变更后，同步更新 `docs/fastfetch-cheatsheet.md`
- 用户询问并确认 nvim/tmux 新用法后，需同步更新 `docs/nvim-tmux-cheatsheet.md`
- nvim `init.lua` 改动后，同步更新 `claude-skills/nvim-quickref/SKILL.md`、`codex-skills/nvim-quickref/SKILL.md` 和 `docs/nvim-tmux-cheatsheet.md`

## Reference Docs

- **Neovim & Tmux 操作速查**: 当用户询问 nvim/tmux 快捷键、窗口管理、搜索跳转等操作问题时，先读取 `docs/nvim-tmux-cheatsheet.md` 再回答。该文件包含基于本 dotfile 实际配置的个性化快捷键速查表。配置变更后需同步更新此文件。
- **Fastfetch 主题速查**: 当用户询问 `ff` / fastfetch 主题、默认分流、`~/.secrets` 覆盖时，先读取 `docs/fastfetch-cheatsheet.md` 再回答。
- **Codex 通知与 Session 状态**: 涉及 Codex popup、Nvim session agent 状态或 SSH 通知回传时，先读取 `docs/codex-notifications.md`。
