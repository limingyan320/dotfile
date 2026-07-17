local uv = vim.uv

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(("%s: expected %s, got %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local config_root = vim.fs.normalize(vim.fn.getcwd() .. "/nvim/.config/nvim")
package.path = table.concat({
  vim.fs.joinpath(config_root, "lua", "?.lua"),
  vim.fs.joinpath(config_root, "lua", "?", "init.lua"),
  package.path,
}, ";")

local dashboard = require("dotfiles.session_dashboard")
local notes_root = vim.fn.tempname()
local fake_session = {
  address = vim.fs.joinpath(notes_root, "nvim-1700000000-42-7.sock"),
  current = true,
  name = "dotfiles work",
  project = "dotfiles",
  cwd = vim.fn.getcwd(),
  current_buffer = "init.lua",
  modified_count = 0,
  terminal_count = 0,
  window_count = 1,
  tab_count = 1,
  ui_count = 1,
  last_active = os.time(),
  agent_state = { state = "idle", unread = false },
}
local second_session = vim.tbl_extend("force", vim.deepcopy(fake_session), {
  address = vim.fs.joinpath(notes_root, "nvim-1700000001-43-8.sock"),
  current = false,
  name = "second session",
  ui_count = 0,
})

local store = dashboard._new_store(notes_root)
assert_equal(store:session_id(fake_session), "nvim-1700000000-42-7", "managed session id")
assert_equal(store:session_id({ pid = 42 }), "process-42", "direct session fallback id")

local first_entry = assert(store:create_entry(fake_session))
assert(vim.fn.writefile({ "implemented dashboard", "more detail" }, first_entry.path, "b") == 0)
local entries = store:list_entries(fake_session)
assert_equal(#entries, 1, "stored entry count")
assert_equal(entries[1].preview, "implemented dashboard", "entry preview")
assert_equal(store:load_metadata(fake_session).name, "dotfiles work", "session metadata")

local sessions = { fake_session, second_session }
local stopped_current_session
dashboard.setup({
  notes_dir = notes_root,
  discover_sessions = function()
    return vim.deepcopy(sessions)
  end,
  normalize_name = function(value)
    return vim.trim(tostring(value or ""))
  end,
  read_agent_state = function()
    return { state = "idle", unread = false }
  end,
  connect_session = function() end,
  create_session = function() end,
  connect_created_session = function() end,
  rename_session = function()
    return true
  end,
  stop_session = function() end,
  stop_current_session = function(session)
    stopped_current_session = session
  end,
  clear_agent = function() end,
  autosave_delay = 20,
})

dashboard.open({ current_notes = true })
local state = assert(dashboard._active_dashboard())
assert(vim.api.nvim_win_is_valid(state.winid), "dashboard window should be valid")
assert_equal(vim.bo[state.bufnr].filetype, "dotfiles-session-dashboard", "dashboard filetype")
vim.api.nvim_exec_autocmds("VimResized", { buffer = state.bufnr, modeline = false })
local dashboard_text = table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
assert(dashboard_text:find("CURRENT", 1, true), "dashboard should show current session")
assert(dashboard_text:find("implemented dashboard", 1, true), "current timeline should start expanded")

vim.api.nvim_set_current_win(state.winid)
local initial_row = vim.api.nvim_win_get_cursor(state.winid)[1]
local next_mapping = vim.fn.maparg("j", "n", false, true)
assert(type(next_mapping.callback) == "function", "dashboard next mapping is missing")
next_mapping.callback()
local second_row = vim.api.nvim_win_get_cursor(state.winid)[1]
assert(second_row > initial_row, "j should move to the next actionable row")
assert_equal(state.line_map[second_row].session_id, store:session_id(second_session), "j selected session")

local refresh_mapping = vim.fn.maparg("R", "n", false, true)
refresh_mapping.callback()
local refreshed_row = vim.api.nvim_win_get_cursor(state.winid)[1]
assert_equal(state.line_map[refreshed_row].session_id, store:session_id(second_session), "refresh kept selection")

local previous_mapping = vim.fn.maparg("k", "n", false, true)
previous_mapping.callback()
assert(vim.api.nvim_win_get_cursor(state.winid)[1] < refreshed_row, "k should move to the previous actionable row")

local last_mapping = vim.fn.maparg("G", "n", false, true)
last_mapping.callback()
assert_equal(
  state.line_map[vim.api.nvim_win_get_cursor(state.winid)[1]].session_id,
  store:session_id(second_session),
  "G"
)
local first_mapping = vim.fn.maparg("gg", "n", false, true)
first_mapping.callback()
assert_equal(
  state.line_map[vim.api.nvim_win_get_cursor(state.winid)[1]].session_id,
  store:session_id(fake_session),
  "gg"
)

local add_mapping = vim.fn.maparg("a", "n", false, true)
assert(type(add_mapping.callback) == "function", "dashboard add mapping is missing")
add_mapping.callback()

local note = assert(state.note)
assert_equal(vim.bo[note.bufnr].filetype, "markdown", "note editor filetype")
vim.api.nvim_exec_autocmds("VimResized", { buffer = note.bufnr, modeline = false })
vim.api.nvim_buf_set_lines(note.bufnr, 0, -1, false, { "testing automatic save", "second line" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = note.bufnr, modeline = false })
assert(
  vim.wait(500, function()
    return vim.api.nvim_buf_is_valid(note.bufnr) and not vim.bo[note.bufnr].modified
  end),
  "note autosave did not finish"
)
local saved = assert(io.open(note.entry.path, "r"))
local saved_text = saved:read("*a")
saved:close()
assert(saved_text:find("testing automatic save", 1, true), "autosave should update the Markdown file")

vim.cmd("stopinsert")
vim.api.nvim_set_current_win(note.winid)
local close_note_mapping = vim.fn.maparg("q", "n", false, true)
assert(type(close_note_mapping.callback) == "function", "note close mapping is missing")
close_note_mapping.callback()
assert(state.note == nil, "note editor should close back to dashboard")

sessions = {}
vim.api.nvim_set_current_win(state.winid)
refresh_mapping = vim.fn.maparg("R", "n", false, true)
refresh_mapping.callback()
local archive_mapping = vim.fn.maparg("A", "n", false, true)
archive_mapping.callback()
dashboard_text = table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
assert(dashboard_text:find("Archived Sessions", 1, true), "archive section should be visible")
assert(dashboard_text:find("dotfiles work", 1, true), "archived session should retain its name")

entries = store:list_entries(fake_session)
assert_equal(#entries, 2, "entry count after dashboard add")
local deleted, delete_err = store:delete_entry(entries[2])
assert(deleted, delete_err)
assert_equal(#store:list_entries(fake_session), 1, "soft-deleted entry should leave the timeline")
local trash_scan = uv.fs_scandir(vim.fs.joinpath(notes_root, store:session_id(fake_session), "trash"))
assert(trash_scan and uv.fs_scandir_next(trash_scan), "soft-deleted entry should be retained in trash")

vim.api.nvim_set_current_win(state.winid)
local close_dashboard_mapping = vim.fn.maparg("q", "n", false, true)
close_dashboard_mapping.callback()
assert(dashboard._active_dashboard() == nil, "dashboard should close cleanly")

sessions = { fake_session, second_session }
dashboard.open()
state = assert(dashboard._active_dashboard())
vim.api.nvim_set_current_win(state.winid)
local delete_mapping = vim.fn.maparg("dd", "n", false, true)
assert(type(delete_mapping.callback) == "function", "dashboard delete mapping is missing")

local original_select = vim.ui.select
vim.ui.select = function(items, opts, callback)
  assert_equal(items[1], "Cancel", "current delete defaults to cancel")
  assert(opts.prompt:find("Progress notes stay archived", 1, true), "current delete explains archive behavior")
  callback(items[1])
end
delete_mapping.callback()
assert(stopped_current_session == nil, "cancel should keep the current session")
assert(dashboard._active_dashboard() == state, "cancel should keep the dashboard open")

vim.ui.select = function(items, _, callback)
  assert(items[2]:find("return to shell", 1, true), "current delete explains UI exit")
  callback(items[2])
end
delete_mapping.callback()
vim.ui.select = original_select
assert_equal(stopped_current_session.name, fake_session.name, "confirmed current session delete")
assert(dashboard._active_dashboard() == nil, "current session delete should close the dashboard")

vim.fs.rm(notes_root, { recursive = true, force = true })
print("session dashboard: ok")
vim.cmd("qa!")
