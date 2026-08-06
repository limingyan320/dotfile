local uv = vim.uv

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(("%s: expected %s, got %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local root = vim.fs.normalize(vim.fn.getcwd())
local fake_bin = vim.fn.tempname()
assert(vim.fn.mkdir(fake_bin, "p") == 1)
local fake_codex = vim.fs.joinpath(fake_bin, "codex")
local fake_codex_args = fake_codex .. ".args"
vim.env.DOTFILES_CODEX_TEST_ARGS = fake_codex_args
assert_equal(vim.fn.writefile({
  "#!/bin/sh",
  'printf "%s\\n" "$@" > "$DOTFILES_CODEX_TEST_ARGS"',
  "/usr/bin/seq 1 80",
  "while IFS= read -r line; do",
  '  if [ "$line" = "finish" ]; then',
  "    echo final-output",
  '  elif [ "$line" = "after-unlock" ]; then',
  "    echo after-unlock",
  "  fi",
  "done",
}, fake_codex), 0, "fake Codex fixture")
assert(uv.fs_chmod(fake_codex, 493))
vim.env.PATH = fake_bin .. ":/usr/bin:/bin"

local function buffer_contains(bufnr, needle)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n"):find(needle, 1, true) ~= nil
end

vim.api.nvim_cmd({ cmd = "edit", args = { vim.fs.joinpath(root, "README.md") } }, {})
local editor_win = vim.api.nvim_get_current_win()
local editor_buf = vim.api.nvim_get_current_buf()
local toggle = vim.fn.maparg("<M-/>", "n", false, true)
assert(type(toggle.callback) == "function", "Codex toggle mapping is missing")
toggle.callback()

assert(vim.wait(1000, function()
  return vim.bo.buftype == "terminal"
end), "Codex terminal did not open")

local drawer_win = vim.api.nvim_get_current_win()
local codex_buf = vim.api.nvim_get_current_buf()
assert_equal(drawer_win, editor_win, "Codex should reuse the current normal window")
assert_equal(vim.bo[codex_buf].buflisted, true, "Codex should be a listed session buffer")
local job_id = vim.b[codex_buf].terminal_job_id
assert(vim.wait(1000, function()
  return vim.fn.filereadable(fake_codex_args) == 1
end), "fake Codex did not record its arguments")
assert_equal(
  vim.fn.readfile(fake_codex_args),
  { "--yolo", "--no-alt-screen" },
  "Codex terminal arguments"
)
assert(vim.wait(5000, function()
  return buffer_contains(codex_buf, "80")
end), "fake Codex initial output did not arrive")
vim.cmd("stopinsert")
toggle.callback()
assert_equal(vim.api.nvim_get_current_buf(), editor_buf, "Codex toggle should restore the previous buffer")
assert_equal(vim.fn.jobwait({ job_id }, 0)[1], -1, "hiding Codex should preserve its process")
toggle.callback()
assert(vim.wait(1000, function()
  return vim.api.nvim_get_current_buf() == codex_buf
end), "Codex toggle should restore the existing terminal buffer")
assert_equal(vim.b[codex_buf].terminal_job_id, job_id, "Codex toggle should reuse the same process")
drawer_win = vim.api.nvim_get_current_win()
local latest_output = vim.fn.maparg("G", "n", false, true)
assert_equal(latest_output.buffer, 1, "agent G should be buffer-local")
assert(type(latest_output.callback) == "function", "agent G mapping is missing")
latest_output.callback()
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = codex_buf, modeline = false })
assert(
  vim.api.nvim_win_call(drawer_win, function()
    return vim.fn.line("w$")
  end) >= vim.api.nvim_buf_line_count(codex_buf),
  "G should place the agent view at the latest output before locking"
)
vim.api.nvim_win_set_cursor(drawer_win, { 20, 0 })
vim.api.nvim_win_call(drawer_win, function()
  vim.cmd("normal! zt")
end)
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = codex_buf, modeline = false })
vim.api.nvim_exec_autocmds("WinScrolled", { buffer = codex_buf, modeline = false })
local reading_view = vim.api.nvim_win_call(drawer_win, vim.fn.winsaveview)
assert(
  vim.api.nvim_win_call(drawer_win, function()
    return vim.fn.line("w$")
  end) < vim.api.nvim_buf_line_count(codex_buf),
  "scroll-lock fixture must stay above the latest output"
)
vim.api.nvim_chan_send(job_id, "finish\n")
assert(vim.wait(2000, function()
  if not buffer_contains(codex_buf, "final-output") then
    return false
  end
  local view = vim.api.nvim_win_call(drawer_win, vim.fn.winsaveview)
  return view.lnum == reading_view.lnum and view.topline == reading_view.topline
end), "final Codex output moved the terminal-normal reading position")
local final_view = vim.api.nvim_win_call(drawer_win, vim.fn.winsaveview)
assert_equal(final_view.lnum, reading_view.lnum, "Codex output should preserve the reading cursor")
assert_equal(final_view.topline, reading_view.topline, "Codex output should preserve the reading topline")
latest_output.callback()
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = codex_buf, modeline = false })
vim.api.nvim_chan_send(job_id, "after-unlock\n")
local resumed_following = vim.wait(2000, function()
  return buffer_contains(codex_buf, "after-unlock")
    and vim.api.nvim_win_call(drawer_win, function()
      return vim.fn.line("w$")
    end) >= vim.api.nvim_buf_line_count(codex_buf)
end)
if not resumed_following then
  error("G should unlock the agent view and resume following output: " .. vim.inspect({
    line_count = vim.api.nvim_buf_line_count(codex_buf),
    last_visible = vim.api.nvim_win_call(drawer_win, function()
      return vim.fn.line("w$")
    end),
    view = vim.api.nvim_win_call(drawer_win, vim.fn.winsaveview),
  }))
end
vim.fn.jobstop(job_id)
local job_status = vim.fn.jobwait({ job_id }, 1000)[1]
assert(job_status ~= -1, "fake Codex should stop cleanly")
vim.bo[codex_buf].modifiable = true
vim.cmd.lcd(fake_bin)

local transcript = {
  "Codex welcome",
  "› first prompt",
  "",
  "• first response",
  "  response detail",
  "• Ran a tool inside the first response",
  "  tool output",
  "› second prompt",
  "  wrapped prompt text",
  "",
  "• second response",
  "  more response text",
  "› current empty composer",
}
vim.api.nvim_buf_set_lines(codex_buf, 0, -1, false, transcript)
vim.api.nvim_win_set_cursor(drawer_win, { #transcript, 0 })
local previous_response = vim.fn.maparg("[a", "n", false, true)
local next_response = vim.fn.maparg("]a", "n", false, true)
assert_equal(previous_response.buffer, 1, "[a should be buffer-local")
assert_equal(next_response.buffer, 1, "]a should be buffer-local")
assert(type(previous_response.callback) == "function", "[a callback is missing")
assert(type(next_response.callback) == "function", "]a callback is missing")
previous_response.callback()
assert_equal(vim.api.nvim_win_get_cursor(drawer_win), { 11, 0 }, "[a should find the current response")
previous_response.callback()
assert_equal(vim.api.nvim_win_get_cursor(drawer_win), { 4, 0 }, "[a should skip tool bullets")
next_response.callback()
assert_equal(vim.api.nvim_win_get_cursor(drawer_win), { 11, 0 }, "]a should find the next response")
vim.api.nvim_win_set_cursor(drawer_win, { 1, 0 })
local counted_jump = vim.api.nvim_replace_termcodes("2]a", true, false, true)
vim.api.nvim_feedkeys(counted_jump, "mx", false)
assert(vim.wait(1000, function()
  return vim.api.nvim_win_get_cursor(drawer_win)[1] == 11
end), "2]a should jump across two responses")

vim.api.nvim_set_current_win(drawer_win)
vim.cmd("rightbelow new")
editor_win = vim.api.nvim_get_current_win()
vim.api.nvim_cmd({ cmd = "edit", args = { vim.fs.joinpath(root, "README.md") } }, {})
assert_equal(vim.api.nvim_win_get_buf(drawer_win), codex_buf, "Codex should behave as a normal split buffer")

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
  assert_equal(vim.api.nvim_win_get_buf(drawer_win), codex_buf, "Codex terminal should stay open")
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
print("full Codex terminal integration: ok")
vim.cmd("qa!")
