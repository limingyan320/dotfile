local M = {}

local config
local active_state
local state_sequence = 0
local filename_highlight_ns
local scoreboard_state
local scoreboard_highlight_ns
local scoreboard_key_ns
local SELECTED_FILENAME_HIGHLIGHT = "DotfilesBufferPickerSelectedFilename"
local TELESCOPE_SELECTION_PRIORITY = 4095
local FILENAME_HIGHLIGHT_PRIORITY = 4096
local MARK_DESCRIPTIONS_VAR = "dotfiles_mark_descriptions"
local SCOREBOARD_INITIAL_TIMEOUT_MS = 650
local SCOREBOARD_REPEAT_TIMEOUT_MS = 130
local SCOREBOARD_NAVIGATION_TIMEOUT_MS = 650

local DELETE_CANCEL = "Cancel"
local DELETE_SAVE = "Save and delete"
local DELETE_DISCARD = "Discard changes and delete"
local TERMINAL_CLOSE = "Close terminal"

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Buffer manager" })
end

function M.add_mark()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].buftype ~= "" or not vim.bo[bufnr].buflisted then
    notify("只能在普通 listed buffer 中添加 mark", vim.log.levels.WARN)
    return nil
  end

  local free_mark
  for code = string.byte("a"), string.byte("z") do
    local mark = string.char(code)
    local position = vim.api.nvim_buf_get_mark(bufnr, mark)
    if position[1] == 0 then
      free_mark = mark
      break
    end
  end
  if not free_mark then
    notify("当前 buffer 的 a-z marks 已全部占用（26/26）", vim.log.levels.WARN)
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local ok, set = pcall(vim.api.nvim_buf_set_mark, bufnr, free_mark, cursor[1], cursor[2], {})
  if not ok or not set then
    notify(("无法添加 mark %s"):format(free_mark), vim.log.levels.ERROR)
    return nil
  end
  notify(("已添加 mark %s · %d:%d"):format(free_mark, cursor[1], cursor[2] + 1))
  return free_mark
end

local function protected_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return true
  end
  return config.is_protected_buffer(bufnr)
end

local function valid_editor_window(win)
  return win
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_config(win).relative == ""
    and config.is_editor_window(win)
end

local function current_tab_regular_window(state)
  local tab = state.tab
  if not tab or not vim.api.nvim_tabpage_is_valid(tab) then
    tab = vim.api.nvim_get_current_tabpage()
    state.tab = tab
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
  return nil
end

local function configure_temporary_buffer(bufnr)
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
end

local function create_temporary_editor(state)
  local base = current_tab_regular_window(state)
  if not base then
    notify("当前 tab 没有可用于创建编辑 split 的窗口", vim.log.levels.ERROR)
    return nil
  end

  local ok, created = pcall(vim.api.nvim_win_call, base, function()
    vim.cmd("aboveleft new")
    local win = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_get_current_buf()
    configure_temporary_buffer(bufnr)
    return { win = win, bufnr = bufnr }
  end)
  if not ok or not created or not valid_editor_window(created.win) then
    notify("无法创建安全的临时编辑 split: " .. tostring(created), vim.log.levels.ERROR)
    return nil
  end

  state.temporary_windows[created.win] = created.bufnr
  return created.win
end

local function ensure_target_window(state)
  if valid_editor_window(state.target_win) then
    return state.target_win
  end

  local candidate = config.find_editor_window()
  if valid_editor_window(candidate) then
    state.target_win = candidate
    return candidate
  end

  state.target_win = create_temporary_editor(state)
  return state.target_win
end

local function close_temporary_windows(state, retained_win)
  for win, bufnr in pairs(state.temporary_windows) do
    if win ~= retained_win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      pcall(vim.api.nvim_win_close, win, true)
    end
    state.temporary_windows[win] = nil
  end
end

local function restore_source_window(state)
  local source = state.source_win
  if source and vim.api.nvim_win_is_valid(source) then
    pcall(vim.api.nvim_set_current_win, source)
  end
end

local function temporary_buffer(state, bufnr)
  for _, temporary_bufnr in pairs(state.temporary_windows) do
    if temporary_bufnr == bufnr then
      return true
    end
  end
  return false
end

local function buffer_info(state)
  local current_buf = valid_editor_window(state.target_win) and vim.api.nvim_win_get_buf(state.target_win) or nil
  local alternate_buf = vim.fn.bufnr("#")
  local buffers = {}

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.fn.buflisted(bufnr) == 1 and not protected_buffer(bufnr) and not temporary_buffer(state, bufnr) then
      local info = vim.fn.getbufinfo(bufnr)[1]
      if info then
        buffers[#buffers + 1] = {
          bufnr = bufnr,
          flag = bufnr == current_buf and "%" or (bufnr == alternate_buf and "#" or " "),
          info = info,
        }
      end
    end
  end

  table.sort(buffers, function(left, right)
    if left.bufnr == current_buf then
      return true
    elseif right.bufnr == current_buf then
      return false
    end
    if left.info.lastused == right.info.lastused then
      return left.bufnr < right.bufnr
    end
    return left.info.lastused > right.info.lastused
  end)
  return buffers
end

local function inline_text(value)
  return vim.trim(tostring(value or ""):gsub("[%c]", " "):gsub("%s+", " "))
end

local function mark_descriptions(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end
  local descriptions = vim.b[bufnr][MARK_DESCRIPTIONS_VAR]
  return type(descriptions) == "table" and descriptions or {}
end

local function set_mark_description(bufnr, mark, description)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "buffer is no longer valid"
  end
  local descriptions = vim.deepcopy(mark_descriptions(bufnr))
  description = inline_text(description)
  descriptions[mark] = description ~= "" and description or nil
  local ok, err = pcall(function()
    vim.b[bufnr][MARK_DESCRIPTIONS_VAR] = descriptions
  end)
  return ok, err
end

local function current_mark_position(bufnr, mark)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or type(mark) ~= "string" or not mark:match("^[a-z]$") then
    return nil
  end
  local ok, position = pcall(vim.api.nvim_buf_get_mark, bufnr, mark)
  if not ok or type(position) ~= "table" or not position[1] or position[1] <= 0 then
    return nil
  end
  return position
end

local function buffer_local_marks(entry)
  local bufnr = entry.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return {}
  end

  local ok, mark_list = pcall(vim.fn.getmarklist, bufnr)
  if not ok then
    return {}
  end
  local descriptions = mark_descriptions(bufnr)
  local marks = {}
  for _, item in ipairs(mark_list) do
    local mark = type(item.mark) == "string" and item.mark:match("^'([a-z])$") or nil
    local position = item.pos
    local lnum = type(position) == "table" and tonumber(position[2]) or nil
    local col = type(position) == "table" and tonumber(position[3]) or nil
    if mark and lnum and lnum > 0 and col then
      local source_line = ""
      if vim.api.nvim_buf_is_loaded(bufnr) then
        source_line = inline_text(vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1])
      end
      marks[#marks + 1] = {
        kind = "mark",
        key = ("mark:%d:%s"):format(bufnr, mark),
        bufnr = bufnr,
        buffer = entry,
        mark = mark,
        lnum = lnum,
        col = math.max(1, col),
        description = inline_text(descriptions[mark]),
        source_line = source_line,
      }
    end
  end
  table.sort(marks, function(left, right)
    return left.mark < right.mark
  end)
  for index, mark in ipairs(marks) do
    mark.branch = index == #marks and "└" or "├"
  end
  return marks
end

local function mark_display(entry)
  local text = ""
  local highlights = {}
  local function append(value, highlight)
    local start_col = #text
    text = text .. value
    if highlight then
      highlights[#highlights + 1] = { { start_col, #text }, highlight }
    end
  end

  append("    " .. entry.branch .. " ", "TelescopeResultsComment")
  append(entry.mark, "TelescopeResultsIdentifier")
  append("  ", "TelescopeResultsComment")
  append(("%d:%d"):format(entry.lnum, entry.col), "TelescopeResultsNumber")
  append("  ", "TelescopeResultsComment")
  local summary = entry.description ~= "" and entry.description
    or entry.source_line ~= "" and entry.source_line
    or "(empty line)"
  append(summary, entry.description ~= "" and "TelescopeNormal" or "TelescopeResultsComment")
  return text, highlights
end

local function buffer_display_path(entry)
  local name = entry.info.name
  if name == "" then
    return "[No Name]"
  end
  name = vim.fs.normalize(name)
  local cwd = vim.uv.cwd() or vim.fn.getcwd()
  return vim.fs.relpath(vim.fs.normalize(cwd), name) or name
end

local function buffer_lnum(entry)
  local lnum = tonumber(entry.info.lnum) or 0
  if lnum > 0 and vim.api.nvim_buf_is_loaded(entry.bufnr) then
    lnum = math.max(1, math.min(lnum, vim.api.nvim_buf_line_count(entry.bufnr)))
  end
  return lnum
end

local function scoreboard_buffer_row(entry, bufnr_width, mark_count)
  local text = ""
  local highlights = {}
  local function append(value, highlight)
    local start_col = #text
    text = text .. value
    if highlight then
      highlights[#highlights + 1] = { { start_col, #text }, highlight }
    end
  end

  local hidden = entry.info.hidden == 1 and "h" or "a"
  local readonly = vim.bo[entry.bufnr].readonly and "=" or " "
  local changed = entry.info.changed == 1 and "+" or " "
  append(("%" .. bufnr_width .. "d"):format(entry.bufnr), "TelescopeResultsNumber")
  append(" " .. entry.flag .. hidden .. readonly .. changed .. " ", "TelescopeResultsComment")

  local path = buffer_display_path(entry)
  local filename = vim.fs.basename(path)
  local directory_end = math.max(0, #path - #filename)
  if directory_end > 0 then
    append(path:sub(1, directory_end), "TelescopeResultsComment")
  end
  append(path:sub(directory_end + 1), "TelescopeResultsIdentifier")
  append(":" .. buffer_lnum(entry), "TelescopeResultsNumber")
  if mark_count > 0 then
    append(("  ◆ %d"):format(mark_count), "DiagnosticHint")
  end

  return {
    text = text,
    highlights = highlights,
    current = entry.flag == "%",
    item = {
      kind = "buffer",
      bufnr = entry.bufnr,
    },
  }
end

local function scoreboard_rows(state)
  local buffers = buffer_info(state)
  local bufnr_width = 1
  for _, entry in ipairs(buffers) do
    bufnr_width = math.max(bufnr_width, #tostring(entry.bufnr))
  end

  local rows = {}
  local mark_count = 0
  for _, entry in ipairs(buffers) do
    local marks = buffer_local_marks(entry)
    mark_count = mark_count + #marks
    rows[#rows + 1] = scoreboard_buffer_row(entry, bufnr_width, #marks)
    for _, mark in ipairs(marks) do
      local text, highlights = mark_display(mark)
      rows[#rows + 1] = { text = text, highlights = highlights, item = mark }
    end
  end
  if #rows == 0 then
    rows[1] = {
      text = "No session buffers",
      highlights = { { { 0, #"No session buffers" }, "TelescopeResultsComment" } },
    }
  end
  return rows, #buffers, mark_count
end

local function scoreboard_dimensions(row_count)
  local columns = vim.o.columns
  local available_height = math.max(1, vim.o.lines - vim.o.cmdheight - 2)
  if columns < 8 or available_height < 3 then
    return nil
  end

  local width = math.min(math.max(1, columns - 4), math.max(32, math.floor(columns * 0.82)))
  local max_height = math.max(1, math.floor(available_height * 0.72))
  local height = math.max(1, math.min(row_count, max_height))
  return {
    width = width,
    height = height,
    row = math.max(0, math.floor((available_height - height) / 2)),
    col = math.max(0, math.floor((columns - width) / 2)),
  }
end

local function apply_scoreboard_highlights(bufnr, rows, selected_index)
  scoreboard_highlight_ns = scoreboard_highlight_ns
    or vim.api.nvim_create_namespace("dotfiles_buffer_scoreboard_highlight")
  vim.api.nvim_buf_clear_namespace(bufnr, scoreboard_highlight_ns, 0, -1)
  for row_index, row in ipairs(rows) do
    local zero_row = row_index - 1
    if row_index == selected_index then
      vim.api.nvim_buf_set_extmark(bufnr, scoreboard_highlight_ns, zero_row, 0, {
        end_col = #row.text,
        hl_eol = true,
        hl_group = "TelescopeSelection",
        priority = 50,
      })
    end
    for _, highlight in ipairs(row.highlights or {}) do
      vim.api.nvim_buf_set_extmark(bufnr, scoreboard_highlight_ns, zero_row, highlight[1][1], {
        end_col = highlight[1][2],
        hl_group = highlight[2],
        hl_mode = "combine",
        priority = 100,
      })
    end
  end
end

local close_scoreboard
local move_scoreboard_selection
local confirm_scoreboard_selection

local SCOREBOARD_LOCAL_KEYS = { "j", "k", "<Down>", "<Up>", "<CR>", "<Esc>", "q" }

local function restore_buffer_mapping(bufnr, lhs, mapping)
  pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", lhs)
  if not mapping then
    return
  end

  local opts = {
    buffer = bufnr,
    silent = mapping.silent == 1,
    expr = mapping.expr == 1,
    nowait = mapping.nowait == 1,
    remap = mapping.noremap == 0,
    script = mapping.script == 1,
  }
  if mapping.desc and mapping.desc ~= "" then
    opts.desc = mapping.desc
  end
  if mapping.expr == 1 then
    opts.replace_keycodes = mapping.replace_keycodes == 1
  end
  pcall(vim.keymap.set, "n", lhs, mapping.callback or mapping.rhs or "", opts)
end

local function restore_scoreboard_keymaps(state)
  local bufnr = state and state.source_buf
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not state.saved_keymaps then
    return
  end
  for _, lhs in ipairs(SCOREBOARD_LOCAL_KEYS) do
    restore_buffer_mapping(bufnr, lhs, state.saved_keymaps[lhs])
  end
  state.saved_keymaps = nil
end

local function install_scoreboard_keymaps(state)
  local existing = {}
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.source_buf, "n")) do
    existing[mapping.lhs] = mapping
  end
  state.saved_keymaps = {}
  for _, lhs in ipairs(SCOREBOARD_LOCAL_KEYS) do
    state.saved_keymaps[lhs] = existing[lhs] or false
  end

  local opts = { buffer = state.source_buf, nowait = true, silent = true }
  vim.keymap.set("n", "j", function()
    move_scoreboard_selection(1, vim.v.count1)
  end, vim.tbl_extend("force", opts, { desc = "Scoreboard next item" }))
  vim.keymap.set("n", "k", function()
    move_scoreboard_selection(-1, vim.v.count1)
  end, vim.tbl_extend("force", opts, { desc = "Scoreboard previous item" }))
  vim.keymap.set("n", "<Down>", function()
    move_scoreboard_selection(1, vim.v.count1)
  end, vim.tbl_extend("force", opts, { desc = "Scoreboard next item" }))
  vim.keymap.set("n", "<Up>", function()
    move_scoreboard_selection(-1, vim.v.count1)
  end, vim.tbl_extend("force", opts, { desc = "Scoreboard previous item" }))
  vim.keymap.set("n", "<CR>", function()
    confirm_scoreboard_selection()
  end, vim.tbl_extend("force", opts, { desc = "Open scoreboard item" }))
  vim.keymap.set("n", "<Esc>", function()
    close_scoreboard()
  end, vim.tbl_extend("force", opts, { desc = "Close scoreboard" }))
  vim.keymap.set("n", "q", function()
    close_scoreboard()
  end, vim.tbl_extend("force", opts, { desc = "Close scoreboard" }))
end

local function stop_scoreboard_timer(state)
  local timer = state and state.timer
  if not timer then
    return
  end
  state.timer = nil
  pcall(timer.stop, timer)
  if not timer:is_closing() then
    timer:close()
  end
end

close_scoreboard = function()
  local state = scoreboard_state
  if not state then
    return
  end
  scoreboard_state = nil
  stop_scoreboard_timer(state)
  restore_scoreboard_keymaps(state)
  if scoreboard_key_ns then
    pcall(vim.on_key, nil, scoreboard_key_ns)
  end
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  elseif state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  close_temporary_windows(state)
end

local function arm_scoreboard_timer(state, timeout_ms)
  state.timer_generation = state.timer_generation + 1
  local generation = state.timer_generation
  state.timer:stop()
  state.timer:start(
    timeout_ms,
    0,
    vim.schedule_wrap(function()
      if scoreboard_state == state and state.timer_generation == generation then
        close_scoreboard()
      end
    end)
  )
end

local function watch_scoreboard_input(state)
  scoreboard_key_ns = scoreboard_key_ns or vim.api.nvim_create_namespace("dotfiles_buffer_scoreboard_key")
  vim.on_key(function(_, typed)
    local key = vim.fn.keytrans(typed)
    if
      scoreboard_state ~= state
      or typed == ""
      or key == "<Tab>"
      or key == "j"
      or key == "k"
      or key == "<Down>"
      or key == "<Up>"
      or key == "<CR>"
      or key == "<Esc>"
      or key == "q"
      or key:match("^%d$")
    then
      return
    end
    vim.schedule(function()
      if scoreboard_state == state then
        close_scoreboard()
      end
    end)
  end, scoreboard_key_ns)
end

move_scoreboard_selection = function(direction, count)
  local state = scoreboard_state
  if not state or not state.selectable_rows or #state.selectable_rows == 0 then
    return
  end
  local next_position = state.selection_position + direction * math.max(1, count or 1)
  next_position = math.max(1, math.min(next_position, #state.selectable_rows))
  state.selection_position = next_position
  state.selected_index = state.selectable_rows[next_position]
  apply_scoreboard_highlights(state.buf, state.rows, state.selected_index)
  pcall(vim.api.nvim_win_set_cursor, state.win, { state.selected_index, 0 })
  arm_scoreboard_timer(state, SCOREBOARD_NAVIGATION_TIMEOUT_MS)
end

confirm_scoreboard_selection = function()
  local state = scoreboard_state
  local row = state and state.rows and state.rows[state.selected_index]
  local selection = row and row.item
  local bufnr = selection and selection.bufnr
  if not state or protected_buffer(bufnr) then
    notify("没有可打开的 buffer", vim.log.levels.WARN)
    close_scoreboard()
    return
  end

  local mark_position
  if selection.kind == "mark" then
    mark_position = current_mark_position(bufnr, selection.mark)
    if not mark_position then
      notify(("mark %s 已不存在"):format(selection.mark), vim.log.levels.WARN)
      close_scoreboard()
      return
    end
  end

  local target = ensure_target_window(state)
  if not target or not valid_editor_window(target) then
    notify("找不到安全的目标窗口", vim.log.levels.ERROR)
    close_scoreboard()
    return
  end
  if protected_buffer(bufnr) then
    notify("目标 buffer 已失效", vim.log.levels.WARN)
    close_scoreboard()
    return
  end

  local ok, err = pcall(vim.api.nvim_win_set_buf, target, bufnr)
  if not ok or not valid_editor_window(target) then
    notify("无法在安全目标窗口打开 buffer: " .. tostring(err), vim.log.levels.ERROR)
    close_scoreboard()
    return
  end
  state.temporary_windows[target] = nil
  close_scoreboard()
  if not vim.api.nvim_win_is_valid(target) then
    return
  end
  vim.api.nvim_set_current_win(target)

  if mark_position then
    local cursor_ok, cursor_err = pcall(vim.api.nvim_win_set_cursor, target, mark_position)
    if not cursor_ok then
      notify("无法跳转到 mark: " .. tostring(cursor_err), vim.log.levels.ERROR)
    else
      pcall(vim.api.nvim_win_call, target, function()
        vim.cmd("normal! zv")
      end)
    end
  end
  if vim.bo[bufnr].buftype == "terminal" then
    vim.schedule(function()
      if
        vim.api.nvim_win_is_valid(target)
        and vim.api.nvim_get_current_win() == target
        and vim.api.nvim_win_get_buf(target) == bufnr
      then
        vim.cmd("startinsert")
      end
    end)
  end
end

local function open_scoreboard()
  local source_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(source_win).relative ~= "" then
    return nil
  end
  local state = {
    source_win = source_win,
    source_buf = vim.api.nvim_win_get_buf(source_win),
    tab = vim.api.nvim_get_current_tabpage(),
    target_win = valid_editor_window(source_win) and source_win or nil,
    temporary_windows = {},
  }
  local rows, buffer_count, mark_count = scoreboard_rows(state)
  local dimensions = scoreboard_dimensions(#rows)
  if not dimensions then
    return nil
  end

  local selectable_rows = {}
  local selection_position = 1
  for index, row in ipairs(rows) do
    if row.item then
      selectable_rows[#selectable_rows + 1] = index
      if row.current then
        selection_position = #selectable_rows
      end
    end
  end
  local selected_index = selectable_rows[selection_position]

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(
    bufnr,
    0,
    -1,
    false,
    vim.tbl_map(function(row)
      return row.text
    end, rows)
  )
  apply_scoreboard_highlights(bufnr, rows, selected_index)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].filetype = "dotfiles-buffer-scoreboard"

  local ok, winid = pcall(vim.api.nvim_open_win, bufnr, false, {
    relative = "editor",
    width = dimensions.width,
    height = dimensions.height,
    row = dimensions.row,
    col = dimensions.col,
    style = "minimal",
    border = "rounded",
    title = " Session buffers ",
    title_pos = "center",
    focusable = false,
    noautocmd = true,
    zindex = 90,
  })
  if not ok then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    return nil
  end
  vim.wo[winid].wrap = false
  vim.wo[winid].cursorline = false
  vim.wo[winid].winhighlight = table.concat({
    "Normal:TelescopeNormal",
    "NormalFloat:TelescopeNormal",
    "FloatBorder:TelescopeBorder",
    "FloatTitle:TelescopeTitle",
  }, ",")

  state.buf = bufnr
  state.win = winid
  state.rows = rows
  state.selectable_rows = selectable_rows
  state.selection_position = selection_position
  state.selected_index = selected_index
  state.buffer_count = buffer_count
  state.mark_count = mark_count
  state.pulse_count = 1
  state.timer = vim.uv.new_timer()
  state.timer_generation = 0
  if not state.timer then
    pcall(vim.api.nvim_win_close, winid, true)
    return nil
  end
  state.augroup = vim.api.nvim_create_augroup(("DotfilesBufferScoreboard%d"):format(bufnr), { clear = true })
  vim.api.nvim_create_autocmd({ "ModeChanged", "TabLeave", "VimResized", "VimLeavePre" }, {
    group = state.augroup,
    callback = function(args)
      if
        scoreboard_state == state
        and (args.event ~= "ModeChanged" or not vim.api.nvim_get_mode().mode:match("^n"))
      then
        close_scoreboard()
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.augroup,
    pattern = { tostring(source_win), tostring(winid) },
    once = true,
    callback = function()
      if scoreboard_state == state then
        close_scoreboard()
      end
    end,
  })

  scoreboard_state = state
  install_scoreboard_keymaps(state)
  watch_scoreboard_input(state)
  if selected_index then
    pcall(vim.api.nvim_win_set_cursor, winid, { selected_index, 0 })
  end
  arm_scoreboard_timer(state, SCOREBOARD_INITIAL_TIMEOUT_MS)
  return state
end

function M.hold_scoreboard()
  if active_state and not active_state.finished then
    return nil
  end
  local state = scoreboard_state
  if state and state.win and vim.api.nvim_win_is_valid(state.win) then
    state.pulse_count = state.pulse_count + 1
    arm_scoreboard_timer(state, SCOREBOARD_REPEAT_TIMEOUT_MS)
    return state
  end
  if state then
    close_scoreboard()
  end
  return open_scoreboard()
end

function M.close_scoreboard()
  close_scoreboard()
end

local function make_finder(state)
  local finders = require("telescope.finders")
  local make_entry = require("telescope.make_entry")
  local telescope_utils = require("telescope.utils")
  local buffers = buffer_info(state)
  local entries = {}
  local max_bufnr = 1
  for _, entry in ipairs(buffers) do
    max_bufnr = math.max(max_bufnr, entry.bufnr)
  end

  local entry_opts = {
    bufnr_width = #tostring(max_bufnr),
    cwd = vim.uv.cwd(),
    path_display = function(_, path)
      local filename = telescope_utils.path_tail(path)
      local filename_start = math.max(0, #path - #filename)
      return path,
        {
          { { 0, filename_start }, "TelescopeResultsComment" },
          { { filename_start, #path }, "TelescopeResultsIdentifier" },
        }
    end,
  }
  local buffer_entry_maker = make_entry.gen_from_buffer(entry_opts)

  for _, buffer in ipairs(buffers) do
    local marks = buffer_local_marks(buffer)
    for index = #marks, 1, -1 do
      entries[#entries + 1] = marks[index]
    end
    entries[#entries + 1] = {
      kind = "buffer",
      key = "buffer:" .. buffer.bufnr,
      bufnr = buffer.bufnr,
      buffer = buffer,
      mark_count = #marks,
    }
  end

  return finders.new_table({
    results = entries,
    entry_maker = function(item)
      local buffer_entry = buffer_entry_maker(item.buffer)
      if item.kind == "buffer" then
        local original_display = buffer_entry.display
        buffer_entry.kind = "buffer"
        buffer_entry.key = item.key
        buffer_entry.mark_count = item.mark_count
        buffer_entry.display = function(display_entry)
          local display, highlights = original_display(display_entry)
          if item.mark_count == 0 then
            return display, highlights
          end
          local suffix = ("  ◆ %d"):format(item.mark_count)
          local suffix_start = #display
          highlights = highlights or {}
          highlights[#highlights + 1] = { { suffix_start, suffix_start + #suffix }, "DiagnosticHint" }
          return display .. suffix, highlights
        end
        return buffer_entry
      end

      return make_entry.set_default_entry_mt({
        value = item,
        ordinal = table.concat({
          tostring(item.bufnr),
          buffer_entry.filename or "",
          item.mark,
          item.description,
          item.source_line,
          tostring(item.lnum),
          tostring(item.col),
        }, " "),
        display = mark_display,
        kind = "mark",
        key = item.key,
        bufnr = item.bufnr,
        path = buffer_entry.path,
        filename = buffer_entry.filename,
        lnum = item.lnum,
        col = item.col,
        colend = item.col + 1,
        mark = item.mark,
        branch = item.branch,
        description = item.description,
        source_line = item.source_line,
      }, entry_opts)
    end,
  }),
    entries
end

local function selection_index(entries, preferred_bufnr, preferred_mark)
  if not preferred_bufnr then
    return 1
  end
  if preferred_mark then
    for index, entry in ipairs(entries) do
      if entry.kind == "mark" and entry.bufnr == preferred_bufnr and entry.mark == preferred_mark then
        return index
      end
    end
  end
  for index, entry in ipairs(entries) do
    if entry.kind == "buffer" and entry.bufnr == preferred_bufnr then
      return index
    end
  end
  return 1
end

local function window_options(picker)
  local width = vim.o.columns
  local height = math.max(3, vim.o.lines - vim.o.cmdheight)
  local strategies = require("telescope.pickers.layout_strategies")
  return strategies.vertical(picker, width, height, {
    vertical = {
      width = 0.82,
      height = picker.previewer and 0.82 or 0.62,
      preview_cutoff = 1,
      preview_height = 0.5,
      prompt_position = "bottom",
      mirror = false,
    },
  })
end

local function preserve_selected_filename_highlight(picker)
  filename_highlight_ns = filename_highlight_ns or vim.api.nvim_create_namespace("dotfiles_buffer_picker_filename")
  local highlighter = picker.highlighter
  local original_hi_display = highlighter.hi_display
  local original_hi_selection = highlighter.hi_selection
  local original_clear_display = highlighter.clear_display
  local filename_ranges = {}

  highlighter.hi_display = function(self, row, prefix, display_highlights)
    original_hi_display(self, row, prefix, display_highlights)
    filename_ranges[row] = nil
    for _, highlight in ipairs(display_highlights or {}) do
      if highlight[2] == "TelescopeResultsIdentifier" then
        filename_ranges[row] = { #prefix + highlight[1][1], #prefix + highlight[1][2] }
      end
    end
  end

  highlighter.hi_selection = function(self, row, caret)
    original_hi_selection(self, row, caret)

    local results_bufnr = self.picker.results_bufnr
    if not results_bufnr or not vim.api.nvim_buf_is_valid(results_bufnr) then
      return
    end
    vim.api.nvim_buf_clear_namespace(results_bufnr, filename_highlight_ns, 0, -1)
    local range = filename_ranges[row]
    if range then
      local selection_ns = vim.api.nvim_get_namespaces().telescope_selection
      if selection_ns then
        local selection_marks = vim.api.nvim_buf_get_extmarks(
          results_bufnr,
          selection_ns,
          { row, 0 },
          { row, -1 },
          { details = true }
        )
        for _, mark in ipairs(selection_marks) do
          local details = mark[4]
          if details.hl_group == "TelescopeSelection" then
            vim.api.nvim_buf_set_extmark(results_bufnr, selection_ns, mark[2], mark[3], {
              id = mark[1],
              end_row = details.end_row,
              end_col = details.end_col,
              hl_eol = details.hl_eol,
              hl_group = details.hl_group,
              priority = TELESCOPE_SELECTION_PRIORITY,
            })
          end
        end
      end

      local selection = vim.api.nvim_get_hl(0, { name = "TelescopeSelection", link = false })
      local identifier = vim.api.nvim_get_hl(0, { name = "TelescopeResultsIdentifier", link = false })
      local selected_filename = vim.tbl_extend("force", selection, identifier)
      selected_filename.bg = selection.bg
      selected_filename.ctermbg = selection.ctermbg
      vim.api.nvim_set_hl(0, SELECTED_FILENAME_HIGHLIGHT, selected_filename)
      vim.api.nvim_buf_set_extmark(results_bufnr, filename_highlight_ns, row, range[1], {
        end_col = range[2],
        hl_group = SELECTED_FILENAME_HIGHLIGHT,
        priority = FILENAME_HIGHLIGHT_PRIORITY,
      })
    end
  end

  highlighter.clear_display = function(self)
    local results_bufnr = self.picker.results_bufnr
    if results_bufnr and vim.api.nvim_buf_is_valid(results_bufnr) then
      vim.api.nvim_buf_clear_namespace(results_bufnr, filename_highlight_ns, 0, -1)
    end
    filename_ranges = {}
    return original_clear_display(self)
  end
end

local function clear_target_watch(state)
  if state.target_watch_group then
    pcall(vim.api.nvim_del_augroup_by_id, state.target_watch_group)
    state.target_watch_group = nil
  end
end

local function close_picker_only(state)
  local prompt_bufnr = state.prompt_bufnr
  clear_target_watch(state)
  state.prompt_bufnr = nil
  state.picker = nil
  if prompt_bufnr and vim.api.nvim_buf_is_valid(prompt_bufnr) then
    require("telescope.actions").close(prompt_bufnr)
  end
end

local function finish_cancel(state)
  if state.finished then
    return
  end
  state.finished = true
  if active_state == state then
    active_state = nil
  end
  clear_target_watch(state)
  close_temporary_windows(state)
  restore_source_window(state)
end

local function cancel(state)
  close_picker_only(state)
  finish_cancel(state)
end

local function safe_replacement_buffer(state, deleting_bufnr)
  for _, entry in ipairs(buffer_info(state)) do
    if entry.bufnr ~= deleting_bufnr then
      return entry.bufnr, false
    end
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  configure_temporary_buffer(bufnr)
  return bufnr, true
end

local function move_visible_windows_off_buffer(state, bufnr)
  local windows = vim.fn.win_findbuf(bufnr)
  if #windows == 0 then
    return {}, nil, false
  end

  local replacement, created = safe_replacement_buffer(state, bufnr)
  local moved = {}
  for _, win in ipairs(windows) do
    if
      vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_config(win).relative == ""
      and vim.api.nvim_win_get_buf(win) == bufnr
    then
      local ok = pcall(vim.api.nvim_win_set_buf, win, replacement)
      if ok then
        moved[#moved + 1] = win
      end
    end
  end
  return moved, replacement, created
end

local function restore_moved_windows(windows, replacement, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or protected_buffer(bufnr) then
    return
  end
  for _, win in ipairs(windows) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == replacement then
      pcall(vim.api.nvim_win_set_buf, win, bufnr)
    end
  end
end

local function delete_buffer(state, bufnr, force)
  if protected_buffer(bufnr) then
    notify("Terminal/agent buffer 不会被删除", vim.log.levels.WARN)
    return false
  end

  local moved, replacement, created = move_visible_windows_off_buffer(state, bufnr)
  local ok, err = pcall(vim.api.nvim_buf_delete, bufnr, { force = force })
  if not ok then
    restore_moved_windows(moved, replacement, bufnr)
    if created and vim.api.nvim_buf_is_valid(replacement) and #vim.fn.win_findbuf(replacement) == 0 then
      pcall(vim.api.nvim_buf_delete, replacement, { force = true })
    end
    notify("无法删除 buffer: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
end

local function refresh_picker(state, preferred_bufnr, preferred_mark)
  if not state.picker or not state.prompt_bufnr or not vim.api.nvim_buf_is_valid(state.prompt_bufnr) then
    return
  end
  state.preferred_bufnr = preferred_bufnr
  state.preferred_mark = preferred_mark
  local finder, entries = make_finder(state)
  state.picker.default_selection_index = selection_index(entries, preferred_bufnr, preferred_mark)
  state.picker:refresh(finder, { reset_prompt = false })
end

local function save_named_buffer(bufnr)
  local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("silent write")
  end)
  if not ok then
    notify("保存失败: " .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

local open_picker

local function reopen_picker(state, preferred_bufnr, preferred_mark)
  if state.finished or active_state ~= state then
    return
  end
  state.preferred_bufnr = preferred_bufnr
  state.preferred_mark = preferred_mark
  local target = ensure_target_window(state)
  if not target then
    finish_cancel(state)
    return
  end
  vim.api.nvim_set_current_win(target)
  open_picker(state)
end

local function save_unnamed_then_delete(state, bufnr)
  local target = ensure_target_window(state)
  if not target then
    finish_cancel(state)
    return
  end
  vim.api.nvim_set_current_win(target)
  vim.ui.input({
    prompt = "Save buffer as",
    completion = "file",
    kind = "dotfiles_buffer_save_as",
  }, function(path)
    if state.finished or active_state ~= state then
      return
    end
    if not path or vim.trim(path) == "" then
      reopen_picker(state, bufnr)
      return
    end
    if protected_buffer(bufnr) then
      notify("目标 buffer 已失效", vim.log.levels.WARN)
      reopen_picker(state)
      return
    end

    local absolute = vim.fn.fnamemodify(path, ":p")
    local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("silent write " .. vim.fn.fnameescape(absolute))
    end)
    if not ok then
      notify("保存失败: " .. tostring(err), vim.log.levels.ERROR)
      reopen_picker(state, bufnr)
      return
    end
    delete_buffer(state, bufnr, false)
    reopen_picker(state)
  end)
end

local function handle_delete_choice(state, bufnr, choice)
  if choice == nil or choice == DELETE_CANCEL then
    reopen_picker(state, bufnr)
    return
  end
  if protected_buffer(bufnr) then
    notify("目标 buffer 已失效", vim.log.levels.WARN)
    reopen_picker(state)
    return
  end

  if choice == DELETE_SAVE then
    if vim.api.nvim_buf_get_name(bufnr) == "" then
      save_unnamed_then_delete(state, bufnr)
      return
    end
    if not save_named_buffer(bufnr) then
      reopen_picker(state, bufnr)
      return
    end
    delete_buffer(state, bufnr, false)
  elseif choice == DELETE_DISCARD then
    delete_buffer(state, bufnr, true)
  end
  reopen_picker(state)
end

local function confirm_modified_delete(state, bufnr)
  state.preferred_bufnr = bufnr
  state.preferred_mark = nil
  close_picker_only(state)

  local target = ensure_target_window(state)
  if not target then
    finish_cancel(state)
    return
  end
  vim.api.nvim_set_current_win(target)
  vim.ui.select({ DELETE_CANCEL, DELETE_SAVE, DELETE_DISCARD }, {
    prompt = "Modified buffer: choose delete action",
    kind = "dotfiles_buffer_delete",
  }, function(choice)
    handle_delete_choice(state, bufnr, choice)
  end)
end

local function confirm_terminal_delete(state, bufnr)
  state.preferred_bufnr = bufnr
  state.preferred_mark = nil
  close_picker_only(state)

  local target = ensure_target_window(state)
  if not target then
    finish_cancel(state)
    return
  end
  vim.api.nvim_set_current_win(target)
  vim.ui.select({ DELETE_CANCEL, TERMINAL_CLOSE }, {
    prompt = "Running terminal: choose close action",
    kind = "dotfiles_terminal_buffer_delete",
  }, function(choice)
    if state.finished or active_state ~= state then
      return
    end
    if choice == TERMINAL_CLOSE then
      if protected_buffer(bufnr) then
        notify("目标 terminal buffer 已受保护", vim.log.levels.WARN)
      else
        delete_buffer(state, bufnr, true)
      end
      reopen_picker(state)
      return
    end
    reopen_picker(state, bufnr)
  end)
end

local function edit_mark_description(state)
  local selection = require("telescope.actions.state").get_selected_entry()
  if not selection or selection.kind ~= "mark" then
    notify("请选择一个 mark 子行来编辑说明", vim.log.levels.WARN)
    return
  end

  local bufnr = selection.bufnr
  local mark = selection.mark
  if not current_mark_position(bufnr, mark) then
    notify(("mark %s 已不存在"):format(mark), vim.log.levels.WARN)
    refresh_picker(state, bufnr)
    return
  end

  state.preferred_bufnr = bufnr
  state.preferred_mark = mark
  close_picker_only(state)
  local target = ensure_target_window(state)
  if not target then
    finish_cancel(state)
    return
  end
  vim.api.nvim_set_current_win(target)

  vim.ui.input({
    prompt = ("Mark %s description: "):format(mark),
    default = mark_descriptions(bufnr)[mark] or "",
    kind = "dotfiles_mark_description",
  }, function(description)
    if state.finished or active_state ~= state then
      return
    end
    if description == nil then
      reopen_picker(state, bufnr, mark)
      return
    end
    if not current_mark_position(bufnr, mark) then
      notify(("mark %s 已不存在"):format(mark), vim.log.levels.WARN)
      reopen_picker(state, bufnr)
      return
    end
    local ok, err = set_mark_description(bufnr, mark, description)
    if not ok then
      notify("保存 mark 说明失败: " .. tostring(err), vim.log.levels.ERROR)
    end
    reopen_picker(state, bufnr, mark)
  end)
end

local function delete_mark_selection(state, selection)
  local bufnr = selection.bufnr
  local mark = selection.mark
  if not current_mark_position(bufnr, mark) then
    notify(("mark %s 已不存在"):format(mark), vim.log.levels.WARN)
    refresh_picker(state, bufnr)
    return
  end

  local ok, deleted = pcall(vim.api.nvim_buf_del_mark, bufnr, mark)
  if not ok or not deleted then
    notify(("无法删除 mark %s"):format(mark), vim.log.levels.ERROR)
    return
  end
  local description_ok, description_err = set_mark_description(bufnr, mark, "")
  if not description_ok then
    notify("清理 mark 说明失败: " .. tostring(description_err), vim.log.levels.WARN)
  end
  refresh_picker(state, bufnr)
end

local function delete_selection(state)
  local action_state = require("telescope.actions.state")
  local selection = action_state.get_selected_entry()
  if selection and selection.kind == "mark" then
    delete_mark_selection(state, selection)
    return
  end
  local bufnr = selection and selection.bufnr
  if protected_buffer(bufnr) then
    notify("没有可删除的 buffer", vim.log.levels.WARN)
    return
  end

  if vim.bo[bufnr].buftype == "terminal" then
    confirm_terminal_delete(state, bufnr)
    return
  end

  if vim.bo[bufnr].modified then
    confirm_modified_delete(state, bufnr)
    return
  end
  if delete_buffer(state, bufnr, false) then
    refresh_picker(state)
  end
end

local function retain_temporary_window(state, win)
  state.temporary_windows[win] = nil
end

local function select_buffer(state)
  local selection = require("telescope.actions.state").get_selected_entry()
  local bufnr = selection and selection.bufnr
  if protected_buffer(bufnr) then
    notify("没有可打开的 buffer", vim.log.levels.WARN)
    return
  end

  local target = ensure_target_window(state)
  if not target or not valid_editor_window(target) then
    notify("找不到安全的目标窗口", vim.log.levels.ERROR)
    return
  end
  if protected_buffer(bufnr) then
    notify("目标 buffer 已失效", vim.log.levels.WARN)
    return
  end

  local mark_position
  if selection.kind == "mark" then
    mark_position = current_mark_position(bufnr, selection.mark)
    if not mark_position then
      notify(("mark %s 已不存在"):format(selection.mark), vim.log.levels.WARN)
      refresh_picker(state, bufnr)
      return
    end
  end

  local ok, err = pcall(vim.api.nvim_win_set_buf, target, bufnr)
  if not ok or not valid_editor_window(target) then
    notify("无法在安全目标窗口打开 buffer: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  retain_temporary_window(state, target)
  close_picker_only(state)
  state.finished = true
  if active_state == state then
    active_state = nil
  end
  close_temporary_windows(state, target)
  if vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_set_current_win(target)
  end
  if mark_position then
    vim.schedule(function()
      if not vim.api.nvim_win_is_valid(target) or vim.api.nvim_win_get_buf(target) ~= bufnr then
        return
      end
      local cursor_ok, cursor_err = pcall(vim.api.nvim_win_set_cursor, target, mark_position)
      if not cursor_ok then
        notify("无法跳转到 mark: " .. tostring(cursor_err), vim.log.levels.ERROR)
        return
      end
      pcall(vim.api.nvim_win_call, target, function()
        vim.cmd("normal! zv")
      end)
    end)
  end
  if vim.bo[bufnr].buftype == "terminal" then
    vim.schedule(function()
      if
        vim.api.nvim_win_is_valid(target)
        and vim.api.nvim_get_current_win() == target
        and vim.api.nvim_win_get_buf(target) == bufnr
      then
        vim.cmd("startinsert")
      end
    end)
  end
end

local function attach_mappings(state, prompt_bufnr, map)
  local actions = require("telescope.actions")
  local action_layout = require("telescope.actions.layout")
  local function do_cancel()
    cancel(state)
  end
  local function do_select()
    select_buffer(state)
  end
  local function do_delete()
    delete_selection(state)
  end
  local function do_edit_mark()
    edit_mark_description(state)
  end

  actions.select_default:replace(do_select)
  actions.select_horizontal:replace(do_select)
  actions.select_vertical:replace(do_select)
  actions.select_tab:replace(do_select)

  map("n", "q", do_cancel)
  map("n", "<Esc>", do_cancel)
  map("n", "dd", do_delete)
  map("n", "e", do_edit_mark)
  map("n", "p", function()
    action_layout.toggle_preview(prompt_bufnr)
  end)
  map("i", "<Esc>", do_cancel)
  map("i", "<C-c>", do_cancel)
  map("n", "<C-q>", actions.nop)
  map("i", "<C-q>", actions.nop)
  map("n", "<M-q>", actions.nop)
  map("i", "<M-q>", actions.nop)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = prompt_bufnr,
    once = true,
    callback = function()
      if active_state == state and state.prompt_bufnr == prompt_bufnr and not state.finished then
        state.prompt_bufnr = nil
        state.picker = nil
        vim.schedule(function()
          finish_cancel(state)
        end)
      end
    end,
  })
  return true
end

local function watch_target_window(state, prompt_bufnr)
  local target = state.target_win
  if not target then
    return
  end

  clear_target_watch(state)
  local group = vim.api.nvim_create_augroup(
    ("dotfiles_buffer_picker_target_%d_%d"):format(state.id, prompt_bufnr),
    { clear = true }
  )
  state.target_watch_group = group
  local rehome_scheduled = false
  local function rehome()
    if rehome_scheduled or active_state ~= state or state.prompt_bufnr ~= prompt_bufnr or state.finished then
      return
    end
    rehome_scheduled = true
    clear_target_watch(state)
    state.prompt_bufnr = nil
    state.picker = nil
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(prompt_bufnr) then
        require("telescope.actions").close(prompt_bufnr)
      end
      state.target_win = nil
      reopen_picker(state, state.preferred_bufnr, state.preferred_mark)
    end)
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(target),
    once = true,
    callback = rehome,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function()
      if not valid_editor_window(target) then
        rehome()
      end
    end,
  })
end

open_picker = function(state)
  local target = ensure_target_window(state)
  if not target then
    finish_cancel(state)
    return
  end
  local width = vim.o.columns
  local height = math.max(3, vim.o.lines - vim.o.cmdheight)
  if width < 3 or height < 3 then
    notify("Nvim 界面太小，无法显示 buffer picker", vim.log.levels.ERROR)
    finish_cancel(state)
    return
  end

  local pickers = require("telescope.pickers")
  local conf = require("telescope.config").values
  local finder, entries = make_finder(state)
  local opts = {
    initial_mode = "normal",
    prompt_title = "Buffers",
    results_title = "Session buffers",
    preview_title = "Live preview",
    finder = finder,
    sorter = conf.generic_sorter({}),
    previewer = conf.grep_previewer({}),
    preview = { hide_on_startup = true },
    default_selection_index = selection_index(entries, state.preferred_bufnr, state.preferred_mark),
    cache_picker = false,
    get_window_options = window_options,
    attach_mappings = function(prompt_bufnr, map)
      state.prompt_bufnr = prompt_bufnr
      watch_target_window(state, prompt_bufnr)
      return attach_mappings(state, prompt_bufnr, map)
    end,
  }
  if height < 6 or width < 9 then
    opts.border = false
  end

  vim.api.nvim_set_current_win(target)
  state.picker = pickers.new(opts, {})
  preserve_selected_filename_highlight(state.picker)
  state.picker:find()
  state.prompt_bufnr = state.picker.prompt_bufnr
end

function M.open()
  close_scoreboard()
  if active_state and not active_state.finished then
    local prompt = active_state.prompt_bufnr
    if prompt and vim.api.nvim_buf_is_valid(prompt) then
      local picker = active_state.picker
      if picker and picker.prompt_win and vim.api.nvim_win_is_valid(picker.prompt_win) then
        vim.api.nvim_set_current_win(picker.prompt_win)
      end
      return
    end
    finish_cancel(active_state)
  end

  state_sequence = state_sequence + 1
  local source_win = vim.api.nvim_get_current_win()
  local state = {
    id = state_sequence,
    source_win = source_win,
    tab = vim.api.nvim_get_current_tabpage(),
    target_win = valid_editor_window(source_win) and source_win or nil,
    temporary_windows = {},
    preferred_bufnr = valid_editor_window(source_win) and vim.api.nvim_win_get_buf(source_win) or nil,
    preferred_mark = nil,
    finished = false,
  }
  active_state = state
  open_picker(state)
end

function M.command_abbreviation()
  if vim.fn.getcmdtype() == ":" and vim.fn.getcmdline() == "ls" and vim.v.char == "\r" then
    return "DotfilesBuffers"
  end
  return "ls"
end

function M.setup(opts)
  config = vim.tbl_extend("force", {
    is_protected_buffer = function(bufnr)
      return vim.bo[bufnr].buftype == "terminal"
    end,
    is_editor_window = function(win)
      return vim.bo[vim.api.nvim_win_get_buf(win)].buftype ~= "terminal"
    end,
    find_editor_window = function()
      return nil
    end,
  }, opts or {})

  vim.api.nvim_create_user_command("DotfilesBuffers", M.open, {
    desc = "Interactive session buffer manager",
  })
  _G.dotfiles_buffer_ls_abbreviation = M.command_abbreviation
  vim.cmd([[cnoreabbrev <expr> ls v:lua.dotfiles_buffer_ls_abbreviation()]])
  return M
end

function M._active_state()
  return active_state
end

function M._scoreboard_state()
  return scoreboard_state
end

function M._delete_choices()
  return { DELETE_CANCEL, DELETE_SAVE, DELETE_DISCARD }
end

return M
