local M = {}

local config
local active_state
local state_sequence = 0

local DELETE_CANCEL = "Cancel"
local DELETE_SAVE = "Save and delete"
local DELETE_DISCARD = "Discard changes and delete"

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Buffer manager" })
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

local function make_finder(state)
  local finders = require("telescope.finders")
  local make_entry = require("telescope.make_entry")
  local entries = buffer_info(state)
  local max_bufnr = 1
  for _, entry in ipairs(entries) do
    max_bufnr = math.max(max_bufnr, entry.bufnr)
  end

  local entry_opts = {
    bufnr_width = #tostring(max_bufnr),
    cwd = vim.uv.cwd(),
  }
  return finders.new_table({
    results = entries,
    entry_maker = make_entry.gen_from_buffer(entry_opts),
  }),
    entries
end

local function selection_index(entries, preferred_bufnr)
  if not preferred_bufnr then
    return 1
  end
  for index, entry in ipairs(entries) do
    if entry.bufnr == preferred_bufnr then
      return index
    end
  end
  return 1
end

local function translate_layout(layout, row, col)
  for _, name in ipairs({ "preview", "results", "prompt" }) do
    local window = layout[name]
    if window then
      window.line = window.line + row
      window.col = window.col + col
    end
  end
  return layout
end

local function window_options(state, picker)
  local target = state.target_win
  if valid_editor_window(target) then
    state.last_target_position = vim.api.nvim_win_get_position(target)
    state.last_target_width = vim.api.nvim_win_get_width(target)
    state.last_target_height = vim.api.nvim_win_get_height(target)
  end

  local position = state.last_target_position or { 0, 0 }
  local width = state.last_target_width or vim.o.columns
  local height = state.last_target_height or math.max(3, vim.o.lines - vim.o.cmdheight)
  local strategies = require("telescope.pickers.layout_strategies")
  local layout = strategies.horizontal(picker, width, height, {
    horizontal = {
      width = width,
      height = height,
      preview_cutoff = 1,
      preview_width = width >= 90 and 0.55 or 0.5,
      prompt_position = "bottom",
      mirror = false,
    },
  })
  return translate_layout(layout, position[1], position[2])
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

local function refresh_picker(state, preferred_bufnr)
  if not state.picker or not state.prompt_bufnr or not vim.api.nvim_buf_is_valid(state.prompt_bufnr) then
    return
  end
  local finder = make_finder(state)
  state.picker:refresh(finder, { reset_prompt = false })
  state.preferred_bufnr = preferred_bufnr
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

local function reopen_picker(state, preferred_bufnr)
  if state.finished or active_state ~= state then
    return
  end
  state.preferred_bufnr = preferred_bufnr
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

local function delete_selection(state)
  local action_state = require("telescope.actions.state")
  local selection = action_state.get_selected_entry()
  local bufnr = selection and selection.bufnr
  if protected_buffer(bufnr) then
    notify("没有可删除的普通 buffer", vim.log.levels.WARN)
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
    notify("没有可打开的普通 buffer", vim.log.levels.WARN)
    return
  end

  local target = ensure_target_window(state)
  if not target or not valid_editor_window(target) then
    notify("找不到安全的普通编辑窗口", vim.log.levels.ERROR)
    return
  end
  if protected_buffer(bufnr) then
    notify("目标 buffer 已失效", vim.log.levels.WARN)
    return
  end

  local ok, err = pcall(vim.api.nvim_win_set_buf, target, bufnr)
  if not ok or not valid_editor_window(target) then
    notify("无法在安全编辑窗口打开 buffer: " .. tostring(err), vim.log.levels.ERROR)
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
end

local function attach_mappings(state, prompt_bufnr, map)
  local actions = require("telescope.actions")
  local function do_cancel()
    cancel(state)
  end
  local function do_select()
    select_buffer(state)
  end
  local function do_delete()
    delete_selection(state)
  end

  actions.select_default:replace(do_select)
  actions.select_horizontal:replace(do_select)
  actions.select_vertical:replace(do_select)
  actions.select_tab:replace(do_select)

  map("n", "q", do_cancel)
  map("n", "<Esc>", do_cancel)
  map("n", "dd", do_delete)
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
      reopen_picker(state, state.preferred_bufnr)
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
  local width = vim.api.nvim_win_get_width(target)
  local height = vim.api.nvim_win_get_height(target)
  if width < 3 or height < 3 then
    notify("普通编辑窗口太小，无法安全显示 buffer picker", vim.log.levels.ERROR)
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
    default_selection_index = selection_index(entries, state.preferred_bufnr),
    cache_picker = false,
    get_window_options = function(picker)
      return window_options(state, picker)
    end,
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
  state.picker:find()
  state.prompt_bufnr = state.picker.prompt_bufnr
end

function M.open()
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

function M._delete_choices()
  return { DELETE_CANCEL, DELETE_SAVE, DELETE_DISCARD }
end

return M
