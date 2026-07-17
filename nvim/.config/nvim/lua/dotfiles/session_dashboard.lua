local uv = vim.uv

local M = {}

local config
local store
local active_dashboard
local note_states = {}
local dashboard_namespace = vim.api.nvim_create_namespace("dotfiles_session_dashboard")

local function path_join(...)
  return vim.fs.joinpath(...)
end

local function trim(value)
  return vim.trim(tostring(value or ""))
end

local function display_name(session)
  local name = trim(session.name)
  if name ~= "" then
    return name
  end
  name = trim(session.project)
  if name ~= "" then
    return name
  end
  return trim(session.cwd) ~= "" and session.cwd or "unnamed"
end

local function stat_seconds(value)
  if type(value) == "table" then
    return tonumber(value.sec or value.tv_sec or value[1]) or 0
  end
  return tonumber(value) or 0
end

local function ensure_directory(path)
  if vim.fn.isdirectory(path) ~= 1 and vim.fn.mkdir(path, "p") ~= 1 then
    return false, "cannot create directory " .. path
  end
  pcall(uv.fs_chmod, path, 448) -- 0700
  return true
end

local function read_file(path)
  local handle = io.open(path, "r")
  if not handle then
    return nil
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local function read_json(path)
  local content = read_file(path)
  if not content or content == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, content)
  return ok and type(decoded) == "table" and decoded or nil
end

local function write_json_atomic(path, value)
  local parent = vim.fn.fnamemodify(path, ":h")
  local ok, err = ensure_directory(parent)
  if not ok then
    return false, err
  end

  local temporary = path .. ".tmp-" .. tostring(uv.hrtime())
  local written = vim.fn.writefile({ vim.json.encode(value) }, temporary, "b")
  if written ~= 0 then
    return false, "cannot write " .. temporary
  end
  pcall(uv.fs_chmod, temporary, 384) -- 0600
  local renamed, rename_err = uv.fs_rename(temporary, path)
  if not renamed then
    pcall(uv.fs_unlink, temporary)
    return false, tostring(rename_err or "cannot replace metadata")
  end
  return true
end

local function truncate_display(text, width)
  text = tostring(text or ""):gsub("[\r\n\t]", " ")
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end

  local suffix = "…"
  local available = math.max(0, width - vim.fn.strdisplaywidth(suffix))
  local result = {}
  local used = 0
  for index = 0, vim.fn.strchars(text) - 1 do
    local character = vim.fn.strcharpart(text, index, 1)
    local character_width = vim.fn.strdisplaywidth(character)
    if used + character_width > available then
      break
    end
    result[#result + 1] = character
    used = used + character_width
  end
  return table.concat(result) .. suffix
end

local function pad_display(text, width)
  text = truncate_display(text, width)
  return text .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(text)))
end

local function relative_age(timestamp)
  local elapsed = math.max(0, os.time() - (tonumber(timestamp) or 0))
  if elapsed < 60 then
    return "now"
  elseif elapsed < 3600 then
    return math.floor(elapsed / 60) .. "m"
  elseif elapsed < 86400 then
    return math.floor(elapsed / 3600) .. "h"
  end
  return math.floor(elapsed / 86400) .. "d"
end

local function day_label(timestamp)
  local date = os.date("%Y-%m-%d", timestamp)
  local today = os.date("%Y-%m-%d")
  local yesterday = os.date("%Y-%m-%d", os.time() - 86400)
  if date == today then
    return "Today"
  elseif date == yesterday then
    return "Yesterday"
  end
  return date
end

local Store = {}
Store.__index = Store

function Store.new(root)
  return setmetatable({ root = vim.fs.normalize(root) }, Store)
end

function Store:session_id(session)
  local explicit = trim(session and session.session_id)
  if explicit ~= "" then
    return explicit:gsub("[^%w._-]", "_")
  end

  local address = vim.fs.normalize(tostring(session and session.address or ""))
  local socket_name = vim.fn.fnamemodify(address, ":t")
  local managed_id = socket_name:match("^(nvim%-.+)%.sock$")
  if managed_id then
    return managed_id:gsub("[^%w._-]", "_")
  end
  if address ~= "" then
    return "peer-" .. vim.fn.sha256(address):sub(1, 24)
  end
  local pid = tonumber(session and session.pid)
  if pid then
    return "process-" .. tostring(pid)
  end
  return nil
end

function Store:session_path(session_or_id)
  local session_id = type(session_or_id) == "table" and self:session_id(session_or_id) or session_or_id
  return session_id and path_join(self.root, session_id) or nil
end

function Store:metadata_path(session_or_id)
  local directory = self:session_path(session_or_id)
  return directory and path_join(directory, "meta.json") or nil
end

function Store:entries_path(session_or_id)
  local directory = self:session_path(session_or_id)
  return directory and path_join(directory, "entries") or nil
end

function Store:load_metadata(session_or_id)
  local path = self:metadata_path(session_or_id)
  return path and read_json(path) or nil
end

function Store:update_session(session)
  local session_id = self:session_id(session)
  if not session_id then
    return false, "session has no stable identifier"
  end

  local directory = self:session_path(session_id)
  local ok, err = ensure_directory(self.root)
  if not ok then
    return false, err
  end
  ok, err = ensure_directory(directory)
  if not ok then
    return false, err
  end
  ok, err = ensure_directory(self:entries_path(session_id))
  if not ok then
    return false, err
  end

  local previous = self:load_metadata(session_id) or {}
  local now = os.time()
  local metadata = {
    version = 1,
    session_id = session_id,
    name = trim(session.name),
    project = trim(session.project),
    cwd = trim(session.cwd),
    address = trim(session.address),
    created_at = tonumber(previous.created_at) or now,
    updated_at = now,
  }
  return write_json_atomic(self:metadata_path(session_id), metadata)
end

function Store:create_entry(session)
  local ok, err = self:update_session(session)
  if not ok then
    return nil, err
  end

  local session_id = self:session_id(session)
  local created_at = os.time()
  local suffix = math.floor(uv.hrtime() % 1000000)
  local entry_id = ("%d-%06d"):format(created_at, suffix)
  local path = path_join(self:entries_path(session_id), entry_id .. ".md")
  while uv.fs_stat(path) do
    suffix = (suffix + 1) % 1000000
    entry_id = ("%d-%06d"):format(created_at, suffix)
    path = path_join(self:entries_path(session_id), entry_id .. ".md")
  end

  if vim.fn.writefile({ "" }, path, "b") ~= 0 then
    return nil, "cannot create progress entry"
  end
  pcall(uv.fs_chmod, path, 384) -- 0600
  return {
    id = entry_id,
    path = path,
    created_at = created_at,
    updated_at = created_at,
    preview = "",
  }
end

function Store:list_entries(session_or_id)
  local directory = self:entries_path(session_or_id)
  local scan = directory and uv.fs_scandir(directory) or nil
  if not scan then
    return {}
  end

  local entries = {}
  while true do
    local filename, file_type = uv.fs_scandir_next(scan)
    if not filename then
      break
    end
    local created_at, suffix = filename:match("^(%d+)%-(%d+)%.md$")
    if file_type == "file" and created_at and suffix then
      local path = path_join(directory, filename)
      local stat = uv.fs_stat(path)
      local preview = ""
      local handle = io.open(path, "r")
      if handle then
        for raw_line in handle:lines() do
          local line = trim(raw_line)
          if line ~= "" then
            preview = line
            break
          end
        end
        handle:close()
      end
      entries[#entries + 1] = {
        id = created_at .. "-" .. suffix,
        path = path,
        created_at = tonumber(created_at),
        updated_at = stat and stat_seconds(stat.mtime) or tonumber(created_at),
        preview = preview,
      }
    end
  end

  table.sort(entries, function(a, b)
    if a.created_at ~= b.created_at then
      return a.created_at > b.created_at
    end
    return a.id > b.id
  end)
  return entries
end

function Store:delete_entry(entry)
  if not entry or not entry.path or not uv.fs_stat(entry.path) then
    return false, "progress entry no longer exists"
  end

  local session_directory = vim.fn.fnamemodify(vim.fn.fnamemodify(entry.path, ":h"), ":h")
  local trash = path_join(session_directory, "trash")
  local ok, err = ensure_directory(trash)
  if not ok then
    return false, err
  end

  local target = path_join(trash, vim.fn.fnamemodify(entry.path, ":t") .. ".deleted-" .. os.time())
  local renamed, rename_err = uv.fs_rename(entry.path, target)
  if not renamed then
    return false, tostring(rename_err or "cannot move entry to trash")
  end
  return true
end

function Store:list_archives(live_ids)
  local scan = uv.fs_scandir(self.root)
  if not scan then
    return {}
  end

  local archives = {}
  while true do
    local session_id, file_type = uv.fs_scandir_next(scan)
    if not session_id then
      break
    end
    if file_type == "directory" and not live_ids[session_id] then
      local metadata = self:load_metadata(session_id)
      local entries = self:list_entries(session_id)
      if metadata and #entries > 0 then
        archives[#archives + 1] = {
          session_id = session_id,
          archived = true,
          current = false,
          ui_count = 0,
          name = trim(metadata.name),
          project = trim(metadata.project),
          cwd = trim(metadata.cwd),
          address = trim(metadata.address),
          current_buffer = "",
          modified_count = 0,
          terminal_count = 0,
          window_count = 0,
          tab_count = 0,
          last_active = math.max(entries[1].updated_at, tonumber(metadata.updated_at) or 0),
          agent_state = { state = "idle", unread = false },
          notes = entries,
        }
      end
    end
  end

  table.sort(archives, function(a, b)
    return a.last_active > b.last_active
  end)
  return archives
end

local function note_summary(entries)
  local updated_at = 0
  for _, entry in ipairs(entries or {}) do
    updated_at = math.max(updated_at, entry.updated_at or entry.created_at or 0)
  end
  return { count = #(entries or {}), updated_at = updated_at }
end

local function dashboard_valid(state)
  return state and vim.api.nvim_buf_is_valid(state.bufnr) and state.winid and vim.api.nvim_win_is_valid(state.winid)
end

local function selected_key(state)
  if not dashboard_valid(state) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(state.winid)[1]
  local item = state.line_map[row]
  return item and item.key or nil
end

local function refresh_note_data(state, session_id)
  for _, session in ipairs(state.sessions or {}) do
    if not session_id or session.session_id == session_id then
      session.notes = store:list_entries(session.session_id)
      session.note_summary = note_summary(session.notes)
    end
  end
end

local function load_sessions(state)
  local ok, sessions = pcall(config.discover_sessions)
  if not ok or type(sessions) ~= "table" then
    vim.notify("读取 Nvim sessions 失败: " .. tostring(sessions), vim.log.levels.ERROR)
    sessions = {}
  end

  local live_ids = {}
  for _, session in ipairs(sessions) do
    if session.current then
      if state.current_buffer_snapshot then
        session.current_buffer = state.current_buffer_snapshot
      else
        state.current_buffer_snapshot = session.current_buffer
      end
    end
    session.session_id = store:session_id(session)
    if session.session_id then
      live_ids[session.session_id] = true
      session.notes = store:list_entries(session.session_id)
      session.note_summary = note_summary(session.notes)
    else
      session.notes = {}
      session.note_summary = note_summary({})
    end
  end

  if state.show_archives then
    vim.list_extend(sessions, store:list_archives(live_ids))
  end
  state.sessions = sessions

  local focused_exists = false
  for _, session in ipairs(sessions) do
    if session.session_id == state.focused_session_id then
      focused_exists = true
      break
    end
  end
  if not focused_exists then
    state.focused_session_id = nil
    for _, session in ipairs(sessions) do
      if session.current then
        state.focused_session_id = session.session_id
        break
      end
    end
    if not state.focused_session_id and sessions[1] then
      state.focused_session_id = sessions[1].session_id
    end
  end
end

local function session_by_id(state, session_id)
  for _, session in ipairs(state.sessions or {}) do
    if session.session_id == session_id then
      return session
    end
  end
  return nil
end

local function append_render_line(output, spans, item)
  local text = ""
  local highlights = {}
  for _, span in ipairs(spans) do
    local content = tostring(span[1] or "")
    local start_col = #text
    text = text .. content
    if span[2] and span[2] ~= "" then
      highlights[#highlights + 1] = {
        group = span[2],
        start_col = start_col,
        end_col = #text,
      }
    end
  end
  output.lines[#output.lines + 1] = text
  output.highlights[#output.lines] = highlights
  if item then
    output.line_map[#output.lines] = item
  end
end

local function session_status(session)
  if session.archived then
    return "ARCHIVED", "Comment"
  elseif session.current then
    return "CURRENT", "DiagnosticOk"
  elseif session.ui_count == 0 then
    return "DETACHED", "DiagnosticWarn"
  end
  return "ATTACHED", "DiagnosticInfo"
end

local function agent_indicator(state, session)
  local agent = session.agent_state or {}
  if agent.state == "ready" and agent.unread then
    local frames = config.agent_ready_frames or { " ! ", " · " }
    local index = math.floor((state.animation_frame - 1) / 2) % #frames + 1
    return frames[index], "DiagnosticError"
  elseif agent.state == "working" then
    local frames = config.agent_working_frames or { "●··", "·●·", "··●", "···" }
    local index = (state.animation_frame - 1) % #frames + 1
    return frames[index], "DiagnosticInfo"
  end
  return "   ", "Comment"
end

local function render_dashboard(state, preferred_key)
  if not dashboard_valid(state) then
    return
  end

  preferred_key = preferred_key or selected_key(state)
  local width = vim.api.nvim_win_get_width(state.winid)
  local output = { lines = {}, highlights = {}, line_map = {} }
  local live_count = 0
  for _, session in ipairs(state.sessions) do
    if not session.archived then
      live_count = live_count + 1
    end
  end

  append_render_line(output, {
    { " Live Sessions", "Title" },
    { ("  %d active"):format(live_count), "Comment" },
  })

  local archived_heading_rendered = false
  for _, session in ipairs(state.sessions) do
    if session.archived and not archived_heading_rendered then
      append_render_line(output, { { "", nil } })
      append_render_line(output, { { " Archived Sessions", "Title" } })
      archived_heading_rendered = true
    end

    local session_id = session.session_id
    local status, status_highlight = session_status(session)
    local agent_text, agent_highlight = agent_indicator(state, session)
    local summary = session.note_summary or note_summary(session.notes)
    local note_text
    local note_highlight
    if summary.count > 0 then
      note_text = ("◆ %d · %s"):format(summary.count, relative_age(summary.updated_at))
      note_highlight = "DiagnosticHint"
    else
      note_text = "◇ 0"
      note_highlight = "Comment"
    end

    local details = session.archived and "saved progress"
      or ("%dw %dt %d* %dterm"):format(
        session.window_count,
        session.tab_count,
        session.modified_count,
        session.terminal_count
      )
    local status_width = 8
    local note_width = 13
    local details_width = width >= 95 and 17 or 0
    local name_width = math.max(12, math.min(32, math.floor(width * 0.24)))
    local fixed_width = 3
      + 2
      + status_width
      + 2
      + name_width
      + 2
      + note_width
      + (details_width > 0 and details_width + 2 or 0)
    local buffer_width = math.max(0, width - fixed_width - 2)

    local item = {
      kind = "session",
      key = "session:" .. session_id,
      session = session,
      session_id = session_id,
    }
    local spans = {
      { agent_text, agent_highlight },
      { "  ", nil },
      { pad_display(status, status_width), status_highlight },
      { "  ", nil },
      { pad_display(display_name(session), name_width), "Identifier" },
      { "  ", nil },
      { pad_display(note_text, note_width), note_highlight },
    }
    if buffer_width > 0 then
      spans[#spans + 1] = { "  ", nil }
      spans[#spans + 1] = { pad_display(session.current_buffer or "", buffer_width), nil }
    end
    if details_width > 0 then
      spans[#spans + 1] = { "  ", nil }
      spans[#spans + 1] = { pad_display(details, details_width), "Comment" }
    end
    append_render_line(output, spans, item)

    local show_entries = session_id == state.focused_session_id and (#(session.notes or {}) > 0 or state.mode == "tags")
    if show_entries then
      local entries = session.notes or {}
      if #entries == 0 then
        append_render_line(output, {
          { "      No progress entries", "Comment" },
        })
      else
        local groups = {}
        local order = {}
        for _, entry in ipairs(entries) do
          local label = day_label(entry.created_at)
          if not groups[label] then
            groups[label] = {}
            order[#order + 1] = label
          end
          groups[label][#groups[label] + 1] = entry
        end

        for _, label in ipairs(order) do
          append_render_line(output, {
            { "      " .. label, "Special" },
          })
          for index, entry in ipairs(groups[label]) do
            local branch = index == #groups[label] and "└" or "├"
            local preview = entry.preview ~= "" and entry.preview or "(empty note)"
            local prefix = ("      %s %s  "):format(branch, os.date("%H:%M", entry.created_at))
            append_render_line(output, {
              { prefix, "Comment" },
              {
                truncate_display(preview, math.max(12, width - vim.fn.strdisplaywidth(prefix) - 2)),
                "Normal",
              },
            }, {
              kind = "entry",
              key = "entry:" .. entry.id,
              session = session,
              session_id = session_id,
              entry = entry,
            })
          end
        end
      end
    end
  end

  if #state.sessions == 0 then
    append_render_line(output, { { "   No live sessions", "Comment" } })
  elseif state.show_archives and not archived_heading_rendered then
    append_render_line(output, { { "", nil } })
    append_render_line(output, { { " Archived Sessions", "Title" } })
    append_render_line(output, { { "   No archived progress", "Comment" } })
  end

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, output.lines)
  vim.api.nvim_buf_clear_namespace(state.bufnr, dashboard_namespace, 0, -1)
  for line, highlights in pairs(output.highlights) do
    for _, highlight in ipairs(highlights) do
      vim.api.nvim_buf_add_highlight(
        state.bufnr,
        dashboard_namespace,
        highlight.group,
        line - 1,
        highlight.start_col,
        highlight.end_col
      )
    end
  end
  vim.bo[state.bufnr].modifiable = false
  state.line_map = output.line_map

  local title = " Nvim Sessions "
  if state.mode == "tags" then
    local focused = session_by_id(state, state.focused_session_id)
    if focused then
      title = (" Session Tags · %s "):format(display_name(focused))
    else
      title = " Session Tags "
    end
  end
  pcall(vim.api.nvim_win_set_config, state.winid, {
    title = truncate_display(title, math.max(1, width - 4)),
    title_pos = "center",
  })

  local target_line
  if preferred_key then
    for line, item in pairs(state.line_map) do
      if item.key == preferred_key then
        target_line = line
        break
      end
    end
  end
  if not target_line then
    for line, item in pairs(state.line_map) do
      if item.kind == "session" then
        target_line = target_line and math.min(target_line, line) or line
      end
    end
  end
  if target_line then
    pcall(vim.api.nvim_win_set_cursor, state.winid, { target_line, 0 })
  end
end

local function selected_item(state)
  if not dashboard_valid(state) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(state.winid)[1]
  if state.line_map[row] then
    return state.line_map[row]
  end
  for line = row, 1, -1 do
    if state.line_map[line] then
      return state.line_map[line]
    end
  end
  return nil
end

local function move_selection(state, direction, boundary)
  if not dashboard_valid(state) then
    return
  end
  local row = vim.api.nvim_win_get_cursor(state.winid)[1]
  local line_count = vim.api.nvim_buf_line_count(state.bufnr)
  local start_line
  local end_line
  local step
  if boundary == "first" then
    start_line, end_line, step = 1, line_count, 1
  elseif boundary == "last" then
    start_line, end_line, step = line_count, 1, -1
  else
    start_line = row + direction
    end_line = direction > 0 and line_count or 1
    step = direction
  end
  for line = start_line, end_line, step do
    local item = state.line_map[line]
    local selectable = item
      and (
        (state.mode == "sessions" and item.kind == "session")
        or (state.mode == "tags" and item.kind == "entry" and item.session_id == state.focused_session_id)
      )
    if selectable then
      if state.mode == "sessions" then
        state.focused_session_id = item.session_id
        render_dashboard(state, item.key)
      else
        vim.api.nvim_win_set_cursor(state.winid, { line, 0 })
      end
      return
    end
  end
end

local function stop_dashboard_timer(state)
  if not state.timer or state.timer_closed then
    return
  end
  state.timer_closed = true
  state.timer:stop()
  if not state.timer:is_closing() then
    state.timer:close()
  end
end

local function close_note_editor(state)
  local note = state and state.note
  if not note then
    return true
  end
  local note_state = note_states[note.bufnr]
  if note_state and note_state.save_now and not note_state.save_now() then
    return false
  end
  if note.winid and vim.api.nvim_win_is_valid(note.winid) then
    vim.api.nvim_win_close(note.winid, true)
  end
  state.note = nil
  if dashboard_valid(state) then
    vim.api.nvim_set_current_win(state.winid)
  end
  return true
end

local function close_dashboard(state)
  if not state then
    return true
  end
  if not close_note_editor(state) then
    return false
  end
  stop_dashboard_timer(state)
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_win_close(state.winid, true)
  end
  if active_dashboard == state then
    active_dashboard = nil
  end
  return true
end

local function open_note_editor(state, session, entry, enter_insert)
  if not entry or not uv.fs_stat(entry.path) then
    vim.notify("进度条目已不存在", vim.log.levels.WARN)
    refresh_note_data(state, session.session_id)
    render_dashboard(state, "session:" .. session.session_id)
    return
  end
  if state.note and not close_note_editor(state) then
    return
  end

  local bufnr = vim.fn.bufadd(entry.path)
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = true
  vim.bo[bufnr].filetype = "markdown"
  vim.b[bufnr].dotfiles_session_note = true

  local columns = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight
  local width = math.min(math.max(1, columns - 4), math.max(40, math.floor(columns * 0.78)))
  local height = math.min(math.max(1, lines - 4), math.max(10, math.floor(lines * 0.72)))
  local title = (" %s · %s "):format(display_name(session), os.date("%Y-%m-%d %H:%M", entry.created_at))
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = truncate_display(title, math.max(1, width - 4)),
    title_pos = "center",
    width = width,
    height = height,
    row = math.max(0, math.floor((lines - height) / 2)),
    col = math.max(0, math.floor((columns - width) / 2)),
    zindex = 60,
  })
  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true
  vim.wo[winid].cursorline = false
  state.note = { bufnr = bufnr, winid = winid, entry = entry }

  local note_state = {
    bufnr = bufnr,
    state = state,
    session = session,
    entry = entry,
    generation = 0,
  }
  note_states[bufnr] = note_state

  local function after_save()
    local ok, err = store:update_session(session)
    if not ok then
      vim.notify("更新 session 日志元数据失败: " .. tostring(err), vim.log.levels.ERROR)
    end
    if dashboard_valid(state) then
      refresh_note_data(state, session.session_id)
      render_dashboard(state, "entry:" .. entry.id)
    end
  end

  local function save_now()
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.bo[bufnr].modified then
      return true
    end
    local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("silent write")
    end)
    if not ok then
      vim.notify("保存 session 进度失败: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
    return true
  end
  note_state.save_now = save_now

  local function schedule_save()
    note_state.generation = note_state.generation + 1
    local generation = note_state.generation
    vim.defer_fn(function()
      if note_states[bufnr] == note_state and note_state.generation == generation then
        save_now()
      end
    end, config.autosave_delay or 400)
  end

  local group = vim.api.nvim_create_augroup("DotfilesSessionNote" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = schedule_save,
  })
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = group,
    buffer = bufnr,
    callback = save_now,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = bufnr,
    callback = after_save,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function()
      note_state.generation = note_state.generation + 1
      note_states[bufnr] = nil
      if state.note and state.note.bufnr == bufnr then
        state.note = nil
      end
      if dashboard_valid(state) then
        refresh_note_data(state, session.session_id)
        render_dashboard(state, "entry:" .. entry.id)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    buffer = bufnr,
    callback = function()
      if not vim.api.nvim_win_is_valid(winid) then
        return
      end
      local resized_columns = vim.o.columns
      local resized_lines = vim.o.lines - vim.o.cmdheight
      local resized_width = math.min(math.max(1, resized_columns - 4), math.max(40, math.floor(resized_columns * 0.78)))
      local resized_height = math.min(math.max(1, resized_lines - 4), math.max(10, math.floor(resized_lines * 0.72)))
      pcall(vim.api.nvim_win_set_config, winid, {
        relative = "editor",
        width = resized_width,
        height = resized_height,
        row = math.max(0, math.floor((resized_lines - resized_height) / 2)),
        col = math.max(0, math.floor((resized_columns - resized_width) / 2)),
      })
    end,
  })

  local function close_current_note()
    close_note_editor(state)
  end
  vim.keymap.set("n", "q", close_current_note, { buffer = bufnr, desc = "Close session note" })
  vim.keymap.set("n", "<C-s>", save_now, { buffer = bufnr, desc = "Save session note" })
  vim.keymap.set("i", "<C-s>", save_now, { buffer = bufnr, desc = "Save session note" })

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local last_line = vim.api.nvim_buf_get_lines(bufnr, line_count - 1, line_count, false)[1] or ""
  vim.api.nvim_win_set_cursor(winid, { line_count, #last_line })
  if enter_insert then
    vim.cmd("startinsert!")
  end
end

local function context_session(state)
  local item = selected_item(state)
  local session = item and item.session or session_by_id(state, state.focused_session_id)
  return session, item
end

local function add_entry(state)
  local session = context_session(state)
  if not session then
    return
  end
  local entry, err = store:create_entry(session)
  if not entry then
    vim.notify("创建 session 进度失败: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  state.mode = "tags"
  state.focused_session_id = session.session_id
  refresh_note_data(state, session.session_id)
  render_dashboard(state, "entry:" .. entry.id)
  open_note_editor(state, session, entry, true)
end

local function edit_entry(state, enter_insert)
  local session, item = context_session(state)
  if not session then
    return
  end
  if item and item.kind == "entry" then
    open_note_editor(state, session, item.entry, enter_insert)
  elseif session.notes and session.notes[1] then
    render_dashboard(state, "entry:" .. session.notes[1].id)
    open_note_editor(state, session, session.notes[1], enter_insert)
  else
    vim.notify("当前 session 还没有 tag；按 a 新建", vim.log.levels.INFO)
  end
end

local function delete_entry(state)
  local _, item = context_session(state)
  if not item or item.kind ~= "entry" then
    vim.notify("请先选择一条进度记录", vim.log.levels.WARN)
    return
  end
  local entry = item.entry
  local preview = entry.preview ~= "" and entry.preview or "empty note"
  vim.ui.select({ "Cancel", "Delete - move entry to trash" }, {
    prompt = ("Delete progress %q?"):format(truncate_display(preview, 50)),
    kind = "dotfiles_nvim_session_note_delete",
  }, function(choice)
    if choice ~= "Delete - move entry to trash" then
      return
    end
    if state.note and state.note.entry.path == entry.path and not close_note_editor(state) then
      return
    end
    local ok, err = store:delete_entry(entry)
    if not ok then
      vim.notify("删除 session 进度失败: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    store:update_session(item.session)
    local deleted_index = 1
    for index, candidate in ipairs(item.session.notes or {}) do
      if candidate.id == entry.id then
        deleted_index = index
        break
      end
    end
    refresh_note_data(state, item.session_id)
    local remaining = item.session.notes or {}
    local next_entry = remaining[deleted_index] or remaining[deleted_index - 1]
    local key = next_entry and "entry:" .. next_entry.id or "session:" .. item.session_id
    render_dashboard(state, key)
  end)
end

local function enter_tag_mode(state)
  local session = context_session(state)
  if not session then
    return
  end
  state.mode = "tags"
  state.focused_session_id = session.session_id
  local item = selected_item(state)
  local key = item and item.kind == "entry" and item.key
    or (session.notes and session.notes[1] and "entry:" .. session.notes[1].id)
    or "session:" .. session.session_id
  render_dashboard(state, key)
end

local function leave_tag_mode(state)
  state.mode = "sessions"
  render_dashboard(state, "session:" .. tostring(state.focused_session_id or ""))
end

local function toggle_tag_mode(state)
  if state.mode == "tags" then
    leave_tag_mode(state)
  else
    enter_tag_mode(state)
  end
end

local function select_context(state)
  local session, item = context_session(state)
  if not session then
    return
  end
  if state.mode == "tags" then
    edit_entry(state, false)
  elseif session.archived then
    enter_tag_mode(state)
  elseif session.current then
    close_dashboard(state)
  else
    close_dashboard(state)
    vim.defer_fn(function()
      config.connect_session(session)
    end, 50)
  end
end

local function rename_session(state)
  local session = context_session(state)
  if not session then
    return
  elseif session.archived then
    vim.notify("归档日志不能重命名 live session", vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = "Rename Nvim session:", default = session.name }, function(input)
    if input == nil then
      return
    end
    local ok, err = config.rename_session(session, input)
    if not ok then
      vim.notify("重命名 Nvim session 失败: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    session.name = config.normalize_name(input)
    if session.note_summary.count > 0 then
      store:update_session(session)
    end
    load_sessions(state)
    render_dashboard(state, "session:" .. session.session_id)
  end)
end

local function create_session(state)
  local cwd = vim.fn.getcwd()
  vim.ui.input({ prompt = "New Nvim session:" }, function(input)
    if input == nil then
      return
    end
    local name = config.normalize_name(input)
    if name == "" then
      vim.notify("Session 名称不能为空", vim.log.levels.WARN)
      return
    end

    close_dashboard(state)
    config.create_session(name, cwd, function(address, err)
      if not address then
        vim.notify("创建 Nvim session 失败: " .. tostring(err), vim.log.levels.ERROR)
        vim.schedule(function()
          M.open()
        end)
        return
      end
      vim.defer_fn(function()
        config.connect_created_session(address)
      end, 50)
    end)
  end)
end

local function delete_session(state)
  local session = context_session(state)
  if not session then
    return
  elseif session.archived then
    vim.notify("归档日志不会随 live session 删除", vim.log.levels.WARN)
    return
  end

  local risks = {}
  if session.modified_count > 0 then
    risks[#risks + 1] = ("%d modified buffer(s)"):format(session.modified_count)
  end
  if session.terminal_count > 0 then
    risks[#risks + 1] = ("%d terminal(s)"):format(session.terminal_count)
  end
  if session.ui_count > 0 then
    risks[#risks + 1] = ("%d attached UI(s)"):format(session.ui_count)
  end
  local delete_label
  if session.current then
    delete_label = "Delete current - force close and return to shell"
  else
    delete_label = "Delete - force close this session"
  end
  if session.current and #risks > 0 then
    delete_label = "Delete current - return to shell; closes " .. table.concat(risks, ", ")
  elseif #risks > 0 then
    delete_label = "Delete - closes " .. table.concat(risks, ", ")
  end

  vim.ui.select({ "Cancel", delete_label }, {
    prompt = session.current and ("Delete CURRENT session %q? Progress notes stay archived."):format(
      display_name(session)
    ) or ("Delete session %q?"):format(display_name(session)),
    kind = "dotfiles_nvim_session_delete",
  }, function(choice)
    if choice ~= delete_label then
      return
    end
    if session.current then
      if close_dashboard(state) then
        config.stop_current_session(session)
      end
      return
    end
    config.stop_session(session, function(stopped, err)
      if stopped then
        config.clear_agent(session.address)
        vim.notify(("Deleted Nvim session %q; progress was archived"):format(display_name(session)))
      else
        vim.notify("删除 Nvim session 失败: " .. tostring(err), vim.log.levels.ERROR)
      end
      if dashboard_valid(state) then
        load_sessions(state)
        render_dashboard(state)
      end
    end)
  end)
end

local function show_help(state)
  local lines
  local title
  if state.mode == "tags" then
    lines = {
      "Enter/e edit · i edit in Insert · a add · dd/x trash tag",
      "j/k move tags · / search · t/q/Esc return to sessions · R refresh",
    }
    title = "Session Tags"
  else
    lines = {
      "Enter connect · t manage tags · dd delete session",
      "c create · r rename · A archives · R refresh",
      "j/k move sessions · / search · q/Esc close",
    }
    title = "Nvim Sessions"
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = title })
end

local function require_tag_mode(state)
  if state.mode == "tags" then
    return true
  end
  vim.notify("按 t 进入 Tag 模式后再操作 tag", vim.log.levels.INFO)
  return false
end

local function set_dashboard_keymaps(state)
  local function map(keys, callback, description)
    vim.keymap.set("n", keys, callback, { buffer = state.bufnr, nowait = true, desc = description })
  end
  map("q", function()
    if state.mode == "tags" then
      leave_tag_mode(state)
    else
      close_dashboard(state)
    end
  end, "Close session dashboard")
  map("<Esc>", function()
    if state.mode == "tags" then
      leave_tag_mode(state)
    else
      close_dashboard(state)
    end
  end, "Close session dashboard")
  map("j", function()
    move_selection(state, 1)
  end, "Next session item")
  map("<Down>", function()
    move_selection(state, 1)
  end, "Next session item")
  map("k", function()
    move_selection(state, -1)
  end, "Previous session item")
  map("<Up>", function()
    move_selection(state, -1)
  end, "Previous session item")
  map("gg", function()
    move_selection(state, 1, "first")
  end, "First session item")
  map("G", function()
    move_selection(state, -1, "last")
  end, "Last session item")
  map("<CR>", function()
    select_context(state)
  end, "Connect session or edit progress")
  map("t", function()
    toggle_tag_mode(state)
  end, "Toggle session tag mode")
  map("a", function()
    if require_tag_mode(state) then
      add_entry(state)
    end
  end, "Add session progress")
  map("e", function()
    if require_tag_mode(state) then
      edit_entry(state, false)
    end
  end, "Edit session progress")
  map("i", function()
    if require_tag_mode(state) then
      edit_entry(state, true)
    end
  end, "Edit session progress in Insert mode")
  map("x", function()
    if require_tag_mode(state) then
      delete_entry(state)
    end
  end, "Trash session progress")
  map("c", function()
    if state.mode == "sessions" then
      create_session(state)
    end
  end, "Create session")
  map("r", function()
    if state.mode == "sessions" then
      rename_session(state)
    end
  end, "Rename session")
  map("<C-r>", function()
    if state.mode == "sessions" then
      rename_session(state)
    end
  end, "Rename session")
  map("dd", function()
    if state.mode == "tags" then
      delete_entry(state)
    else
      delete_session(state)
    end
  end, "Delete session or tag")
  map("A", function()
    if state.mode == "sessions" then
      state.show_archives = not state.show_archives
      load_sessions(state)
      render_dashboard(state)
    end
  end, "Toggle archived session progress")
  map("R", function()
    load_sessions(state)
    render_dashboard(state)
  end, "Refresh session dashboard")
  map("?", function()
    show_help(state)
  end, "Session dashboard help")
end

local function schedule_cursor_focus_sync(state)
  if not dashboard_valid(state) then
    return
  end
  local row = vim.api.nvim_win_get_cursor(state.winid)[1]
  local item = state.line_map[row]
  if not item or not item.session_id or item.session_id == state.focused_session_id then
    return
  end

  state.pending_focus_id = item.session_id
  if state.focus_sync_scheduled then
    return
  end
  state.focus_sync_scheduled = true
  vim.schedule(function()
    state.focus_sync_scheduled = false
    local session_id = state.pending_focus_id
    state.pending_focus_id = nil
    if not dashboard_valid(state) or not session_id or session_id == state.focused_session_id then
      return
    end
    local session = session_by_id(state, session_id)
    if not session then
      return
    end
    state.focused_session_id = session_id
    local key = "session:" .. session_id
    if state.mode == "tags" and session.notes and session.notes[1] then
      key = "entry:" .. session.notes[1].id
    end
    render_dashboard(state, key)
  end)
end

local function start_dashboard_timer(state)
  state.timer = uv.new_timer()
  state.timer:start(
    220,
    220,
    vim.schedule_wrap(function()
      if state.timer_closed or not dashboard_valid(state) then
        stop_dashboard_timer(state)
        return
      end
      if #vim.api.nvim_list_uis() == 0 then
        return
      end

      state.animation_frame = state.animation_frame + 1
      local should_render = false
      for _, session in ipairs(state.sessions) do
        if not session.archived then
          local previous = session.agent_state or {}
          local current = config.read_agent_state(session.address)
          session.agent_state = current
          if
            previous.state ~= current.state
            or previous.unread ~= current.unread
            or current.state == "working"
            or (current.state == "ready" and current.unread)
          then
            should_render = true
          end
        end
      end
      if should_render then
        render_dashboard(state)
      end
    end)
  )
end

function M.setup(opts)
  assert(type(opts) == "table", "session dashboard setup requires options")
  assert(type(opts.discover_sessions) == "function", "discover_sessions callback is required")
  assert(type(opts.stop_current_session) == "function", "stop_current_session callback is required")
  config = opts
  config.normalize_name = config.normalize_name or trim
  config.read_agent_state = config.read_agent_state or function()
    return { state = "idle", unread = false }
  end
  local session_root = opts.session_dir
  if not session_root or session_root == "" then
    session_root = path_join(vim.fn.stdpath("state"), "nvim", "sessions")
  end
  store = Store.new(opts.notes_dir or path_join(session_root, "notes"))
  return M
end

function M.open(opts)
  opts = opts or {}
  assert(config and store, "session dashboard is not configured")
  if dashboard_valid(active_dashboard) then
    vim.api.nvim_set_current_win(active_dashboard.winid)
    if opts.current_notes then
      for _, session in ipairs(active_dashboard.sessions) do
        if session.current then
          active_dashboard.mode = "tags"
          active_dashboard.focused_session_id = session.session_id
          local key = session.notes[1] and "entry:" .. session.notes[1].id or "session:" .. session.session_id
          render_dashboard(active_dashboard, key)
          break
        end
      end
    end
    return
  end

  local columns = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight
  local width = math.min(math.max(1, columns - 4), math.max(50, math.floor(columns * 0.9)))
  local height = math.min(math.max(1, lines - 4), math.max(12, math.floor(lines * 0.82)))
  local bufnr = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, bufnr, "dotfiles://session-dashboard")
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = "dotfiles-session-dashboard"

  local state = {
    bufnr = bufnr,
    line_map = {},
    sessions = {},
    mode = opts.current_notes and "tags" or "sessions",
    focused_session_id = nil,
    show_archives = false,
    animation_frame = 1,
    timer_closed = false,
  }
  -- Discover before the floating window becomes current so CURRENT keeps the
  -- user's actual working buffer instead of reporting the dashboard itself.
  load_sessions(state)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = truncate_display(" Nvim Sessions ", math.max(1, width - 4)),
    title_pos = "center",
    width = width,
    height = height,
    row = math.max(0, math.floor((lines - height) / 2)),
    col = math.max(0, math.floor((columns - width) / 2)),
    zindex = 50,
  })
  vim.wo[winid].cursorline = true
  vim.wo[winid].wrap = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"

  state.winid = winid
  active_dashboard = state

  local preferred_key = state.focused_session_id and "session:" .. state.focused_session_id or nil
  if opts.current_notes then
    for _, session in ipairs(state.sessions) do
      if session.current then
        state.focused_session_id = session.session_id
        preferred_key = session.notes[1] and "entry:" .. session.notes[1].id or "session:" .. session.session_id
        break
      end
    end
  end
  render_dashboard(state, preferred_key)
  set_dashboard_keymaps(state)
  start_dashboard_timer(state)

  local group = vim.api.nvim_create_augroup("DotfilesSessionDashboard" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function()
      stop_dashboard_timer(state)
      if active_dashboard == state then
        active_dashboard = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    buffer = bufnr,
    callback = function()
      if dashboard_valid(state) then
        local resized_columns = vim.o.columns
        local resized_lines = vim.o.lines - vim.o.cmdheight
        local resized_width =
          math.min(math.max(1, resized_columns - 4), math.max(50, math.floor(resized_columns * 0.9)))
        local resized_height = math.min(math.max(1, resized_lines - 4), math.max(12, math.floor(resized_lines * 0.82)))
        pcall(vim.api.nvim_win_set_config, state.winid, {
          relative = "editor",
          width = resized_width,
          height = resized_height,
          row = math.max(0, math.floor((resized_lines - resized_height) / 2)),
          col = math.max(0, math.floor((resized_columns - resized_width) / 2)),
        })
      end
      render_dashboard(state)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = bufnr,
    callback = function()
      schedule_cursor_focus_sync(state)
    end,
  })
end

function M._new_store(root)
  return Store.new(root)
end

function M._active_dashboard()
  return active_dashboard
end

return M
