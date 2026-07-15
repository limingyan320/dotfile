# Coding Learning Record

## Context
- Project: dotfiles
- Scenario: 使用独立 Git worktree 开发 Neovim 功能
- Goal: 理解 worktree 的工作目录、暂存区、HEAD 与共享仓库之间的关系
- Current module: linked worktree 的安全清理

## Recall Items
| Item | Kind | Exact or preferred form | Source | Status |
| --- | --- | --- | --- | --- |
| worktree 独立状态 | concept | 每个 worktree 有独立的工作目录、index（暂存区）和 HEAD | `.git/index`; `.git/worktrees/*/index` | new |
| worktree 共享状态 | concept | 所有 worktree 共享对象数据库和 refs（分支、标签） | `git rev-parse --git-common-dir` | new |
| 提交的可见性 | concept | 一个 worktree 创建的 commit 会立即进入共享对象库，但不会自动改写其他 worktree 的文件 | `git worktree list --porcelain` | new |
| 分支占用规则 | concept | 同一个本地分支通常不能同时被两个 worktree checkout；`--force` 可绕过保护但不适合并行开发 | `git worktree add -h` | learning |
| 分岔计数 | contract | `git rev-list --left-right --count A...B`；两列分别是 A、B 独有的 commit 数 | `git-rev-list(1)` | new |
| worktree 路径边界 | concept | `git worktree add <path>` 让 `<path>` 本身成为 linked worktree；其父目录只是容器，无需是 Git 仓库 | `.dotfiles-worktrees/codex-gx-paths/.git` | new |
| merge 方向 | contract | `git merge <source>` 的方向是 `当前 HEAD ← source commit`；若 source 就是当前 HEAD，则是无操作 | `git merge -h` | learning |
| worktree 身份 | concept | 用户主要通过路径识别 worktree；`.git/worktrees/<id>` 是 Git 内部管理 ID，不是 branch ref 式名称 | `git worktree list`; `.git/worktrees` | new |
| main 与 linked worktree | concept | 原始 checkout 是 main worktree，额外添加的是 linked worktree；这是存储结构差异，不代表提交优先级 | `.git`; linked `.git` file | new |
| rebase 方向 | contract | 在 feature 上执行 `git rebase main` 会重放 feature 独有提交并移动 feature；不会移动 `main` | `git-rebase(1)` | learning |
| rebase 后合入 | concept | rebase 成功后仍需在 main 上 fast-forward 到 feature，才算 feature 已进入 main | `git merge --ff-only` | learning |
| worktree 清理 | contract | 先用 `git worktree remove <path>` 删除 linked worktree，再用 `git branch -d <branch>` 安全删除已合并分支 | `git worktree remove -h`; `git branch -h` | shaky |
| rebase 冲突版本 | concept | rebase 时 OURS/HEAD 是 upstream（此处 main），THEIRS 是正在重放的 feature commit | `git ls-files -u`; conflict markers | learning |
| Diffview worktree 上下文 | contract | `:DiffviewOpen -C<worktree-path>` 强制使用指定 worktree 的 index 与 rebase 状态 | `diffview.txt:DiffviewOpen` | learning |
| rebase 冲突流程 | contract | 编辑合并结果并保存 → `git add` 标记解决 → `git rebase --continue` | `git status`; `git-rebase(1)` | learning |
| `--ff-only` 保护 | contract | 仅允许 fast-forward；若目标分支不再是 source 的祖先则中止，不自动创建 merge commit | `git merge --ff-only` | learning |

## Topics
| Topic | Source | Explained | Quizzed | Result |
| --- | --- | --- | --- | --- |
| Git worktree 状态模型 | `.git`; `.git/worktrees/codex-gx-paths` | 2026-07-15 | - | not-tested |
| 判断分支提交是否分岔 | `git rev-list`; `git log` | 2026-07-15 | - | not-tested |
| worktree 的目录布局 | `git worktree add`; linked `.git` file | 2026-07-15 | - | not-tested |
| worktree 与 branch 的对应关系 | `git worktree add -h`; `git worktree list` | 2026-07-15 | - | not-tested |
| merge 的目标与执行位置 | `git merge -h`; worktree `HEAD` | 2026-07-15 | - | not-tested |
| worktree 的身份与 main/linked 关系 | `git worktree list`; `.git/worktrees` | 2026-07-15 | - | not-tested |
| rebase 后是否已经完成合入 | `git rebase`; `git merge --ff-only` | 2026-07-15 | - | not-tested |
| linked worktree 的安全清理 | `git worktree remove`; `git branch -d` | 2026-07-15 | - | not-tested |
| 在 Neovim 中解决 rebase conflict | `DiffviewOpen -C`; rebase index stages | 2026-07-15 | - | not-tested |
| fast-forward 与 `--ff-only` | `git merge`; `merge.ff` | 2026-07-15 | - | not-tested |

## Active Quiz
- Topic: none
- Question: none
- Hint level: 0
- State: none

## Notes
- 曾把暂存区误认为所有 worktree 共享；需要区分共享仓库数据与每个 worktree 的独立 index。
- 分支分岔只比较 commit 历史；未提交的工作目录修改要分别用 `git status` 查看。
- rebase 解决的是提交基底与历史形状，不会自动把目标分支指针推进到 feature。
- linked worktree 与 feature branch 是两个对象，清理时需按顺序分别删除。
