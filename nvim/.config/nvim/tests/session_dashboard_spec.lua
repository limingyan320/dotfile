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

local function set_trashed_at(store, session, timestamp)
  local metadata = assert(store:load_metadata(session))
  metadata.trashed_at = timestamp
  metadata.updated_at = timestamp
  assert(vim.fn.writefile({ vim.json.encode(metadata) }, store:metadata_path(session), "b") == 0)
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

local expired_tag_session = vim.tbl_extend("force", vim.deepcopy(second_session), {
  address = vim.fs.joinpath(notes_root, "nvim-1700000002-44-9.sock"),
  name = "expired tag fixture",
})
local expired_tag = assert(store:create_entry(expired_tag_session))
assert(store:delete_entry(expired_tag))
local deleted_tag = assert(store:list_deleted_entries(expired_tag_session)[1])
local expired_tag_path = deleted_tag.path:gsub("deleted%-%d+$", "deleted-1")
assert(uv.fs_rename(deleted_tag.path, expired_tag_path))
local purged_tags, purge_errors = store:purge_expired_deleted_entries(os.time(), 30 * 24 * 60 * 60)
assert_equal(purged_tags, 1, "expired Tag Trash count")
assert_equal(#purge_errors, 0, "expired Tag Trash errors")
assert(not uv.fs_stat(expired_tag_path), "expired Tag Trash file should be unlinked")
assert(store:delete_session_record(expired_tag_session))

local sessions = { fake_session, second_session }
local stopped_current_session
local detached_current_session
local stopped_remote_session
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
  stop_session = function(session, callback)
    stopped_remote_session = session
    for index, candidate in ipairs(sessions) do
      if candidate.address == session.address then
        table.remove(sessions, index)
        break
      end
    end
    callback(true)
  end,
  stop_current_session = function(session)
    stopped_current_session = session
  end,
  detach_current_session = function(session)
    detached_current_session = session
    for _, candidate in ipairs(sessions) do
      if candidate.address == session.address then
        candidate.ui_count = 0
      end
    end
  end,
  clear_agent = function() end,
  autosave_delay = 20,
})

local expired_session = vim.tbl_extend("force", vim.deepcopy(second_session), {
  address = vim.fs.joinpath(notes_root, "nvim-1700000003-45-10.sock"),
  name = "expired session",
  ui_count = 0,
})
assert(store:trash_session(expired_session))
set_trashed_at(store, expired_session, os.time() - 8 * 24 * 60 * 60)
sessions[#sessions + 1] = expired_session
assert_equal(dashboard.cleanup_expired(), 1, "expired Session cleanup should start")
assert(
  vim.wait(200, function()
    return stopped_remote_session
      and stopped_remote_session.address == expired_session.address
      and not uv.fs_stat(store:session_path(expired_session))
  end),
  "expired Session should be stopped automatically"
)
assert(not uv.fs_stat(store:session_path(expired_session)), "empty expired Session metadata should be removed")
stopped_remote_session = nil

local paused_session = vim.tbl_extend("force", vim.deepcopy(second_session), {
  address = vim.fs.joinpath(notes_root, "nvim-1700000004-46-11.sock"),
  name = "attached expired session",
  ui_count = 1,
})
assert(store:trash_session(paused_session))
set_trashed_at(store, paused_session, os.time() - 8 * 24 * 60 * 60)
sessions[#sessions + 1] = paused_session
assert_equal(dashboard.cleanup_expired(), 0, "attached expired Session cleanup should pause")
assert(stopped_remote_session == nil, "attached expired Session must not be stopped")
for index, candidate in ipairs(sessions) do
  if candidate.address == paused_session.address then
    table.remove(sessions, index)
    break
  end
end
assert(store:delete_session_record(paused_session))

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

local recycle_mapping = vim.fn.maparg("T", "n", false, true)
assert(type(recycle_mapping.callback) == "function", "dashboard recycle-bin mapping is missing")
recycle_mapping.callback()
assert(state.show_tag_trash, "T should open the focused session's Tag trash")
assert(window_title(state.winid):find("Tag Trash · dotfiles work", 1, true), "Tag trash title names its session")
assert_equal(#store:list_deleted_entries(fake_session), 1, "deleted tag should be listed in Tag trash")

local restore_mapping = vim.fn.maparg("u", "n", false, true)
assert(type(restore_mapping.callback) == "function", "dashboard restore mapping is missing")
restore_mapping.callback()
assert_equal(#store:list_deleted_entries(fake_session), 0, "u should remove the tag from trash")
assert_equal(#store:list_entries(fake_session), 3, "u should restore the tag to active entries")
recycle_mapping.callback()
assert(not state.show_tag_trash, "T should return to active tags")

local close_dashboard_mapping = vim.fn.maparg("q", "n", false, true)
close_dashboard_mapping.callback()
assert_equal(state.mode, "sessions", "q returns from Tag mode to Session mode")
assert(dashboard._active_dashboard() == state, "returning from Tag mode keeps dashboard open")

sessions = {}
vim.api.nvim_set_current_win(state.winid)
refresh_mapping = vim.fn.maparg("R", "n", false, true)
refresh_mapping.callback()
local past_notes_mapping = vim.fn.maparg("P", "n", false, true)
assert(type(past_notes_mapping.callback) == "function", "Past Session Notes mapping is missing")
past_notes_mapping.callback()
text = dashboard_text(state)
assert(text:find("Past Session Notes", 1, true), "past notes section should be visible")
assert(text:find("ENDED", 1, true), "past notes should use the ENDED status")
assert(text:find("dotfiles work", 1, true), "past notes should retain the session name")

local past_notes_row = assert(session_row(state, store:session_id(fake_session)))
vim.api.nvim_win_set_cursor(state.winid, { past_notes_row, 0 })
original_select = vim.ui.select
vim.ui.select = function(items, opts, callback)
  assert_equal(items[1], "Cancel", "Past Session Notes delete defaults to cancel")
  assert(opts.prompt:find("Metadata and Tag Trash", 1, true), "past notes delete explains its full scope")
  callback(items[2])
end
delete_mapping = vim.fn.maparg("dd", "n", false, true)
delete_mapping.callback()
vim.ui.select = original_select
assert(not uv.fs_stat(store:session_path(fake_session)), "dd should permanently remove all Past Session Notes")
assert(session_row(state, store:session_id(fake_session)) == nil, "deleted Past Session Notes should leave the list")

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
delete_mapping.callback()
assert_equal(detached_current_session.name, fake_session.name, "current session should detach after moving to trash")
assert(stopped_current_session == nil, "moving current session to trash must not stop it")
assert(store:session_trashed_at(fake_session) ~= nil, "current session should have recycle metadata")
assert(dashboard._active_dashboard() == nil, "trashing current session should close the dashboard before detach")

dashboard.open()
state = assert(dashboard._active_dashboard())
assert(session_row(state, store:session_id(fake_session)) == nil, "trashed session should be hidden by default")
vim.api.nvim_set_current_win(state.winid)
recycle_mapping = vim.fn.maparg("T", "n", false, true)
recycle_mapping.callback()
assert(dashboard_text(state):find("Recycle Bin", 1, true), "T should show the Session recycle bin")
assert(dashboard_text(state):find("expires 7d", 1, true), "Session trash should show its seven-day retention")
local current_trash_row = assert(session_row(state, store:session_id(fake_session)))
vim.api.nvim_win_set_cursor(state.winid, { current_trash_row, 0 })
restore_mapping = vim.fn.maparg("u", "n", false, true)
restore_mapping.callback()
assert(store:session_trashed_at(fake_session) == nil, "u should restore a trashed session")
assert(session_row(state, store:session_id(fake_session)) ~= nil, "restored session should return to the live list")

local remote_row = assert(session_row(state, store:session_id(second_session)))
vim.api.nvim_win_set_cursor(state.winid, { remote_row, 0 })
delete_mapping = vim.fn.maparg("dd", "n", false, true)
delete_mapping.callback()
assert(stopped_remote_session == nil, "first dd must not stop a remote session")
assert(store:session_trashed_at(second_session) ~= nil, "first dd should move a remote session to trash")

remote_row = assert(session_row(state, store:session_id(second_session)))
vim.api.nvim_win_set_cursor(state.winid, { remote_row, 0 })
original_select = vim.ui.select
vim.ui.select = function(items, opts, callback)
  assert_equal(items[1], "Cancel", "permanent delete defaults to cancel")
  assert(opts.prompt:find("cannot be restored", 1, true), "permanent delete explains the irreversible runtime loss")
  callback(items[2])
end
delete_mapping.callback()
vim.ui.select = original_select
assert_equal(stopped_remote_session.name, second_session.name, "second dd should permanently stop the remote session")
assert(
  session_row(state, store:session_id(second_session)) == nil,
  "permanently deleted session should leave the dashboard"
)

vim.api.nvim_set_current_win(state.winid)
close_dashboard_mapping = vim.fn.maparg("q", "n", false, true)
close_dashboard_mapping.callback()
assert(dashboard._active_dashboard() == nil, "dashboard should close after recycle-bin tests")

vim.fs.rm(notes_root, { recursive = true, force = true })
print("session dashboard: ok")
vim.cmd("qa!")
