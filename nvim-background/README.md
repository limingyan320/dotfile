# Nvim Background Renderer

The Neovim background panel is renderer-independent. Color and transparent
canvas modes work without this directory; this helper adds iTerm2-specific
image, opacity, and blur controls.

`iterm_background_daemon.py` listens on:

- `~/Library/Caches/dotfiles/iterm-background.sock` for local Neovim
- `127.0.0.1:47790` for SSH reverse forwarding

The helper claims a request only while iTerm2 is the active terminal. It writes
the active session's temporary profile, never the underlying saved profile.
Neovim keeps the original session snapshot for as long as a UI is attached.
Saving or cancelling the panel only changes the Neovim background state; detaching
the last UI or exiting Neovim restores the original iTerm2 session profile. A
later UI attach takes a fresh snapshot and reapplies the saved Neovim background.

For an SSH-hosted Neovim, `shell/.shared_rc` automatically adds the reverse
forward. A remote image selected with Yazi is content-addressed, uploaded once
to `~/Library/Caches/dotfiles/nvim-background-images/` on the Mac, and then
referenced by hash. TCP clients cannot request arbitrary Mac paths.

Run `install.sh` on macOS, then start `dotfiles_nvim_background.py` once from
iTerm2's `Scripts > AutoLaunch` menu. Set `DARWIN_NO_REMOTE_BACKGROUND=1` to
disable the automatic SSH bridge. Neovim stores UI settings in
`stdpath("state")/dotfiles-background.json`.
