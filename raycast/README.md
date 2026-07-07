# Raycast Settings Migration

Raycast extension commands 的 hotkeys、aliases 和 preferences 不通过 dotfiles symlink 管理，也不直接复制 Raycast 的本机数据库。使用 Raycast 官方的 `.rayconfig` Export / Import 流程迁移。

官方说明: https://manual.raycast.com/import-export

## Export From m4

1. 在 m4 打开 Raycast。
2. 运行 `Export Settings & Data`，或进入 Raycast `Settings -> Advanced -> Export`。
3. 设置至少 8 位的 export passphrase。
4. 导出 `.rayconfig` 到不进 git 的位置，例如 `~/Downloads/raycast-m4.rayconfig`、iCloud Drive、Dropbox 或其他私有目录。

`.rayconfig` 文件是加密的，但仍按私密备份处理，不提交到本仓库。

## Import On A New Machine

1. 在新机器安装并登录 Raycast。
2. 把 m4 导出的 `.rayconfig` 用安全方式传到本机。
3. 在 Raycast 里运行 `Import Settings & Data`。
4. 导入时按需勾选:
   - `Extensions installed from the Store`
   - `Settings, Aliases & Hotkeys`
   - 其他确实需要同步的 categories

如果只想同步快捷键和 alias，优先只勾 `Settings, Aliases & Hotkeys`，避免把 clipboard history、账号态或机器特定数据一起带过来。

## Verify After Import

- 在 Raycast `Settings -> Shortcuts` 搜索常用 extension，确认 hotkey / alias 已出现。
- 重点检查 Google Gemini、Easy Dictionary / OCR Translate、Bitwarden、LeetCode、Window Management 和常用 built-in commands。
- 实测 3 到 5 个关键快捷键，确认没有和 iTerm2 `Cmd+Shift+V`、Karabiner 或 macOS 系统快捷键冲突。
- 导入后运行 `git status --short`，确认没有 `.rayconfig`、sqlite、cache 或 token 配置进入仓库。

## Notes

- 不逆向、不解密、不同步 `raycast-enc.sqlite`。
- 不把 `~/raycast-scripts` 作为本迁移流程的主线；脚本命令可单独整理，和 extension hotkeys / aliases / preferences 迁移无关。
- `setup.sh` 不会安装 Raycast，也不会自动导入 `.rayconfig`。
