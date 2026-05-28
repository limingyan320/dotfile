---
name: parallel-codex
description: Use when orchestrating a large, separable coding task by launching multiple real `codex exec` agents in parallel, each isolated in its own git worktree. Covers task slicing by file boundaries, single-source specs, committing the spec before worktree fan-out, smoke-testing one agent first, foreground/PTY or background launch monitoring, validation, merge order, cleanup, and common failure modes such as silent background launch exits, missing ignored dependencies, AGENTS.md/CLAUDE.md differences, shared-file conflicts, and commit authorship. Not for tightly coupled tasks that cannot be split cleanly.
---

# Parallel Codex Orchestration

Use this when the current Codex session is the orchestrator and the workers are separate real `codex exec` CLI processes running in isolated git worktrees.

Core idea: split by non-overlapping file boundaries, give every worker the same committed contract/spec, run one worker as a launch-mode smoke test, fan out the rest with that same launch mode, then validate and merge centrally.

## Preconditions

- `codex` CLI is installed: `which codex` and `codex --version`.
- The CLI is logged in: `codex login status`. Do not fan out before confirming login.
- The target project is a git repository.
- The task can be split into mostly independent file ownership areas. If it cannot, do the work serially.

## Workflow

1. **Slice the work** by file or module boundaries. Minimize overlapping files.
2. **Write one source of truth**: a committed contract/spec that defines shared interfaces, behavior, boundaries, and acceptance criteria.
3. **Write worker prompts** that reference the contract and explicitly list allowed and forbidden files.
4. **Commit the contract and prompts before creating worktrees.** Uncommitted files in the main working tree will not appear in new worktrees.
5. **Create one worktree per worker** from the base commit containing the contract.
6. **Smoke test one worker and the launch mode**. Confirm it can read files, edit files, and report status before launching the rest. Also confirm the process/session is still alive after 5-15 seconds and has produced non-empty output.
7. **Fan out workers** with the same launch mode that passed the smoke test. Prefer foreground/PTY or orchestrator-managed unified exec sessions when shell background redirection is unreliable.
8. **Monitor sessions, logs, and exits**. Keep enough process or session state to clean up reliably; do not leave required background jobs running at the end or after the user redirects the task.
9. **Validate centrally**: review each diff for boundary violations and contract compliance, then run build/tests/e2e in an environment with dependencies installed.
10. **Commit, merge, and clean up** from the orchestrator side.

## Commands

Create worktrees from the committed base:

```bash
git worktree add <path> -b <branch> <base>
git worktree list
```

Recommended launch under a Codex orchestrator: start each worker as a long-running foreground/PTY or unified exec session, then record the returned session id.

```bash
codex exec \
  -s workspace-write \
  -c sandbox_workspace_write.network_access=true \
  -C <worktree> \
  "<worker prompt>"
```

Optional shell background launch, only after this exact mode has passed the smoke test in the current environment:

```bash
codex exec \
  -s workspace-write \
  -c sandbox_workspace_write.network_access=true \
  -C <worktree> \
  "<worker prompt>" > /tmp/codex-<tag>.log 2>&1 &
```

Useful follow-up commands:

```bash
# Foreground/unified sessions: poll the session output through the orchestrator tool.
# Shell background jobs:
tail -f /tmp/codex-<tag>.log

# Both launch modes:
ps -p <pid>
git -C <worktree> status --short
git -C <worktree> diff
git -C <worktree> commit --author="Name <email@example.com>" -m "<message>"
git merge --no-ff <branch>
git worktree remove <path>
git branch -d <branch>
```

Smoke-check the launch before fan-out:

```bash
sleep 5
ps -p <pid>
test -s /tmp/codex-<tag>.log
git -C <worktree> status --short
```

For a foreground/unified session, replace the `ps` and log-size checks with polling the session output. The worker should emit the Codex header/session startup output or otherwise show it has started reading instructions. A vanished PID plus a zero-byte log means launch failure, not an idle worker; switch to foreground/PTY or unified exec sessions before continuing.

## Sandbox Choice

- `read-only`: research only.
- `workspace-write`: default for workers; confines writes to the worktree. Add `-c sandbox_workspace_write.network_access=true` only when the worker needs network.
- `danger-full-access`: only when the worker must touch files outside the worktree or run broader local checks.
- `--dangerously-bypass-approvals-and-sandbox`: only for externally isolated environments where the worker must run end-to-end validation without sandbox limits.

Always obey the current session's permission and approval policy. If the user or environment forbids a mode, choose a safer mode or do the work serially.

## Worker Prompt Template

```text
You are an independent engineering agent running inside one git worktree.
Your working root is this worktree.

First read the project instructions:
- Read AGENTS.md if present.
- If this project only has CLAUDE.md or other agent docs, read those too because this worker must follow the repository conventions.

Then read and implement worker ticket <ticket path>, using shared contract <contract path> as the single source of truth.

Boundaries:
- You may edit only: <allowed files>
- You must not edit: <forbidden files>
- This is one of multiple parallel worktrees. Do not change files outside your ticket.

Validation:
- Run the checks listed in the ticket when possible.
- If a check cannot run because of sandbox limits or missing ignored dependencies, state that clearly. Do not claim it passed.

Do not git commit or push. Leave changes in the worktree for the orchestrator to review and merge.
When finished, report changed files and validation results concisely.
```

## Pitfalls

- **Uncommitted specs do not enter new worktrees.** Commit the contract and tickets before `git worktree add`.
- **Background redirection can silently fail.** In some Codex/PTY environments, `codex exec ... > log 2>&1 &` or `nohup codex exec ... &` exits immediately with a zero-byte log. Treat that as failed launch and use foreground/PTY or orchestrator-managed unified exec sessions instead.
- **Ignored dependencies are missing.** New worktrees usually lack `.venv`, `node_modules`, build caches, and other gitignored state. Workers may be limited to static checks; run full validation centrally.
- **Codex reads AGENTS.md, not CLAUDE.md by default.** If the repo relies on CLAUDE.md, tell each worker to read it explicitly or include the relevant rules in the prompt.
- **Shared files cause conflicts.** Prefer non-overlapping ownership. For unavoidable shared registries or route tables, tell each worker exactly which lines/entries to add and resolve merges by preserving all entries.
- **Worker commits complicate authorship.** Prefer "do not commit" prompts; the orchestrator commits after review using the correct author.
- **Fan-out amplifies setup mistakes.** Always smoke test one worker before launching many.
- **User redirects require cleanup.** If the user changes direction while workers are running, stop or record active worker sessions/processes before starting unrelated work.
- **Worktrees share git object storage but not working directories.** Separate branches and worktrees are safe for parallel edits; do not have multiple workers commit to the same branch.

## Merge Discipline

1. Review each worktree with `git -C <worktree> diff` and `git -C <worktree> status --short`.
2. Reject or repair boundary violations before merging.
3. Run central validation with dependencies available.
4. Commit accepted changes in each worktree with the intended author.
5. Merge branches back one at a time, resolving shared-file conflicts by preserving all intended changes.
6. Remove clean worktrees and delete merged branches.
7. Summarize results, validation, and any deferred checks to the user.

## Decision Rule

Use parallel Codex only when the work can be split into mostly independent file blocks. If the design, APIs, or shared implementation are still fluid, first create the contract serially; if the remaining work still overlaps heavily, keep it serial.
