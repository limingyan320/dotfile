# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Cross-platform dotfiles synced via git, targeting macOS (zsh), Linux, and WSL (bash). The repo lives at `~/.dotfiles/` and uses symlinks to place config files in their expected locations.

## Architecture

```
shell/.shared_rc     ← 跨平台通用配置（别名、PATH、环境变量），被 .zshrc 和 .bashrc source
shell/.zshrc         ← macOS 专用：zsh 补全、插件、conda、macOS 函数（dark, sr）
shell/.bashrc        ← Linux/WSL 专用：bash 补全、PS1 提示符
nvim/.config/nvim/   ← Neovim 配置，跨平台通用，使用 lazy.nvim 管理插件
tmux/.tmux.conf      ← tmux 配置，跨平台通用，通过 if-shell 判断剪贴板命令
install.sh           ← 一键安装脚本，检测平台后创建符号链接
```

**Shell 配置层级**: `.zshrc` / `.bashrc` → `source ~/.shared_rc` → `source ~/.secrets`

**敏感信息**: API key 等存放在 `~/.secrets`（已 gitignore），由 `.shared_rc` 自动加载。绝不要把 token 写入本仓库的文件。

## Key Commands

```bash
# 新机器安装
bash ~/.dotfiles/install.sh

# 日常同步（任意一台机器改了配置后）
cd ~/.dotfiles && git add -A && git commit -m "描述" && git push

# 另一台机器拉取
cd ~/.dotfiles && git pull
```

## Platform Differences

- **剪贴板**: tmux.conf 用 `if-shell` 判断 — macOS 用 `pbcopy`，Linux 用 `xclip`
- **Shell**: macOS 链接 `.zshrc`，Linux 链接 `.bashrc`，通用配置在 `.shared_rc`
- **nvim / tmux**: 完全跨平台，不需要区分

## Conventions

- 通用配置加在 `shell/.shared_rc`，平台专属配置加在对应的 shell 文件
- nvim 插件通过 lazy.nvim 管理，`lazy-lock.json` 锁定版本需要一起提交
- 新增配置工具时在 `install.sh` 里添加对应的 `link_file` 调用
