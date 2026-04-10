# Tmux SSH Inheritance Policy

## Background

The user wants tmux pane creation to preserve context from the current pane, but panes and windows should not behave identically.

There are two layers of desired behavior:

1. Local shell inheritance
   A new pane or new window should start in the same local working directory as the source pane.
2. SSH session inheritance
   If the source pane is currently connected to a remote machine via `ssh`, only a new pane should automatically establish the same SSH connection and restore the remote working directory from the source pane.

## Expected UX

The existing keybindings and muscle memory must remain unchanged.

- `prefix %`
- `prefix "`
- `prefix v`
- `prefix s`
- `prefix c`

The user does not want a separate command or alternative workflow. The standard tmux split/new-window keys should gain this behavior directly, with split and new-window intentionally diverging on SSH panes.

## Acceptance Criteria

### Local panes

Given a pane running a local shell:

- after `cd /some/path`
- pressing `prefix %`, `prefix "`, `prefix v`, `prefix s`, or `prefix c`
- should create the new pane/window in `/some/path`

### SSH panes

Given a pane where the foreground workflow is:

```bash
ssh user@host
cd /remote/path
```

then pressing `prefix %`, `prefix "`, `prefix v`, or `prefix s` should:

- open a new pane
- automatically reconnect to `user@host`
- land in `/remote/path`

and pressing `prefix c` should:

- open a new local window on the machine where tmux is running
- inherit the pane's local working directory
- not automatically reconnect to `user@host`

The experience should feel like pane splits extend the current SSH workflow, while new windows start a fresh local workspace.

## Non-Goals

- The user does not need tmux to clone arbitrary interactive program state.
- The primary target is standard shell and SSH usage.
- It is acceptable to require a prompt refresh boundary if clearly documented, but the final behavior should be reliable in normal interactive use.

## Current Status

Implemented in `tmux/open-context-pane.sh`:

- `prefix %`, `prefix "`, `prefix v`, `prefix s`: inherit local path, and when the source pane reports SSH context, reconnect to the same SSH target and remote path
- `prefix c`: always opens a local window on the tmux host using the pane's local path

Known dependency:

- Linux/bash remote login shells may enter through `.bash_profile` rather than `.bashrc`
- if `.bash_profile` does not source `.bashrc`, then `.shared_rc` never loads
- in that case the remote prompt never emits tmux context metadata, so SSH split inheritance degrades to local-only behavior

## Constraints

- Keep `CLAUDE.md` unchanged unless explicitly requested.
- Prefer project-wide guidance in `AGENTS.md`.
- If tmux behavior changes, keep `docs/nvim-tmux-cheatsheet.md` aligned.
- Avoid hardcoding the repository path in runtime logic; follow the repository convention that `setup.sh` should manage stable symlinks into `$HOME`.

## Suggested Investigation Path

Whoever picks this up next should verify, in order:

1. Whether `pane_current_path` already solves the local-only case on the target machine.
2. Whether tmux can reliably observe SSH context through pane title, pane path, OSC 7, or another shell-reported channel.
3. Whether the remote machine is guaranteed to load the same shell integration.
4. Whether the feature should degrade gracefully when the remote host lacks the required shell hook.
5. Whether the implementation should operate at tmux binding level, shell hook level, or both.

## Useful Debug Questions

When debugging on another machine, capture:

- tmux version
- local shell (`zsh` or `bash`)
- whether the remote shell loads this dotfiles repo
- output of:

```bash
tmux display-message -p '#{pane_current_path}'
tmux display-message -p '#{pane_title}'
tmux display-message -p '#{pane_current_command}'
```

- whether the failure happens for:
  - local split only
  - SSH split only
  - new window only

## Desired End State

The user should be able to treat tmux pane creation as context-aware:

- local pane -> local pane in same directory
- SSH pane split -> SSH pane to same host in same remote directory
- SSH pane new window -> local window on the tmux host in the pane's local directory

without changing existing keybindings or habits.
