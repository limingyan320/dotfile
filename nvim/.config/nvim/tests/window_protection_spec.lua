local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(("%s: expected %s, got %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function regular_window_count()
  local count = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      count = count + 1
    end
  end
  return count
end

vim.cmd("tabnew")
local left_win = vim.api.nvim_get_current_win()
local split_right = vim.fn.maparg("<C-W>V", "n", false, true)
local split_below = vim.fn.maparg("<C-W>S", "n", false, true)
assert(type(split_right.callback) == "function", "right split mapping is missing")
assert(type(split_below.callback) == "function", "below split mapping is missing")

split_right.callback()
local right_win = vim.api.nvim_get_current_win()
assert(right_win ~= left_win, "<C-w>V should focus the new window")
assert(
  vim.api.nvim_win_get_position(right_win)[2] > vim.api.nvim_win_get_position(left_win)[2],
  "<C-w>V should create the new window on the right"
)

local top_win = right_win
split_below.callback()
local bottom_win = vim.api.nvim_get_current_win()
assert(bottom_win ~= top_win, "<C-w>S should focus the new window")
assert(
  vim.api.nvim_win_get_position(bottom_win)[1] > vim.api.nvim_win_get_position(top_win)[1],
  "<C-w>S should create the new window below"
)
vim.cmd("tabclose!")

vim.cmd("enew")
local first_editor = vim.api.nvim_get_current_win()
vim.cmd("vsplit")
vim.cmd("enew")
local second_editor = vim.api.nvim_get_current_win()
vim.cmd("botright split")
vim.cmd("enew")
local terminal_win = vim.api.nvim_get_current_win()
local terminal_buf = vim.api.nvim_get_current_buf()
local terminal_job = vim.fn.termopen({ vim.o.shell, "-c", "sleep 30" })
assert_equal(vim.bo[terminal_buf].buftype, "terminal", "test terminal buftype")

local close_mapping = vim.fn.maparg("<C-W>c", "n", false, true)
local only_mapping = vim.fn.maparg("<C-W>o", "n", false, true)
assert(type(close_mapping.callback) == "function", "protected close mapping is missing")
assert(type(only_mapping.callback) == "function", "protected only mapping is missing")

local notifications = {}
local original_notify = vim.notify
vim.notify = function(message)
  notifications[#notifications + 1] = tostring(message)
end

close_mapping.callback()
assert(vim.api.nvim_win_is_valid(terminal_win), "<C-w>c should preserve a terminal window")
assert_equal(regular_window_count(), 3, "terminal close protection window count")
assert(notifications[#notifications]:find("不会被", 1, true), "terminal close protection notification")

vim.api.nvim_set_current_win(second_editor)
close_mapping.callback()
assert(not vim.api.nvim_win_is_valid(second_editor), "<C-w>c should close a normal editor window")
assert(vim.api.nvim_win_is_valid(first_editor), "normal close should preserve the other editor")
assert(vim.api.nvim_win_is_valid(terminal_win), "normal close should preserve the terminal")

vim.api.nvim_set_current_win(first_editor)
vim.cmd("vsplit")
vim.cmd("enew")
local kept_editor = vim.api.nvim_get_current_win()
vim.cmd("split")
vim.cmd("enew")
local discarded_editor = vim.api.nvim_get_current_win()
local float_buf = vim.api.nvim_create_buf(false, true)
local float_win = vim.api.nvim_open_win(float_buf, false, {
  relative = "editor",
  width = 12,
  height = 2,
  row = 1,
  col = 1,
  style = "minimal",
})

vim.api.nvim_set_current_win(kept_editor)
only_mapping.callback()
assert(vim.api.nvim_win_is_valid(kept_editor), "<C-w>o should preserve the current editor")
assert(not vim.api.nvim_win_is_valid(first_editor), "<C-w>o should close another editor")
assert(not vim.api.nvim_win_is_valid(discarded_editor), "<C-w>o should close every other editor")
assert(vim.api.nvim_win_is_valid(terminal_win), "<C-w>o should preserve terminal windows")
assert(vim.api.nvim_win_is_valid(float_win), "<C-w>o should ignore floating windows")
assert_equal(regular_window_count(), 2, "protected only should leave one editor and one terminal")

vim.api.nvim_set_current_win(float_win)
local before_float_only = regular_window_count()
only_mapping.callback()
assert_equal(regular_window_count(), before_float_only, "floating <C-w>o should be a no-op")
assert(vim.api.nvim_win_is_valid(float_win), "floating <C-w>o should preserve the current float")
close_mapping.callback()
assert(not vim.api.nvim_win_is_valid(float_win), "<C-w>c should still close a non-terminal float")

vim.api.nvim_set_current_win(kept_editor)
vim.cmd("vsplit")
vim.cmd("enew")
local extra_editor = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(terminal_win)
local before_terminal_only = regular_window_count()
only_mapping.callback()
assert_equal(regular_window_count(), before_terminal_only, "terminal <C-w>o should be a no-op")
assert(vim.api.nvim_win_is_valid(kept_editor), "terminal <C-w>o should preserve the first editor")
assert(vim.api.nvim_win_is_valid(extra_editor), "terminal <C-w>o should preserve the extra editor")
assert(notifications[#notifications]:find("普通编辑窗口", 1, true), "terminal only protection notification")

vim.notify = original_notify
pcall(vim.fn.jobstop, terminal_job)
print("window protection integration: ok")
vim.cmd("qa!")
