---
name: parallel-codex
description: 用 `codex` CLI 把一个多模块编码任务并行拆给多个 codex agent 干活的编排方法——每个 codex 跑在自己的 git worktree 里。当编排方（可能是 Claude Code，也可能是任意调度 agent）需要把一坨独立、可拆分的编码工作分发给多个真·codex 并行推进时使用。覆盖：按文件边界拆工单、写单一事实源契约、建 worktree、`codex exec` 无头启动、先冒烟后扇出、后台监控、统一验收 + 合并；以及踩过的坑（未提交的 spec 不进 worktree、新 worktree 缺 .venv/node_modules、codex 不读 CLAUDE.md、共享文件合并冲突、commit 作者归属）。不适用于单一不可拆的任务。
---

# 并行 codex 编排

> 主视角是**编排方**（可能是 Claude Code，也可能是别的调度 agent）。下文「编排方」= 你这个调度者，「codex」= 被 `codex exec` 拉起的执行 agent（真的 codex CLI，不是子 agent）。
>
> 核心思想：把任务按**文件边界**切成互不重叠的工单 → 每个工单一个 git worktree + 一个 codex → 并行跑 → 编排方统一验收合并。worktree 提供隔离，编排方掌握 commit 作者与合并节奏。

## 0. 前提

- `codex` CLI 已装：`which codex` / `codex --version`。
- 已登录：`codex login status`（输出 `Logged in ...` 即可；否则先 `codex login`）。**没登录就扇出 = 全部空烧。**
- 目标仓库是 git 仓库（worktree 依赖 git）。

## 1. 总流程

1. **拆工单**：切成**文件边界互不重叠**的块。重叠越少，并行越干净、合并越省事。
2. **写单一事实源 + 工单**：一份契约 / spec doc（接口、边界、验收口径）当唯一事实源，再给每块写一份工单 prompt（都引用同一契约，避免各 codex 各自发明接口）。**全部先 commit**（见坑 4.1）。
3. **建 worktree**：每块一个 worktree + 分支，从已含 spec 的 base commit 拉。
4. **冒烟一个**：先只起 1 个 codex，确认「登录 / 沙箱 / 能真改文件」这条链通了，再扇出其余（见坑 4.6）。
5. **扇出**：其余 codex 后台并发起，各自日志落文件。
6. **监控**：tail 各自日志；编排方会在每个后台进程结束时被唤醒。
7. **验收**：逐个 `git -C <worktree> diff` 审边界 + 契约符合度；运行时验收（起服务 / build / 跑测试）由编排方补跑——worktree 多半缺依赖（见坑 4.3）。
8. **合并**：编排方以正确作者在各 worktree 提交 → 顺序 merge 回主干 → 清理 worktree。

## 2. 命令速查

建 worktree（base 必须已含 spec + 工单）：

```bash
git worktree add <path> -b <branch> <base>   # 例：git worktree add ../proj-d1 -b feat/d1 main
git worktree list
```

无头起 codex（后台 + 独立日志）：

```bash
codex exec \
  -s workspace-write \
  -c sandbox_workspace_write.network_access=true \
  -C <worktree> \
  "<工单 prompt>" > /tmp/codex-<tag>.log 2>&1 &
```

- `codex exec [OPTIONS] "PROMPT"` 是非交互入口；prompt 作参数或走 stdin。
- `-C <dir>` 指定工作根；`-s` 选沙箱；`-m <model>` 指定模型（不传走默认）。

监控 / 收尾：

```bash
tail -f /tmp/codex-<tag>.log
git -C <worktree> status --short
git -C <worktree> diff
git worktree remove <path>     # 干净才删；--force 慎用
git branch -d <branch>
```

## 3. 沙箱选择（`-s`）

| 模式 | 能干什么 | 何时用 |
|---|---|---|
| `read-only` | 只读 | 纯调研 / 出方案，不改文件 |
| `workspace-write` | 改 worktree 内文件；加 `-c sandbox_workspace_write.network_access=true` 放行网络（npm / 调模型） | **默认推荐**——文件写入锁在 worktree 内，最安全 |
| `danger-full-access` | 全文件系统 + 网络，仍走审批 | 偶尔要写 worktree 外 |
| `--dangerously-bypass-approvals-and-sandbox` | 跳过一切审批 + 无沙箱 | codex 要自己端到端验收（起服务、绑端口、跑 e2e）且环境已外部隔离时 |

权衡：`workspace-write` 安全，但**起服务 / 绑端口可能被沙箱挡** → codex 只能做 `py_compile` 这类语法检查，运行时验收留给编排方。要 codex 自己跑通端到端验收，才上 `--dangerously-bypass...`，并清楚它能执行任意命令。

## 4. 坑（都是真摔出来的）

**4.1 未提交的 spec / 工单不会进新 worktree。** `git worktree add` 从某个 commit 拉，**工作区里未提交的改动不带过去**。所以建 worktree 之前，契约 + 所有工单必须先 commit 到 base 分支，否则每个 codex 进去看不到自己的工单。

**4.2 按文件边界拆，工单里列死「不许碰」。** 写清该 codex 只动哪些文件、绝不碰哪些（尤其共享内核 / 业务逻辑层）。实在无法避免的共享文件（如路由注册表、入口聚合文件）→ 明确告诉每个 codex「只加你自己那几行，合并时若冲突保留双方」。

**4.3 新 worktree 缺被 gitignore 的依赖。** `.venv` / `node_modules` 通常被 gitignore，**不进新 worktree**。后果：codex 跑不了依赖命令（起后端、build 前端），只能语法编译检查。运行时验收由编排方在装好依赖的环境（主 worktree，或先 `uv sync` / `npm install`）补跑。工单里就要写「跑不了的验收项明确标注，别假装通过」。

**4.4 codex 不读 CLAUDE.md。** codex 默认认 `AGENTS.md`，不认 `CLAUDE.md`。项目约定（注释语言、提交作者、端口、网关地址）要么直接写进 prompt，要么 prompt 里点名「先读 CLAUDE.md」。

**4.5 让 codex 别 commit，作者归编排方。** codex 自行 commit 会用它自己的 git 身份。要统一提交作者，工单里写「不要 git commit / push，改动留工作区」，由编排方审完以正确 `--author` 提交；或允许 codex 提交、编排方合并时再 re-author。

**4.6 先冒烟一个再扇出。** 一上来并发 N 个，若卡在登录 / 沙箱 / 审批，就是 N 份白烧（codex 调模型花钱）。先起 1 个，tail 日志确认它真在读文件、真在改，再并发其余。

**4.7 worktree 共享 .git，但工作区独立。** 多 worktree 共享 object store 与 refs，但**各有独立 index 和工作区**——并发 codex 不会互相覆盖文件。各自在自己分支提交也安全；别让多个 codex 往同一分支并发提交。

## 5. 工单 prompt 模板

```
你是在一个 git worktree 中独立作业的工程 agent，工作根就是这个 worktree。
先读项目根 CLAUDE.md 了解约定（注释语言、提交作者、端口等），
再完整阅读并实施工单 <工单路径>，配合单一事实源 <契约路径>。
严格遵守工单边界：只动 <允许文件>，绝不碰 <禁止文件>。
这是 N 个并行 worktree 之一，请只改你工单列出的文件。
实施完按工单验收自检；跑不了的验收项（沙箱 / 缺依赖）明确说明，别假装通过。
不要 git commit / push，改动留工作区由编排方统一合并。
完成后用中文简述改了哪些文件、验收结果。
```

要点：① 指明 worktree 身份与边界；② 指向工单 + 契约（别把全部细节塞 prompt，让它自己读文件）；③ 禁止 commit；④ 要求如实报告未跑的验收项。

## 6. 验收 + 合并

1. 逐 worktree `git -C <wt> diff` 审：边界守住没？契约符合没？有没有误改无关文件？
2. 补跑运行时验收（编排方装好依赖的环境）：起服务、build、跑测试、关键 e2e。
3. 过了 → 编排方在该 worktree 以正确作者提交：`git -C <wt> commit --author="..." -m "..."`。
4. 顺序合并回主干：`git merge --no-ff <branch>`；共享文件冲突按「保留双方」解。
5. 清理：`git worktree remove <wt>` + `git branch -d <branch>`。
6. 向用户汇总成果；push 等用户授权（除非已有长期授权）。

## 7. 一句话决策

> 任务能切成**互不重叠的文件块** → 值得并行 codex。切不开、或块之间强耦合 → 老老实实串行，别硬拆（合并冲突会吃光并行省下的时间）。
