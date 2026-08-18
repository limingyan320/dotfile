---
name: parallel-codex
description: Use when the user explicitly asks Codex to parallelize a large, separable coding task with built-in subagents. Covers deciding whether to fan out, slicing work by non-overlapping file ownership, defining shared contracts, writing self-contained spawn prompts, monitoring and correcting agents, centralized review and validation, interruption handling, and optional worktree isolation for exceptional cases. Do not use for tightly coupled work or overlapping edits that require continuous coordination.
---

# Parallel Codex Orchestration

Use built-in subagents for worker execution. Treat the root agent as the orchestrator and integration owner.

All subagents share the same filesystem and working tree. Their edits are visible immediately, including uncommitted files and concurrent changes from other agents. Delegation does not broaden the user's authorization or the current environment's permissions.

## Decide Whether to Fan Out

Delegate only when at least two substantial tasks can proceed independently with stable boundaries. Prefer file or module ownership that does not overlap.

Keep the work serial when:

- shared interfaces or architecture are still changing;
- workers must repeatedly edit the same files;
- the task is too small to repay coordination and review overhead;
- tests, generators, migrations, lockfiles, or shared runtime state cannot run concurrently safely.

Use the fewest agents that provide useful parallelism and respect the current concurrency limit. Keep shared registries, integration files, and final cross-cutting changes with the root agent.

## Prepare the Fan-Out

1. Read repository instructions and inspect the relevant architecture before delegating.
2. Stabilize shared interfaces, behavior, and acceptance criteria serially.
3. Assign each worker an explicit, non-overlapping ownership set.
4. Put the shared contract in the worker prompts or a clearly referenced file. Do not commit merely to distribute it; subagents can see uncommitted files in the shared workspace.
5. Record existing user changes and tell workers to preserve them.

Each ticket must state:

- the concrete outcome;
- files or modules the worker owns;
- files it must not edit;
- the shared contract and relevant repository instructions;
- validation it should run;
- what to report when finished.

## Spawn Workers

Call `spawn_agent` only for concrete, bounded tasks that can run independently. Give each task a stable, descriptive name and a self-contained prompt.

Prefer inherited context when repository or user constraints from the conversation matter. Use reduced or no forked context only when the prompt and referenced contract are intentionally complete. Omit model and reasoning overrides unless the user explicitly requests them.

Do not ask workers to commit, push, merge, reset, revert, or clean the working tree. Do not allow nested delegation unless the ticket is intentionally hierarchical and enough concurrency remains.

While workers run, let the root agent handle a separate owned area, integration planning, or read-only investigation. Do not edit worker-owned files concurrently.

## Worker Prompt Template

```text
Implement <bounded outcome> in the shared working tree.

Read and follow <repository instructions and relevant skill/docs>.
Shared contract: <interface, behavior, and acceptance criteria>.

Ownership:
- You may edit only: <owned files/modules>.
- Do not edit: <shared or worker-owned files>.
- Preserve all pre-existing and concurrent changes outside your ownership.

Validation:
- Run: <targeted checks>.
- Report checks that cannot run; never claim they passed.

Do not commit, push, reset, revert, clean, or spawn more agents.
When finished, report changed files, behavioral notes, and validation results.
```

## Coordinate Workers

- Use `list_agents` to inspect live status when needed.
- Use `send_message` to clarify or redirect a worker that is still running.
- Use `wait_agent` with a long timeout instead of busy polling.
- Use `followup_task` to send a completed or idle worker back for a focused fix while preserving its context.
- Use `interrupt_agent` when the user redirects the task or a worker must stop immediately.

Do not treat an agent's final report as sufficient validation. Inspect its files and results directly.

## Integrate and Validate

1. Wait for all required workers to finish before final integration.
2. Inspect the aggregate working tree and compare changed paths with each ownership set.
3. Review behavior and contracts, not only whether the diff applies cleanly.
4. Repair boundary violations without reverting unrelated user or concurrent changes.
5. Run targeted tests for each component, then central integration, build, lint, or end-to-end checks as appropriate.
6. Commit or push only when the user requested it.
7. Summarize agent contributions, central validation, and any deferred checks.

## Shared-Workspace Pitfalls

- A worker's `git status` and `git diff` include everyone else's changes. Require explicit changed-file reports and verify centrally.
- Partial edits remain after failure or interruption. Inspect them before continuing; do not assume interrupting an agent rolls back files.
- Parallel formatters, code generators, dependency installs, migrations, and tests may contend for the same files, ports, databases, or caches. Assign isolated resources or serialize them.
- Clear file ownership prevents most races; prose instructions do not provide hard isolation. If workers need the same file, redesign the split or keep that work with the root agent.
- New user edits may appear while agents run. Treat them as user-owned and preserve them.

## Optional Worktree Isolation

Use worktrees only when hard filesystem or git-state isolation materially reduces risk, such as destructive generators, incompatible dependency states, or experiments that must not touch the main working tree. Continue to use built-in subagents; give each worker an explicit worktree path as its sole working directory.

Do not use worktrees to justify parallelizing unstable, overlapping design work. When a worktree starts from a commit, pass any missing uncommitted contract directly in the prompt or make it available deliberately. Review and integrate centrally, then remove only worktrees and branches created for the task.
