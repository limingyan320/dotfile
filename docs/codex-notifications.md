# Codex 通知与 Nvim Session 状态

## 状态模型

每台机器独立维护自己的 Nvim session 状态，不做跨主机 Session 聚合：

```text
UserPromptSubmit  -> working      -> Telescope 流动三点
Stop / notify     -> ready/unread -> Telescope 闪烁红色 ! + macOS popup
最新输出被看到    -> seen         -> 清除 ! 并 dismiss 同一个 popup
title 静默 6 秒   -> idle         -> 仅清理同 turn 仍残留的 working
Codex TermClose   -> idle         -> 仅清理同 turn 仍残留的 working
```

`codex-notifications/agent_state.py` 使用 Nvim socket 定位 session，并用 Codex `session_id + turn_id` 关联状态、popup 和 check。状态保存在本机的 `$DOTFILES_NVIM_SESSION_DIR/agent-status/`；状态文件不进 git，Nvim session 退出时清理。

Codex 当前在用户中断回合时不会触发 `Stop` hook，因此 Nvim 还会监测自己 Codex terminal 的 `b:term_title`。`apply.sh` 显式启用 Codex title spinner；对应 terminal 每 200ms 在本地采样一次 title，工作中的 spinner 会持续刷新 6 秒 debounce。title 静默后只有状态仍是同一个 `turn_id` 的 `working` 才原子回到 `idle`；正常完成的 `Stop` hook 最多运行 5 秒，会优先写入 `ready` / `seen`，不会被兜底吞掉。Codex 进程退出时 `TermClose` 使用相同的 turn guard 立即清理。该监测随 Nvim session 在后台继续运行，不依赖 Dashboard 是否打开或 UI 是否 attached。

“看到”要求对应 Nvim UI 在前台、Codex drawer 是当前窗口，并且视口已经位于 terminal 最新输出。Codex 完成时若满足这些条件，结果直接视为 seen，不产生未读标记或 popup；否则保持未读，直到 attach 回该 session、切入 Codex 窗口、恢复焦点或滚动到底后满足条件。仅仅连接到该 session 的编辑窗口、打开 Telescope，或把尚未查看的 drawer 隐藏，都不会误清未读。用户在 agent terminal-normal 中滚离最新输出后，Nvim 会锁定 cursor / topline；完成输出、hook 的 observed 查询和 drawer guardian 修复都不会把视口拉走，只有手动滚到底部、按 `G` 或进入 terminal-input 才解除阅读锁。

迟到的旧 turn notify 不会覆盖新 turn 的 working 状态；listener 还会短期保留已 check 的 notification ID，阻止迟到 popup 重新出现。

## 生成配置

运行：

```bash
bash ~/.dotfiles/codex-notifications/apply.sh
```

脚本只管理这些配置：

- `~/.codex/config.toml` 的 `notify`、`features.hooks`、`tui.notifications`、`tui.animations`、`tui.terminal_title`
- `~/.codex/hooks.json` 中带 `dotfiles-codex-agent-state` marker 的 `UserPromptSubmit` / `Stop` command hook

其他 Codex 配置和其他 hook 会保留。新 hook 第一次使用时需在 Codex 中运行 `/hooks`，检查命令路径后 trust；自动化测试可临时使用 `--dangerously-bypass-hook-trust`，日常启动不要全局绕过 hook trust。

macOS 的 `setup.sh` 还会安装 `com.lumynous.codex-notify-listener` LaunchAgent。listener 只监听 `127.0.0.1:47789`，提供：

```text
POST /notify    显示按 notification ID 管理的 popup
POST /dismiss   check 对应 turn，并关闭同一个 popup
GET  /health    查看 active / acknowledged 数量
```

## SSH 远端

远端 Nvim 只显示远端自己的 session；Mac 只是 popup 接收端。SSH alias 需要把远端 loopback `47789` 反向转发到 Mac listener：

```sshconfig
Host gpu1
  RemoteForward 47789 127.0.0.1:47789
```

完成和 check 都走同一条 tunnel：远端 `/notify` 到 Mac；你在远端 Nvim 中真正看到对应 Codex 最新输出后，远端再向 Mac `/dismiss`。不同远端主机可以各自使用 `47789`；同一主机的多个独立 SSH 连接会争抢同一个远端端口，长期使用时应让该 alias 使用一条 multiplexed master connection，或确保承载反向转发的连接持续存在。

若 SSH tunnel 暂时不可用，远端 Telescope 状态仍然正确；Mac popup 的显示或联动关闭会降级失败，不影响 Codex 回合。

## 排查

```bash
# Mac listener
curl -fsS http://127.0.0.1:47789/health
launchctl print gui/$(id -u)/com.lumynous.codex-notify-listener

# 当前 Nvim server 的 agent 状态
python3 ~/.dotfiles/codex-notifications/agent_state.py inspect --server "$NVIM"

# 确认远端反向端口存在
ssh gpu1 'ss -ltn | rg 47789'
```
