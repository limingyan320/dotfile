# Nvim Background Renderer

The Neovim background panel is renderer-independent. Color and transparent
canvas modes work without this directory; this helper adds iTerm2-specific
image, opacity, and blur controls. Kitty support is implemented directly in
`nvim/.config/nvim/lua/dotfiles/background_renderers/kitty.lua` and does not
use this daemon.

The panel's `Renderer` control can persist either `Auto` or `Off`.
`Off` restores the terminal state captured before Neovim applied its
background, then bypasses automatic renderer detection on later UI attach and
focus events. Opening the panel still probes available capabilities so `Auto`
can be restored without restarting. It is also the native fallback on machines
where no renderer bridge is available.

In Kitty, `Auto` uses the focused window reported by `kitten @ ls`, applies the
image with `set-background-image`, and snapshots/restores the OS-window opacity.
The managed `kitty/kitty.conf` exposes a same-user Unix socket and enables
dynamic opacity. ImageMagick supplies cached image blend, image blur, alpha and
Fit preprocessing; Kitty itself owns Fill, Stretch and Tile layout. The adapter
removes its image and restores the captured opacity on the last UI detach or
Neovim exit. Kitty is optional and is not installed automatically. Restart
Kitty after first linking this config because `listen_on` and
`dynamic_background_opacity` are startup settings rather than hot-reloadable
options. Blend follows iTerm2's direction: `0` is the terminal background color
and `100` is the unblended source image.

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
