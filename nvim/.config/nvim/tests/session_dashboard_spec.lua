local uv = vim.uv

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(("%s: expected %s, got %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function window_title(winid)
  local title = vim.api.nvim_win_get_config(winid).title
  if type(title) == "string" then
    return title
  end
  local chunks = {}
  for _, chunk in ipairs(title or {}) do
    chunks[#chunks + 1] = chunk[1]
  end
  return table.concat(chunks)
end

local function dashboard_text(state)
  return table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
end

local function session_row(state, session_id)
  for line = 1, vim.api.nvim_buf_line_count(state.bufnr) do
    local item = state.line_map[line]
    if item and item.kind == "session" and item.session_id == session_id then
      return line
    end
  end
  return nil
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
local current_second_entry = assert(store:create_entry(fake_session))
assert(vim.fn.writefile({ "current second tag" }, current_second_entry.path, "b") == 0)
local remote_entry = assert(store:create_entry(second_session))
assert(vim.fn.writefile({ "remote session tag" }, remote_entry.path, "b") == 0)
local entries = store:list_entries(fake_session)
assert_equal(#entries, 2, "stored entry count")
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

dashboard.open()
local state = assert(dashboard._active_dashboard())
assert(vim.api.nvim_win_is_valid(state.winid), "dashboard window should be valid")
assert_equal(vim.bo[state.bufnr].filetype, "dotfiles-session-dashboard", "dashboard filetype")
assert_equal(state.mode, "sessions", "leader fs starts in Session mode")
assert_equal(state.focused_session_id, store:session_id(fake_session), "current session starts focused")
assert(window_title(state.winid):find("Nvim Sessions", 1, true), "Session mode title")
vim.api.nvim_exec_autocmds("VimResized", { buffer = state.bufnr, modeline = false })
local text = dashboard_text(state)
assert(text:find("CURRENT", 1, true), "dashboard should show current session")
assert(text:find("implemented dashboard", 1, true), "focused session tags should expand automatically")
assert(not text:find("remote session tag", 1, true), "unfocused session tags should stay collapsed")

vim.api.nvim_set_current_win(state.winid)
local initial_row = vim.api.nvim_win_get_cursor(state.winid)[1]
local next_mapping = vim.fn.maparg("j", "n", false, true)
assert(type(next_mapping.callback) == "function", "dashboard next mapping is missing")
next_mapping.callback()
local second_row = vim.api.nvim_win_get_cursor(state.winid)[1]
assert(second_row > initial_row, "j should move to the next session row")
assert_equal(state.line_map[second_row].session_id, store:session_id(second_session), "j selected session")
assert_equal(state.focused_session_id, store:session_id(second_session), "j updates focused session")
text = dashboard_text(state)
assert(text:find("remote session tag", 1, true), "newly focused session tags should expand")
assert(not text:find("implemented dashboard", 1, true), "previous session tags should collapse")

local refresh_mapping = vim.fn.maparg("R", "n", false, true)
refresh_mapping.callback()
local refreshed_row = vim.api.nvim_win_get_cursor(state.winid)[1]
assert_equal(state.line_map[refreshed_row].session_id, store:session_id(second_session), "refresh kept selection")

local previous_mapping = vim.fn.maparg("k", "n", false, true)
previous_mapping.callback()
assert(vim.api.nvim_win_get_cursor(state.winid)[1] < refreshed_row, "k should move to the previous actionable row")
assert_equal(state.focused_session_id, store:session_id(fake_session), "k restores previous focus")

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

local second_session_row = assert(session_row(state, store:session_id(second_session)))
vim.api.nvim_win_set_cursor(state.winid, { second_session_row, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = state.bufnr, modeline = false })
assert(
  vim.wait(100, function()
    return state.focused_session_id == store:session_id(second_session)
  end),
  "CursorMoved should synchronize session focus"
)
assert(dashboard_text(state):find("remote session tag", 1, true), "CursorMoved focus should update the cascade")

first_mapping.callback()
local tag_mapping = vim.fn.maparg("t", "n", false, true)
assert(type(tag_mapping.callback) == "function", "dashboard tag mode mapping is missing")
tag_mapping.callback()
assert_equal(state.mode, "tags", "t enters Tag mode")
assert(window_title(state.winid):find("Session Tags · dotfiles work", 1, true), "Tag mode title names its session")
local selected_tag_row = vim.api.nvim_win_get_cursor(state.winid)[1]
assert_equal(state.line_map[selected_tag_row].kind, "entry", "Tag mode starts on the latest tag")

next_mapping.callback()
local older_tag_row = vim.api.nvim_win_get_cursor(state.winid)[1]
assert(older_tag_row > selected_tag_row, "Tag mode j should move only between tags")
assert_equal(state.line_map[older_tag_row].session_id, store:session_id(fake_session), "Tag mode stays in its session")
last_mapping.callback()
assert_equal(state.line_map[vim.api.nvim_win_get_cursor(state.winid)[1]].kind, "entry", "Tag mode G selects a tag")
first_mapping.callback()

local insert_edit_mapping = vim.fn.maparg("i", "n", false, true)
assert(type(insert_edit_mapping.callback) == "function", "dashboard insert-edit mapping is missing")
local edited_entry_id = state.line_map[vim.api.nvim_win_get_cursor(state.winid)[1]].entry.id
insert_edit_mapping.callback()
local edited_note = assert(state.note)
assert_equal(edited_note.entry.id, edited_entry_id, "i edits the selected tag")
vim.cmd("stopinsert")
vim.api.nvim_set_current_win(edited_note.winid)
local close_note_mapping = vim.fn.maparg("q", "n", false, true)
close_note_mapping.callback()
assert(state.note == nil, "edited note should close back to Tag mode")

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
close_note_mapping = vim.fn.maparg("q", "n", false, true)
assert(type(close_note_mapping.callback) == "function", "note close mapping is missing")
close_note_mapping.callback()
assert(state.note == nil, "note editor should close back to dashboard")

entries = store:list_entries(fake_session)
assert_equal(#entries, 3, "entry count after dashboard add")
local delete_mapping = vim.fn.maparg("dd", "n", false, true)
assert(type(delete_mapping.callback) == "function", "dashboard delete mapping is missing")
local original_select = vim.ui.select
vim.ui.select = function(items, opts, callback)
  assert_equal(items[1], "Cancel", "tag delete defaults to cancel")
  assert(opts.prompt:find("Delete progress", 1, true), "Tag mode dd should delete progress, not the session")
  callback(items[2])
end
delete_mapping.callback()
vim.ui.select = original_select
assert_equal(#store:list_entries(fake_session), 2, "Tag mode dd should soft-delete one tag")
local trash_scan = uv.fs_scandir(vim.fs.joinpath(notes_root, store:session_id(fake_session), "trash"))
assert(trash_scan and uv.fs_scandir_next(trash_scan), "soft-deleted entry should be retained in trash")
assert_equal(state.mode, "tags", "deleting a tag should keep Tag mode")
assert_equal(
  state.line_map[vim.api.nvim_win_get_cursor(state.winid)[1]].kind,
  "entry",
  "delete selects a remaining tag"
)

local close_dashboard_mapping = vim.fn.maparg("q", "n", false, true)
close_dashboard_mapping.callback()
assert_equal(state.mode, "sessions", "q returns from Tag mode to Session mode")
assert(dashboard._active_dashboard() == state, "returning from Tag mode keeps dashboard open")

sessions = {}
vim.api.nvim_set_current_win(state.winid)
refresh_mapping = vim.fn.maparg("R", "n", false, true)
refresh_mapping.callback()
local archive_mapping = vim.fn.maparg("A", "n", false, true)
archive_mapping.callback()
text = dashboard_text(state)
assert(text:find("Archived Sessions", 1, true), "archive section should be visible")
assert(text:find("dotfiles work", 1, true), "archived session should retain its name")

vim.api.nvim_set_current_win(state.winid)
close_dashboard_mapping = vim.fn.maparg("q", "n", false, true)
close_dashboard_mapping.callback()
assert(dashboard._active_dashboard() == nil, "dashboard should close cleanly")

sessions = { fake_session, second_session }
dashboard.open({ current_notes = true })
state = assert(dashboard._active_dashboard())
assert_equal(state.mode, "tags", "leader fS opens current Tag mode")
assert_equal(state.focused_session_id, store:session_id(fake_session), "leader fS targets current session")
vim.api.nvim_set_current_win(state.winid)
close_dashboard_mapping = vim.fn.maparg("q", "n", false, true)
close_dashboard_mapping.callback()
close_dashboard_mapping.callback()
assert(dashboard._active_dashboard() == nil, "Tag mode q then Session mode q closes")

dashboard.open()
state = assert(dashboard._active_dashboard())
vim.api.nvim_set_current_win(state.winid)
delete_mapping = vim.fn.maparg("dd", "n", false, true)
assert(type(delete_mapping.callback) == "function", "dashboard delete mapping is missing")

original_select = vim.ui.select
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
