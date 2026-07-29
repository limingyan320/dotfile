local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(("%s: expected %s, got %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

vim.opt.swapfile = false

local function assert_true(value, message)
  if not value then
    error(message)
  end
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

local picker = require("dotfiles.buffer_picker")

local function wait_for_picker(message)
  assert_true(
    vim.wait(800, function()
      local state = picker._active_state()
      return state
        and state.prompt_bufnr
        and vim.api.nvim_buf_is_valid(state.prompt_bufnr)
        and state.picker
        and state.picker.manager
    end),
    message or "buffer picker did not open"
  )
  return picker._active_state()
end

local function wait_for_closed(message)
  assert_true(
    vim.wait(800, function()
      return picker._active_state() == nil
    end),
    message or "buffer picker did not close"
  )
end

local function close_picker()
  if picker._active_state() then
    feed("q")
    wait_for_closed()
  end
end

local function listed_buffer(name, lines)
  local bufnr = vim.api.nvim_create_buf(true, false)
  if name then
    vim.api.nvim_buf_set_name(bufnr, name)
  end
  if lines then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modified = false
  end
  return bufnr
end

local function picker_bufnrs(state)
  local bufnrs = {}
  for index = 1, state.picker.manager:num_results() do
    local entry = state.picker.manager:get_entry(index)
    bufnrs[#bufnrs + 1] = entry.bufnr
  end
  return bufnrs
end

local function select_picker_buffer(bufnr)
  local state = picker._active_state()
  for _ = 1, state.picker.manager:num_results() do
    local selected = require("telescope.actions.state").get_selected_entry()
    if selected and selected.bufnr == bufnr then
      return
    end
    feed("j")
    vim.wait(30)
  end
  error("buffer " .. bufnr .. " is not selectable in the picker")
end

local function float_inside_window(float, host)
  local host_position = vim.api.nvim_win_get_position(host)
  local host_height = vim.api.nvim_win_get_height(host)
  local host_width = vim.api.nvim_win_get_width(host)
  local config = vim.api.nvim_win_get_config(float)
  local row = math.floor(config.row)
  local col = math.floor(config.col)
  return config.relative == "editor"
    and row >= host_position[1]
    and row + config.height <= host_position[1] + host_height
    and col >= host_position[2]
    and col + config.width <= host_position[2] + host_width
end

local function assert_picker_inside_target(state, message)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      assert_true(
        float_inside_window(win, state.target_win),
        (message or "picker escaped target window") .. ": " .. win
      )
    end
  end
end

local terminal_jobs = {}
local function start_terminal(command)
  local bufnr = vim.api.nvim_get_current_buf()
  local job = vim.fn.termopen({ vim.o.shell, "-c", command or "sleep 30" })
  terminal_jobs[#terminal_jobs + 1] = job
  return bufnr, job
end

local function stop_terminals()
  for _, job in ipairs(terminal_jobs) do
    pcall(vim.fn.jobstop, job)
  end
end

-- Real drawer integration: opening from its terminal must route to the editor,
-- keep every Telescope float inside that editor, and restore the drawer on q.
vim.cmd("tabnew")
local preview_first_path = vim.fn.tempname()
local preview_second_path = vim.fn.tempname()
assert_equal(vim.fn.writefile({ "first preview marker" }, preview_first_path), 0, "first preview fixture")
assert_equal(vim.fn.writefile({ "second preview marker" }, preview_second_path), 0, "second preview fixture")
vim.cmd("edit " .. vim.fn.fnameescape(preview_first_path))
local editor_win = vim.api.nvim_get_current_win()
local preview_second = listed_buffer(preview_second_path, { "second preview marker" })
local shell_toggle = vim.fn.maparg("<C-_>", "n", false, true)
assert_true(type(shell_toggle.callback) == "function", "shell drawer mapping is missing")
shell_toggle.callback()
assert_true(
  vim.wait(800, function()
    return vim.bo.buftype == "terminal" and vim.api.nvim_get_current_win() ~= editor_win
  end),
  "shell drawer did not open"
)
local drawer_win = vim.api.nvim_get_current_win()
local drawer_buf = vim.api.nvim_get_current_buf()
local drawer_height = vim.api.nvim_win_get_height(drawer_win)
terminal_jobs[#terminal_jobs + 1] = vim.b.terminal_job_id
vim.bo[drawer_buf].buflisted = true -- prove listed terminals are still filtered
vim.cmd("stopinsert")
vim.wait(50)

picker.open()
local state = wait_for_picker("picker did not route out of the drawer")
assert_equal(state.source_win, drawer_win, "drawer source window")
assert_equal(state.target_win, editor_win, "drawer editor target")
assert_equal(vim.api.nvim_win_get_buf(drawer_win), drawer_buf, "drawer buffer while picker is open")
assert_equal(vim.api.nvim_win_get_height(drawer_win), drawer_height, "drawer height while picker is open")
assert_true(not vim.tbl_contains(picker_bufnrs(state), drawer_buf), "drawer terminal leaked into buffer entries")
assert_picker_inside_target(state, "picker visually overlaps the drawer")

local first_selection = require("telescope.actions.state").get_selected_entry()
feed("j")
assert_true(
  vim.wait(400, function()
    local selected = require("telescope.actions.state").get_selected_entry()
    return selected and first_selection and selected.bufnr ~= first_selection.bufnr
  end),
  "j did not move the buffer selection"
)
local selected = require("telescope.actions.state").get_selected_entry()
assert_true(selected.bufnr == preview_second or selected.bufnr ~= drawer_buf, "j selected a protected terminal")
assert_true(
  vim.wait(400, function()
    local preview_win = state.picker.preview_win
    if not preview_win or not vim.api.nvim_win_is_valid(preview_win) then
      return false
    end
    local preview_buf = vim.api.nvim_win_get_buf(preview_win)
    return table.concat(vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false), "\n"):find("preview", 1, true) ~= nil
  end),
  "j did not refresh the live preview"
)
feed("k")
assert_true(
  vim.wait(400, function()
    local current = require("telescope.actions.state").get_selected_entry()
    return current and first_selection and current.bufnr == first_selection.bufnr
  end),
  "k did not restore the previous buffer selection"
)

feed("q")
wait_for_closed("q did not close the drawer-launched picker")
assert_equal(vim.api.nvim_get_current_win(), drawer_win, "q should restore the drawer source")
assert_equal(vim.api.nvim_win_get_buf(drawer_win), drawer_buf, "q should preserve drawer content")
assert_equal(vim.api.nvim_win_get_height(drawer_win), drawer_height, "q should preserve drawer height")
shell_toggle.callback()
assert_true(
  vim.wait(500, function()
    return vim.api.nvim_get_current_win() == editor_win and not vim.api.nvim_win_is_valid(drawer_win)
  end),
  "shell drawer did not hide after the picker test"
)

-- A full terminal opened with <leader>t is a first-class session buffer: the
-- picker uses its window directly, lists it, and switches in both directions.
vim.cmd("tabnew")
local only_target = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(only_target, "/tmp/dotfiles-buffer-picker-only-target")
vim.api.nvim_buf_set_lines(only_target, 0, -1, false, { "only target" })
vim.bo[only_target].modified = false
local full_terminal = vim.fn.maparg("<Space>t", "n", false, true)
assert_true(type(full_terminal.callback) == "function", "<leader>t mapping is missing")
full_terminal.callback()
assert_true(
  vim.wait(800, function()
    return vim.bo.buftype == "terminal"
  end),
  "<leader>t did not open a full terminal"
)
local only_terminal_buf = vim.api.nvim_get_current_buf()
local only_terminal_win = vim.api.nvim_get_current_win()
terminal_jobs[#terminal_jobs + 1] = vim.b.terminal_job_id
vim.cmd("stopinsert")
picker.open()
state = wait_for_picker("full-terminal picker did not open")
assert_equal(state.target_win, only_terminal_win, "full terminal should host the picker")
assert_true(vim.tbl_contains(picker_bufnrs(state), only_terminal_buf), "full terminal missing from picker")
assert_picker_inside_target(state, "full-terminal picker escaped its source window")
select_picker_buffer(only_target)
feed("<CR>")
wait_for_closed("Enter did not close the full-terminal picker")
assert_equal(vim.api.nvim_get_current_win(), only_terminal_win, "normal buffer reused full-terminal window")
assert_equal(vim.api.nvim_win_get_buf(only_terminal_win), only_target, "normal buffer selection")
assert_true(vim.api.nvim_buf_is_valid(only_terminal_buf), "switching away deleted the full terminal")

picker.open()
state = wait_for_picker()
select_picker_buffer(only_terminal_buf)
feed("<CR>")
wait_for_closed("Enter did not switch back to the full terminal")
assert_equal(vim.api.nvim_get_current_win(), only_terminal_win, "full-terminal selection focus")
assert_equal(vim.api.nvim_win_get_buf(only_terminal_win), only_terminal_buf, "full-terminal selection")
vim.cmd("stopinsert")

picker.open()
wait_for_picker()
select_picker_buffer(only_terminal_buf)
feed("dd")
assert_true(
  vim.wait(800, function()
    return vim.bo.filetype == "DressingSelect"
  end),
  "terminal close confirmation did not open"
)
local terminal_select_win = vim.api.nvim_get_current_win()
local terminal_select_config = vim.api.nvim_win_get_config(terminal_select_win)
assert_equal(vim.api.nvim_get_current_line(), "Cancel", "terminal confirmation default choice")
assert_equal(terminal_select_config.relative, "win", "terminal confirmation relativity")
assert_equal(terminal_select_config.win, only_terminal_win, "terminal confirmation parent")
feed("<Esc>")
wait_for_picker("cancel did not reopen the terminal buffer picker")
assert_true(vim.api.nvim_buf_is_valid(only_terminal_buf), "Cancel closed the terminal buffer")
close_picker()

local saved_terminal_select = vim.ui.select
local terminal_delete_choice
vim.ui.select = function(items, opts, callback)
  assert_equal(items, { "Cancel", "Close terminal" }, "terminal delete choices")
  assert_equal(opts.kind, "dotfiles_terminal_buffer_delete", "terminal delete choice kind")
  terminal_delete_choice = callback
end
picker.open()
wait_for_picker()
select_picker_buffer(only_terminal_buf)
feed("dd")
assert_true(
  vim.wait(400, function()
    return terminal_delete_choice ~= nil
  end),
  "terminal close confirmation callback missing"
)
terminal_delete_choice("Close terminal")
assert_true(
  vim.wait(800, function()
    return not vim.api.nvim_buf_is_valid(only_terminal_buf)
  end),
  "confirmed terminal close did not delete the buffer"
)
wait_for_picker("picker did not reopen after closing the terminal")
close_picker()
vim.ui.select = saved_terminal_select

-- Clean deletion is immediate and leaves the picker open on a safe buffer.
vim.cmd("tabnew")
local clean_delete = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(clean_delete, "/tmp/dotfiles-buffer-picker-clean-delete")
vim.api.nvim_buf_set_lines(clean_delete, 0, -1, false, { "clean delete" })
vim.bo[clean_delete].modified = false
local clean_keep = listed_buffer("/tmp/dotfiles-buffer-picker-clean-keep", { "keep" })
local clean_win = vim.api.nvim_get_current_win()
picker.open()
state = wait_for_picker()
feed("dd")
assert_true(
  vim.wait(800, function()
    return not vim.api.nvim_buf_is_valid(clean_delete)
  end),
  "dd did not delete a clean buffer"
)
state = wait_for_picker("picker closed after clean deletion")
assert_true(vim.api.nvim_buf_is_valid(clean_keep), "clean deletion removed the wrong buffer")
assert_equal(vim.bo[vim.api.nvim_win_get_buf(clean_win)].buftype, "", "clean deletion made the host a terminal")
close_picker()

-- The real Dressing confirmation starts on Cancel and remains relative to the
-- safe editor. Esc cancels and reopens the same picker.
vim.cmd("tabnew")
local dirty_cancel = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(dirty_cancel, "/tmp/dotfiles-buffer-picker-dirty-cancel")
vim.api.nvim_buf_set_lines(dirty_cancel, 0, -1, false, { "dirty cancel" })
local dirty_cancel_win = vim.api.nvim_get_current_win()
picker.open()
wait_for_picker()
feed("dd")
assert_true(
  vim.wait(800, function()
    return vim.bo.filetype == "DressingSelect"
  end),
  "modified buffer confirmation did not open"
)
local select_win = vim.api.nvim_get_current_win()
local select_config = vim.api.nvim_win_get_config(select_win)
assert_equal(vim.api.nvim_get_current_line(), "Cancel", "modified confirmation default choice")
assert_equal(vim.api.nvim_win_get_cursor(select_win)[1], 1, "modified confirmation cursor")
assert_equal(select_config.relative, "win", "modified confirmation relativity")
assert_equal(select_config.win, dirty_cancel_win, "modified confirmation parent")
feed("<Esc>")
state = wait_for_picker("cancel did not reopen the modified buffer picker")
assert_true(vim.api.nvim_buf_is_valid(dirty_cancel), "Cancel deleted the modified buffer")
assert_true(vim.bo[dirty_cancel].modified, "Cancel cleared the modified state")
close_picker()

local original_select = vim.ui.select
local original_input = vim.ui.input
local pending_choice
vim.ui.select = function(items, opts, callback)
  assert_equal(items, picker._delete_choices(), "modified delete choices")
  assert_equal(opts.kind, "dotfiles_buffer_delete", "modified delete choice kind")
  pending_choice = callback
end

-- Save-and-delete writes the current contents before removing a named buffer.
vim.cmd("tabnew")
local saved_path = vim.fn.tempname()
local dirty_save = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(dirty_save, saved_path)
vim.api.nvim_buf_set_lines(dirty_save, 0, -1, false, { "saved before delete" })
picker.open()
wait_for_picker()
feed("dd")
assert_true(
  vim.wait(400, function()
    return pending_choice ~= nil
  end),
  "save confirmation callback missing"
)
local choose = pending_choice
pending_choice = nil
choose("Save and delete")
assert_true(
  vim.wait(800, function()
    return not vim.api.nvim_buf_is_valid(dirty_save)
  end),
  "save-and-delete did not remove the buffer"
)
assert_equal(vim.fn.readfile(saved_path), { "saved before delete" }, "save-and-delete file contents")
wait_for_picker("picker did not reopen after save-and-delete")
close_picker()
vim.fn.delete(saved_path)

-- Discard-and-delete is the only force path.
vim.cmd("tabnew")
local dirty_discard = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(dirty_discard, "/tmp/dotfiles-buffer-picker-dirty-discard")
vim.api.nvim_buf_set_lines(dirty_discard, 0, -1, false, { "discard me" })
picker.open()
wait_for_picker()
feed("dd")
assert_true(
  vim.wait(400, function()
    return pending_choice ~= nil
  end),
  "discard confirmation callback missing"
)
choose = pending_choice
pending_choice = nil
choose("Discard changes and delete")
assert_true(
  vim.wait(800, function()
    return not vim.api.nvim_buf_is_valid(dirty_discard)
  end),
  "discard-and-delete did not remove the buffer"
)
wait_for_picker("picker did not reopen after discard-and-delete")
close_picker()

-- Unnamed save uses a file input before deletion.
vim.cmd("tabnew")
local dirty_unnamed = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(dirty_unnamed, 0, -1, false, { "unnamed saved value" })
local pending_input
vim.ui.input = function(opts, callback)
  assert_equal(opts.kind, "dotfiles_buffer_save_as", "unnamed save input kind")
  pending_input = callback
end
picker.open()
wait_for_picker()
feed("dd")
assert_true(
  vim.wait(400, function()
    return pending_choice ~= nil
  end),
  "unnamed confirmation callback missing"
)
choose = pending_choice
pending_choice = nil
choose("Save and delete")
assert_true(
  vim.wait(400, function()
    return pending_input ~= nil
  end),
  "unnamed save input missing"
)
local unnamed_path = vim.fn.tempname()
pending_input(unnamed_path)
assert_true(
  vim.wait(800, function()
    return not vim.api.nvim_buf_is_valid(dirty_unnamed)
  end),
  "unnamed save-and-delete did not remove the buffer"
)
assert_equal(vim.fn.readfile(unnamed_path), { "unnamed saved value" }, "unnamed save contents")
wait_for_picker("picker did not reopen after unnamed save")
close_picker()
vim.fn.delete(unnamed_path)
vim.ui.select = original_select
vim.ui.input = original_input

-- Closing the host while Telescope is open rehomes the picker onto a surviving
-- full terminal, which is a valid session-buffer target.
vim.cmd("tabnew")
vim.cmd("file /tmp/dotfiles-buffer-picker-invalid-target")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "invalid target selection" })
vim.bo.modified = false
local invalid_target_buf = vim.api.nvim_get_current_buf()
local invalid_target_win = vim.api.nvim_get_current_win()
vim.cmd("botright 8new")
local invalid_terminal_buf = vim.api.nvim_get_current_buf()
local invalid_terminal_win = vim.api.nvim_get_current_win()
start_terminal()
vim.api.nvim_set_current_win(invalid_target_win)
picker.open()
wait_for_picker()
vim.api.nvim_win_close(invalid_target_win, true)
state = wait_for_picker("picker did not recover from an invalid target window")
assert_true(state.target_win ~= invalid_target_win, "picker reused the closed target")
assert_equal(state.target_win, invalid_terminal_win, "invalid target did not reuse the full terminal")
assert_equal(vim.bo[vim.api.nvim_win_get_buf(state.target_win)].buftype, "terminal", "invalid target fallback type")
assert_picker_inside_target(state, "reopened picker escaped its replacement editor")
local recovered_target = state.target_win
feed("<CR>")
wait_for_closed("Enter did not close the recovered picker")
assert_equal(vim.api.nvim_get_current_win(), recovered_target, "recovered Enter target")
assert_equal(vim.api.nvim_win_get_buf(recovered_target), invalid_target_buf, "recovered Enter selection")
assert_true(vim.api.nvim_buf_is_valid(invalid_terminal_buf), "recovered Enter deleted the full terminal")

-- A target that changes into the protected drawer buffer is invalid even though
-- ordinary full terminals are valid, so the picker moves to another safe window.
vim.cmd("tabnew")
vim.cmd("file /tmp/dotfiles-buffer-picker-terminalized-target")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "terminalized target selection" })
vim.bo.modified = false
local terminalized_target_buf = vim.api.nvim_get_current_buf()
local terminalized_target_win = vim.api.nvim_get_current_win()
vim.cmd("botright 8new")
local watched_terminal_buf = vim.api.nvim_get_current_buf()
local watched_terminal_win = vim.api.nvim_get_current_win()
start_terminal()
vim.api.nvim_set_current_win(terminalized_target_win)
picker.open()
wait_for_picker()
vim.api.nvim_win_set_buf(terminalized_target_win, drawer_buf)
state = wait_for_picker("picker did not leave a target that became the drawer")
assert_true(state.target_win ~= terminalized_target_win, "picker stayed over a protected drawer")
assert_equal(state.target_win, watched_terminal_win, "drawer rehome did not reuse the full terminal")
assert_equal(vim.bo[vim.api.nvim_win_get_buf(state.target_win)].buftype, "terminal", "drawer target fallback type")
assert_equal(
  vim.api.nvim_win_get_buf(terminalized_target_win),
  drawer_buf,
  "target rehome changed drawer content"
)
assert_picker_inside_target(state, "terminalized target picker escaped its replacement editor")
local terminalized_recovery_win = state.target_win
select_picker_buffer(terminalized_target_buf)
feed("<CR>")
wait_for_closed("Enter did not close the terminalized-target picker")
assert_equal(vim.api.nvim_get_current_win(), terminalized_recovery_win, "terminalized target Enter focus")
assert_equal(
  vim.api.nvim_win_get_buf(terminalized_recovery_win),
  terminalized_target_buf,
  "terminalized target selection"
)
assert_equal(
  vim.api.nvim_win_get_buf(terminalized_target_win),
  drawer_buf,
  "terminalized Enter replaced drawer"
)

-- Exact :ls<CR> and <leader>fb share the enhanced picker. Native variants and
-- aliases remain untouched.
vim.cmd("tabnew")
feed(":ls<CR>")
wait_for_picker(":ls did not open the enhanced buffer picker")
close_picker()

for _, command in ipairs({ ":ls!<CR>", ":ls +<CR>", ":buffers<CR>", ":files<CR>" }) do
  feed(command)
  vim.wait(80)
  assert_true(picker._active_state() == nil, command .. " was incorrectly redirected")
end

local leader_buffers = vim.fn.maparg("<Space>fb", "n", false, true)
assert_true(type(leader_buffers.callback) == "function", "<leader>fb mapping is missing")
leader_buffers.callback()
wait_for_picker("<leader>fb did not open the enhanced picker")
close_picker()

stop_terminals()
vim.fn.delete(preview_first_path)
vim.fn.delete(preview_second_path)
print("buffer picker integration: ok")
vim.cmd("qa!")
