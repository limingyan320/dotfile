local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(("%s: expected %s, got %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function mapping(lhs, mode)
  local value = vim.fn.maparg(lhs, mode or "n", false, true)
  assert(type(value.callback) == "function", lhs .. " mapping is missing")
  return value.callback
end

local function window_for_buffer_in_current_tab(bufnr)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" and vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

local function ordinary_windows(drawer_buf)
  local windows = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if
      vim.api.nvim_win_get_config(win).relative == ""
      and vim.api.nvim_win_get_buf(win) ~= drawer_buf
    then
      windows[#windows + 1] = win
    end
  end
  return windows
end

local function assert_drawer(drawer_buf, expected_height, message)
  local drawer_win
  assert(vim.wait(1000, function()
    drawer_win = window_for_buffer_in_current_tab(drawer_buf)
    if not drawer_win then
      return false
    end
    local layout = vim.fn.winlayout()
    if layout[1] ~= "col" or #layout[2] < 2 then
      return false
    end
    local bottom = layout[2][#layout[2]]
    return vim.deep_equal(bottom, { "leaf", drawer_win })
      and vim.api.nvim_win_get_width(drawer_win) == vim.o.columns
      and vim.api.nvim_win_get_height(drawer_win) == expected_height
  end), message .. " invariant was not restored")

  local layout = vim.fn.winlayout()
  assert_equal(layout[1], "col", message .. " root layout")
  local bottom = layout[2][#layout[2]]
  assert_equal(bottom, { "leaf", drawer_win }, message .. " bottom leaf")
  assert_equal(vim.api.nvim_win_get_width(drawer_win), vim.o.columns, message .. " full width")
  assert_equal(vim.api.nvim_win_get_height(drawer_win), expected_height, message .. " height")
  assert_equal(vim.wo[drawer_win].winfixheight, true, message .. " fixed height")
  return drawer_win
end

local function assert_job_running(bufnr, message)
  local job_id = vim.b[bufnr].terminal_job_id
  assert(type(job_id) == "number", message .. " job id")
  assert_equal(vim.fn.jobwait({ job_id }, 0), { -1 }, message .. " running job")
  return job_id
end

-- Directional split helpers keep their existing left/up and right/down semantics.
vim.cmd("tabnew")
local left_win = vim.api.nvim_get_current_win()
mapping("<C-W>V")()
local right_win = vim.api.nvim_get_current_win()
assert(right_win ~= left_win, "<C-w>V should focus the new window")
assert(
  vim.api.nvim_win_get_position(right_win)[2] > vim.api.nvim_win_get_position(left_win)[2],
  "<C-w>V should create the new window on the right"
)
local top_win = right_win
mapping("<C-W>S")()
local bottom_win = vim.api.nvim_get_current_win()
assert(bottom_win ~= top_win, "<C-w>S should focus the new window")
assert(
  vim.api.nvim_win_get_position(bottom_win)[1] > vim.api.nvim_win_get_position(top_win)[1],
  "<C-w>S should create the new window below"
)
vim.cmd("tabclose!")

vim.cmd("enew")
vim.cmd("vsplit")
vim.cmd("enew")
local shell_toggle = mapping("<C-_>")
shell_toggle()
assert(vim.wait(1000, function()
  return vim.bo.buftype == "terminal"
end), "shell drawer did not open")
vim.cmd("stopinsert")

local drawer_buf = vim.api.nvim_get_current_buf()
local drawer_job = assert_job_running(drawer_buf, "initial drawer")
local drawer_height = 12
local drawer_win = assert_drawer(drawer_buf, drawer_height, "initial drawer")
assert_equal(vim.bo[drawer_buf].buflisted, false, "drawer should remain unlisted")
assert_equal(vim.fn.maparg("<M-0>", "n"), "", "drawer height reset mapping should be removed")

local notifications = {}
local original_notify = vim.notify
vim.notify = function(message)
  notifications[#notifications + 1] = tostring(message)
end

-- Window-layout mappings are blacklisted while focus is inside the drawer.
for _, key in ipairs({ "H", "J", "K", "L", "r", "R", "x", "T", "=", "+", "-", "v", "s", "V", "S", "c", "q", "o" }) do
  drawer_win = assert_drawer(drawer_buf, drawer_height, "before drawer <C-w>" .. key)
  vim.api.nvim_set_current_win(drawer_win)
  local before_windows = #vim.api.nvim_tabpage_list_wins(0)
  mapping("<C-W>" .. key)()
  assert_equal(#vim.api.nvim_tabpage_list_wins(0), before_windows, "drawer <C-w>" .. key .. " window count")
  assert_drawer(drawer_buf, drawer_height, "after drawer <C-w>" .. key)
  assert(
    notifications[#notifications]:find("不参与窗口布局操作", 1, true),
    "drawer <C-w>" .. key .. " should explain the blacklist"
  )
end

-- Height is controlled only by Option +/- and is independent from <C-w> resizing.
drawer_win = assert_drawer(drawer_buf, drawer_height, "before option resize")
vim.api.nvim_set_current_win(drawer_win)
mapping("<M-=>")()
drawer_height = drawer_height + 2
assert_drawer(drawer_buf, drawer_height, "after option increase")
mapping("<M-->")()
drawer_height = drawer_height - 2
assert_drawer(drawer_buf, drawer_height, "after option decrease")

-- Editor-side layout commands may freely rearrange editors but never include the drawer.
for _, key in ipairs({ "H", "J", "K", "L", "r", "R", "x", "=" }) do
  local editors = ordinary_windows(drawer_buf)
  assert(#editors >= 2, "layout test requires two ordinary windows")
  vim.api.nvim_set_current_win(editors[1])
  mapping("<C-W>" .. key)()
  assert_drawer(drawer_buf, drawer_height, "editor <C-w>" .. key)
  assert_job_running(drawer_buf, "editor <C-w>" .. key)
end

for _, key in ipairs({ "v", "s", "V", "S" }) do
  local editor = ordinary_windows(drawer_buf)[1]
  vim.api.nvim_set_current_win(editor)
  local before = #ordinary_windows(drawer_buf)
  mapping("<C-W>" .. key)()
  assert_equal(#ordinary_windows(drawer_buf), before + 1, "editor <C-w>" .. key .. " split count")
  assert_drawer(drawer_buf, drawer_height, "editor split <C-w>" .. key)
end

local editors = ordinary_windows(drawer_buf)
vim.api.nvim_set_current_win(editors[1])
mapping("<C-W>c")()
assert_equal(#ordinary_windows(drawer_buf), #editors - 1, "editor <C-w>c should close an ordinary window")
assert_drawer(drawer_buf, drawer_height, "after editor close")

editors = ordinary_windows(drawer_buf)
vim.api.nvim_set_current_win(editors[1])
mapping("<C-W>o")()
assert_equal(#ordinary_windows(drawer_buf), 1, "editor <C-w>o should keep one ordinary window")
assert_drawer(drawer_buf, drawer_height, "after editor only")

-- Ex commands and plugins can bypass mappings; the guardian repairs those mutations.
drawer_win = assert_drawer(drawer_buf, drawer_height, "before direct move")
vim.api.nvim_set_current_win(drawer_win)
vim.cmd("wincmd H")
assert_drawer(drawer_buf, drawer_height, "after direct move")

drawer_win = assert_drawer(drawer_buf, drawer_height, "before direct resize")
vim.api.nvim_set_current_win(drawer_win)
vim.fn.feedkeys(":resize 5\r", "xt")
assert_drawer(drawer_buf, drawer_height, "after direct resize")

drawer_win = assert_drawer(drawer_buf, drawer_height, "before buffer replacement")
vim.api.nvim_set_current_win(drawer_win)
vim.cmd("enew")
assert_drawer(drawer_buf, drawer_height, "after buffer replacement")

drawer_win = assert_drawer(drawer_buf, drawer_height, "before direct close")
vim.api.nvim_set_current_win(drawer_win)
vim.cmd("close")
assert_drawer(drawer_buf, drawer_height, "after direct close")
assert_job_running(drawer_buf, "after direct close")

local editor = ordinary_windows(drawer_buf)[1]
vim.api.nvim_set_current_win(editor)
vim.cmd("only")
assert_drawer(drawer_buf, drawer_height, "after direct only")

-- Tabs and zoom receive the same logical drawer, while the process remains unique.
local original_tab = vim.api.nvim_get_current_tabpage()
vim.cmd("tabnew")
assert_drawer(drawer_buf, drawer_height, "drawer in new tab")
assert_equal(#vim.fn.win_findbuf(drawer_buf), 1, "drawer should have one view across tabs")
assert_job_running(drawer_buf, "drawer in new tab")
vim.cmd("tabclose!")
assert_equal(vim.api.nvim_get_current_tabpage(), original_tab, "tabclose should return to original tab")
assert_drawer(drawer_buf, drawer_height, "drawer after tabclose")

editor = ordinary_windows(drawer_buf)[1]
vim.api.nvim_set_current_win(editor)
mapping("<C-W>V")()
local tabs_before_zoom = #vim.api.nvim_list_tabpages()
local zoom = mapping("<leader>z")
zoom()
assert(vim.wait(1000, function()
  return #vim.api.nvim_list_tabpages() == tabs_before_zoom + 1
end), "zoom should open a temporary tab")
assert_drawer(drawer_buf, drawer_height, "drawer in zoom tab")
assert_job_running(drawer_buf, "drawer in zoom tab")
zoom()
assert(vim.wait(1000, function()
  return #vim.api.nvim_list_tabpages() == tabs_before_zoom
end), "second zoom should restore the original tab")
assert_drawer(drawer_buf, drawer_height, "drawer after zoom restore")

-- <leader>t terminals are ordinary session windows, not protected drawer views.
editor = ordinary_windows(drawer_buf)[1]
vim.api.nvim_set_current_win(editor)
local full_terminal = mapping("<leader>t")
full_terminal()
assert(vim.wait(1000, function()
  return vim.bo.buftype == "terminal" and vim.api.nvim_get_current_buf() ~= drawer_buf
end), "full terminal did not open")
vim.cmd("stopinsert")
local full_win = vim.api.nvim_get_current_win()
local full_buf = vim.api.nvim_get_current_buf()
local full_job = assert_job_running(full_buf, "full terminal")
assert_equal(vim.bo[full_buf].buflisted, true, "full terminal should be listed")
assert_drawer(drawer_buf, drawer_height, "drawer beside full terminal")

local focus_editor = mapping("<C-S-Del>")
focus_editor()
assert(vim.api.nvim_get_current_win() ~= full_win, "Caps+N should leave a full terminal")
vim.api.nvim_set_current_win(full_win)
mapping("<C-W>H")()
assert(vim.api.nvim_win_is_valid(full_win), "full terminal should participate in window movement")
assert_equal(vim.api.nvim_win_get_buf(full_win), full_buf, "full terminal buffer after movement")
assert_drawer(drawer_buf, drawer_height, "drawer after full terminal movement")

vim.api.nvim_set_current_win(full_win)
mapping("<C-W>c")()
assert(not vim.api.nvim_win_is_valid(full_win), "full terminal window should close like an ordinary window")
assert(vim.api.nvim_buf_is_valid(full_buf), "closing a full terminal window should preserve its listed buffer")
assert_drawer(drawer_buf, drawer_height, "drawer after full terminal close")

-- Only the explicit toggle changes the drawer's logical visibility.
drawer_win = assert_drawer(drawer_buf, drawer_height, "before intentional hide")
vim.api.nvim_set_current_win(drawer_win)
shell_toggle()
assert(vim.wait(1000, function()
  return window_for_buffer_in_current_tab(drawer_buf) == nil
end), "Ctrl+/ should hide the drawer")
assert_job_running(drawer_buf, "hidden drawer")

shell_toggle()
assert_drawer(drawer_buf, drawer_height, "after intentional show")
assert_job_running(drawer_buf, "shown drawer")

vim.notify = original_notify
pcall(vim.fn.jobstop, full_job)
pcall(vim.fn.jobstop, drawer_job)
print("drawer protection integration: ok")
vim.cmd("qa!")
