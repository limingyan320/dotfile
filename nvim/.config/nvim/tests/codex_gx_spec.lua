local uv = vim.uv

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(("%s: expected %s, got %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local root = vim.fs.normalize(vim.fn.getcwd())
local fake_bin = vim.fn.tempname()
assert(vim.fn.mkdir(fake_bin, "p") == 1)
assert(uv.fs_symlink(vim.fn.exepath("true"), vim.fs.joinpath(fake_bin, "codex")))
vim.env.PATH = fake_bin .. ":" .. vim.env.PATH

vim.api.nvim_cmd({ cmd = "edit", args = { vim.fs.joinpath(root, "README.md") } }, {})
local editor_win = vim.api.nvim_get_current_win()
local toggle = vim.fn.maparg("<M-/>", "n", false, true)
assert(type(toggle.callback) == "function", "Codex toggle mapping is missing")
toggle.callback()

assert(vim.wait(1000, function()
  return vim.bo.buftype == "terminal"
end), "Codex terminal did not open")

local drawer_win = vim.api.nvim_get_current_win()
local codex_buf = vim.api.nvim_get_current_buf()
local job_id = vim.b[codex_buf].terminal_job_id
vim.fn.jobwait({ job_id }, 1000)
vim.bo[codex_buf].modifiable = true
vim.cmd.lcd(fake_bin)

local close_window = vim.fn.maparg("<C-W>c", "n", false, true)
local only_window = vim.fn.maparg("<C-W>o", "n", false, true)
assert(type(close_window.callback) == "function", "protected close mapping is missing in Codex")
assert(type(only_window.callback) == "function", "protected only mapping is missing in Codex")

vim.api.nvim_set_current_win(editor_win)
vim.cmd("vsplit")
local extra_editor_win = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(editor_win)
only_window.callback()
assert(not vim.api.nvim_win_is_valid(extra_editor_win), "editor <C-w>o should close another editor")
drawer_win = assert(vim.fn.win_findbuf(codex_buf)[1], "editor <C-w>o should restore the Codex drawer")
assert_equal(vim.api.nvim_win_get_buf(drawer_win), codex_buf, "restored Codex drawer buffer")

local original_notify = vim.notify
vim.notify = function() end
vim.api.nvim_set_current_win(drawer_win)
close_window.callback()
only_window.callback()
vim.notify = original_notify
assert(vim.api.nvim_win_is_valid(drawer_win), "Codex close/only mappings should preserve its window")
assert(vim.api.nvim_win_is_valid(editor_win), "Codex <C-w>o should preserve editor windows")

local function follow(reference, cursor_col, expected_path, expected_line, expected_column)
  vim.api.nvim_set_current_win(drawer_win)
  vim.api.nvim_buf_set_lines(codex_buf, 0, -1, false, { reference })
  vim.api.nvim_win_set_cursor(drawer_win, { 1, cursor_col })

  local gx = vim.fn.maparg("gx", "n", false, true)
  assert_equal(gx.buffer, 1, "gx should be buffer-local")
  assert(type(gx.callback) == "function", "Codex gx callback is missing")
  gx.callback()

  assert_equal(vim.api.nvim_get_current_win(), editor_win, "gx should focus the editor window")
  assert_equal(vim.api.nvim_buf_get_name(0), vim.fs.joinpath(root, expected_path), "opened path")
  assert_equal(vim.api.nvim_win_get_cursor(0), { expected_line, expected_column - 1 }, "cursor location")
  assert_equal(vim.api.nvim_win_get_buf(drawer_win), codex_buf, "Codex drawer should stay open")
end

local function reject(reference, cursor_col)
  vim.api.nvim_set_current_win(drawer_win)
  vim.api.nvim_buf_set_lines(codex_buf, 0, -1, false, { reference })
  vim.api.nvim_win_set_cursor(drawer_win, { 1, cursor_col })

  local notification
  local original_notify = vim.notify
  vim.notify = function(message)
    notification = message
  end
  local gx = vim.fn.maparg("gx", "n", false, true)
  gx.callback()
  vim.notify = original_notify

  assert_equal(vim.api.nvim_get_current_win(), drawer_win, "non-path context should stay in Codex")
  assert_equal(notification, "光标下没有可打开的 Codex 路径", "non-path context notification")
end

local function visual_follow(text, reference, expected_path, expected_line, expected_column)
  vim.api.nvim_set_current_win(drawer_win)
  vim.api.nvim_buf_set_lines(codex_buf, 0, -1, false, { text })
  local start_col = assert(text:find(reference, 1, true)) - 1
  vim.api.nvim_win_set_cursor(drawer_win, { 1, start_col })
  vim.cmd("normal! v")
  vim.api.nvim_win_set_cursor(drawer_win, { 1, start_col + #reference - 1 })

  local gx = vim.fn.maparg("gx", "x", false, true)
  assert_equal(gx.buffer, 1, "visual gx should be buffer-local")
  assert(type(gx.callback) == "function", "visual Codex gx callback is missing")
  gx.callback()

  assert_equal(vim.api.nvim_get_current_win(), editor_win, "visual gx should focus the editor window")
  assert_equal(vim.api.nvim_buf_get_name(0), vim.fs.joinpath(root, expected_path), "visual gx opened path")
  assert_equal(
    vim.api.nvim_win_get_cursor(0),
    { expected_line, expected_column - 1 },
    "visual gx cursor location"
  )
  assert_equal(vim.api.nvim_win_get_buf(drawer_win), codex_buf, "visual gx should leave Codex open")
end

follow("docs/nvim-tmux-cheatsheet.md:1:3", 8, "docs/nvim-tmux-cheatsheet.md", 1, 3)
follow("docs/nvim-tmux-cheatsheet.md:1:3。", 8, "docs/nvim-tmux-cheatsheet.md", 1, 3)
local inline_context = "rules docs/nvim-tmux-cheatsheet.md:1，PDF text follows"
follow(inline_context, 12, "docs/nvim-tmux-cheatsheet.md", 1, 1)
reject(inline_context, assert(inline_context:find("PDF", 1, true)) - 1)
follow(
  "[config](nvim/.config/nvim/init.lua:20:2)",
  3,
  "nvim/.config/nvim/init.lua",
  20,
  2
)
follow("nvim/.config/nvim/init.lua#L30C4", 32, "nvim/.config/nvim/init.lua", 30, 4)
visual_follow(
  "open docs/nvim-tmux-cheatsheet.md:1:3 please",
  "docs/nvim-tmux-cheatsheet.md:1:3",
  "docs/nvim-tmux-cheatsheet.md",
  1,
  3
)

vim.fs.rm(fake_bin, { recursive = true, force = true })
print("codex gx integration: ok")
vim.cmd("qa!")
