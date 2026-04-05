# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Cross-platform dotfiles synced via git, targeting macOS (zsh), Linux (Debian/Fedora/Bazzite), and WSL (bash). The repo lives at `~/.dotfile/` and uses symlinks to place config files in their expected locations.

## Architecture

```
shell/.shared_rc     <- 跨平台通用配置（别名、PATH、环境变量），被 .zshrc 和 .bashrc source
shell/.zshrc         <- macOS 专用：zsh 补全、插件、conda、macOS 函数（dark, sr）
shell/.bashrc        <- Linux/WSL 专用：bash 补全、PS1 提示符
nvim/.config/nvim/   <- Neovim 配置，跨平台通用，使用 lazy.nvim 管理插件
tmux/.tmux.conf      <- tmux 配置，跨平台通用，剪贴板自动检测 (pbcopy/wl-copy/xclip/clip.exe)
install.sh           <- 一键安装脚本，自动检测包管理器 (brew/rpm-ostree/dnf/apt) 和平台
```

**Shell 配置层级**: `.zshrc` / `.bashrc` -> `source ~/.shared_rc` -> `source ~/.secrets`

**敏感信息**: API key 等存放在 `~/.secrets`（已 gitignore），由 `.shared_rc` 自动加载。绝不要把 token 写入本仓库的文件。

## Key Commands

```bash
# 新机器安装
git clone <repo-url> ~/.dotfile
bash ~/.dotfile/install.sh

# 日常同步（任意一台机器改了配置后）
cd ~/.dotfile && git add -A && git commit -m "描述" && git push

# 另一台机器拉取
cd ~/.dotfile && git pull
```

## Platform Differences

- **包管理器**: install.sh 自动检测 brew/rpm-ostree/dnf/apt，找不到则提示手动安装
- **剪贴板**: tmux.conf 逐级检测 — macOS (pbcopy)、Wayland (wl-copy)、X11 (xclip)、WSL (clip.exe)
- **Shell**: macOS 链接 `.zshrc`，Linux/WSL 链接 `.bashrc`，通用配置在 `.shared_rc`
- **nvim / tmux**: 完全跨平台，不需要区分
- **支持的发行版**: macOS、Debian/Ubuntu、Fedora/RHEL/Bazzite、WSL

## Conventions

- 通用配置加在 `shell/.shared_rc`，平台专属配置加在对应的 shell 文件
- nvim 插件通过 lazy.nvim 管理，`lazy-lock.json` 锁定版本需要一起提交
- 新增配置工具时在 `install.sh` 里添加对应的 `link_file` 调用
- install.sh 自动检测自身所在目录，不要硬编码 DOTFILES 路径

## Reference Docs

- **Neovim & Tmux 操作速查**: 当用户询问 nvim/tmux 快捷键、窗口管理、搜索跳转等操作问题时，先读取 `docs/nvim-tmux-cheatsheet.md` 再回答。该文件包含基于本 dotfile 实际配置的个性化快捷键速查表。配置变更后需同步更新此文件。
