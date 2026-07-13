local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
local uv = vim.uv or vim.loop
if not uv.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- 最新稳定版
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.clipboard = "unnamedplus"
vim.g.mapleader = " "
-- 统一用 2-space soft tabs，避免新行缩进看起来像硬 Tab 那样过宽
vim.opt.expandtab = true
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2
vim.opt.softtabstop = 2
vim.opt.hlsearch = true
vim.opt.incsearch = false
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.foldenable = true
vim.opt.foldlevel = 99
vim.opt.foldlevelstart = 99
vim.opt.scroll = 6
vim.opt.scrolloff = 6
vim.opt.sidescrolloff = 8
vim.opt.mousescroll = "ver:2,hor:6"
vim.opt.smoothscroll = true
vim.opt.guicursor = "n-v-c-sm:block,i-ci-ve:ver25,r-cr-o:hor20,t:block-TermCursor"

local view_scroll_lines = 6
local terminal_cursor_bg = "#ffd866"
local terminal_cursor_fg = "#1a1b26"

local treesitter_languages = {
  "lua",
  "python",
  "ecma",
  "javascript",
  "jsx",
  "typescript",
  "tsx",
  "html",
  "css",
  "json",
  "yaml",
  "bash",
  "markdown",
  "markdown_inline",
  "vim",
  "vimdoc",
  "go",
  "gomod",
  "gosum",
  "gowork",
}

vim.treesitter.language.register("javascript", "javascriptreact")
vim.treesitter.language.register("tsx", "typescriptreact")

local function statusline_escape(text)
  return text:gsub("%%", "%%%%")
end

function _G.dotfiles_winbar()
  if vim.bo.buftype ~= "" then
    return ""
  end

  local ok, navic = pcall(require, "nvim-navic")
  if ok and navic.is_available() then
    return statusline_escape(" " .. navic.get_location())
  end

  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t")
  if name == "" then
    return ""
  end

  return statusline_escape(" " .. name)
end

vim.o.winbar = "%{%v:lua.dotfiles_winbar()%}"

local function indent_step(bufnr)
  local sw = vim.bo[bufnr].shiftwidth
  if sw == 0 then
    return vim.bo[bufnr].tabstop
  end
  return sw
end

local function indent_text(width, bufnr)
  if width <= 0 then
    return ""
  end

  if vim.bo[bufnr].expandtab then
    return string.rep(" ", width)
  end

  local ts = vim.bo[bufnr].tabstop
  local tabs = math.floor(width / ts)
  local spaces = width % ts
  return string.rep("\t", tabs) .. string.rep(" ", spaces)
end

local function shift_current_line(delta)
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local leading = line:match("^%s*") or ""
  local content = line:sub(#leading + 1)
  local current_width = vim.fn.indent(row)
  local new_width = math.max(0, current_width + delta * indent_step(bufnr))
  local new_indent = indent_text(new_width, bufnr)

  vim.api.nvim_set_current_line(new_indent .. content)
  local new_col = math.max(0, col + (#new_indent - #leading))
  vim.api.nvim_win_set_cursor(0, { row, new_col })
end

local function paired_block_enter()
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local left = col > 0 and line:sub(col, col) or ""
  local right = line:sub(col + 1, col + 1)
  local pairs = { ["{"] = "}", ["["] = "]", ["("] = ")" }

  if pairs[left] ~= right then
    return nil
  end

  local before = line:sub(1, col)
  local after = line:sub(col + 1)
  local base_width = vim.fn.indent(row)
  local base_indent = indent_text(base_width, bufnr)
  local inner_indent = indent_text(base_width + indent_step(bufnr), bufnr)

  vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, {
    before,
    inner_indent,
    base_indent .. after,
  })
  vim.api.nvim_win_set_cursor(0, { row + 1, #inner_indent })
  vim.schedule(function()
    vim.cmd("startinsert")
  end)

  return true
end

local function smart_enter()
  local ok, cmp = pcall(require, "blink.cmp")
  if ok then
    local visible_ok, visible = pcall(cmp.is_visible)
    if visible_ok and visible then
      local accepted = cmp.accept()
      if accepted then
        return
      end
    end
  end

  if paired_block_enter() then
    return
  end

  local cr = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
  vim.api.nvim_feedkeys(cr, "n", false)
end

local function attach_smart_enter(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if vim.bo[bufnr].buftype ~= "" or not vim.bo[bufnr].modifiable then
    return
  end

  if vim.b[bufnr].smart_enter_attached then
    return
  end

  vim.b[bufnr].smart_enter_attached = true
  vim.keymap.set("i", "<CR>", smart_enter, {
    buffer = bufnr,
    desc = "Smart enter",
  })
end

local function remove_local_key_token(bufnr, optname, token)
  local current = vim.api.nvim_get_option_value(optname, { buf = bufnr })
  if current == "" then
    return
  end

  local items = vim.split(current, ",", { plain = true, trimempty = true })
  local filtered = {}
  local changed = false

  for _, item in ipairs(items) do
    if item ~= token then
      table.insert(filtered, item)
    else
      changed = true
    end
  end

  if changed then
    vim.api.nvim_set_option_value(optname, table.concat(filtered, ","), { buf = bufnr })
  end
end

local function disable_colon_reindent(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- 某些 ftplugin 会把 ":" 放进 indentkeys/cinkeys。这样在行尾用 A 进入
  -- insert 后输入 ":" 时，nvim 会立刻重算当前行缩进，看起来像“冒号把行往右推了一次”。
  -- 这里关掉这个触发，保留 Enter 时的正常续行缩进。
  remove_local_key_token(bufnr, "indentkeys", ":")
  remove_local_key_token(bufnr, "indentkeys", "<:>")
  remove_local_key_token(bufnr, "cinkeys", ":")
  remove_local_key_token(bufnr, "cinkeys", "<:>")
end

local function attach_treesitter_folds(winid, bufnr)
  if not vim.api.nvim_win_is_valid(winid) or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if vim.bo[bufnr].buftype ~= "" then
    vim.wo[winid].foldmethod = "manual"
    vim.wo[winid].foldexpr = "0"
    return
  end

  local filetype = vim.bo[bufnr].filetype
  local lang = vim.treesitter.language.get_lang(filetype) or filetype
  local ok = pcall(vim.treesitter.start, bufnr, lang)
  local parser = ok and vim.treesitter.get_parser(bufnr, lang) or nil
  local query_ok, query = pcall(vim.treesitter.query.get, lang, "folds")
  local has_query = query_ok and query ~= nil
  if not ok or parser == nil or not has_query then
    vim.wo[winid].foldmethod = "manual"
    vim.wo[winid].foldexpr = "0"
    return
  end

  vim.wo[winid].foldmethod = "expr"
  vim.wo[winid].foldexpr = "v:lua.vim.treesitter.foldexpr()"
end

-- SSH / 纯 tty 环境下没有 $DISPLAY，xclip/wl-copy 都失效，
-- 改用 OSC 52 让终端（iTerm2/WezTerm/kitty 等）把内容写到本地剪贴板。
-- 需要外层 tmux 开启 set-clipboard on、iTerm2 允许剪贴板访问。
if vim.env.SSH_TTY or vim.env.SSH_CONNECTION or vim.env.XDG_SESSION_TYPE == "tty" then
  vim.g.clipboard = {
    name = "OSC 52",
    copy = {
      ["+"] = require("vim.ui.clipboard.osc52").copy("+"),
      ["*"] = require("vim.ui.clipboard.osc52").copy("*"),
    },
    paste = {
      ["+"] = require("vim.ui.clipboard.osc52").paste("+"),
      ["*"] = require("vim.ui.clipboard.osc52").paste("*"),
    },
  }
end
vim.opt.autoread = true -- 文件被外部修改时自动重新读取

local function toggle_paste_mode()
  vim.opt.paste = not vim.opt.paste:get()
  vim.notify("paste mode: " .. (vim.opt.paste:get() and "on" or "off"))
end

local function toggle_window_zoom()
  if vim.t.dotfiles_zoomed then
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("tabclose")
    else
      vim.notify("没有可恢复的原始布局", vim.log.levels.WARN)
    end
    return
  end

  if #vim.api.nvim_tabpage_list_wins(0) <= 1 then
    vim.notify("当前 tab 只有一个窗口", vim.log.levels.INFO)
    return
  end

  vim.cmd("tab split")
  vim.t.dotfiles_zoomed = true
end

local function process_cwd(pid)
  if type(pid) ~= "number" or pid <= 0 then
    return nil
  end

  local proc_cwd = uv.fs_realpath("/proc/" .. pid .. "/cwd")
  if proc_cwd and vim.fn.isdirectory(proc_cwd) == 1 then
    return proc_cwd
  end

  if vim.fn.executable("lsof") ~= 1 then
    return nil
  end

  local lines = vim.fn.systemlist({ "lsof", "-a", "-d", "cwd", "-p", tostring(pid), "-Fn" })
  if vim.v.shell_error ~= 0 then
    return nil
  end

  for _, line in ipairs(lines) do
    if vim.startswith(line, "n") then
      local dir = line:sub(2)
      if dir ~= "" and vim.fn.isdirectory(dir) == 1 then
        return dir
      end
    end
  end

  return nil
end

local function terminal_buffer_cwd(bufnr)
  if vim.bo[bufnr].buftype ~= "terminal" then
    return nil
  end

  local pid = vim.b[bufnr].terminal_job_pid
  if type(pid) ~= "number" or pid <= 0 then
    return nil
  end

  return process_cwd(pid)
end

local function buffer_context_dir(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr

  local buf_name = vim.api.nvim_buf_get_name(bufnr)
  if buf_name:match("^oil://") then
    return buf_name:gsub("^oil://", "")
  end

  local term_dir = terminal_buffer_cwd(bufnr)
  if term_dir then
    return term_dir
  end

  if buf_name ~= "" then
    return vim.fn.fnamemodify(buf_name, ":p:h")
  end

  return vim.fn.getcwd()
end

local function open_oil_from_context()
  local dir = buffer_context_dir(0)
  if not dir or vim.fn.isdirectory(dir) == 0 then
    dir = vim.fn.getcwd()
  end

  vim.cmd("Oil " .. vim.fn.fnameescape(dir))
end

local function set_search_without_jump(pattern, forward)
  if not pattern or pattern == "" then
    return false
  end

  local view = vim.fn.winsaveview()
  vim.fn.setreg("/", pattern)
  vim.fn.histadd("search", pattern)
  vim.o.hlsearch = true
  vim.cmd("let v:searchforward = " .. (forward and "1" or "0"))
  vim.g.dotfiles_armed_search_pattern = pattern
  vim.fn.winrestview(view)
  return true
end

local function prompt_search_without_jump(forward)
  local ok, pattern = pcall(vim.fn.input, forward and "/" or "?")
  if not ok then
    return
  end

  set_search_without_jump(pattern, forward)
end

local function cword_search_pattern()
  local word = vim.fn.expand("<cword>")
  if word == "" then
    return nil
  end

  return "\\V\\<" .. vim.fn.escape(word, "\\") .. "\\>"
end

local function cword_search(forward)
  local pattern = cword_search_pattern()
  if not pattern then
    return
  end

  local already_armed = vim.g.dotfiles_armed_search_pattern == pattern and vim.fn.getreg("/") == pattern
  set_search_without_jump(pattern, forward)
  if already_armed then
    vim.cmd("normal! n")
  end
end

vim.keymap.set({ "n", "i" }, "<F2>", toggle_paste_mode, { desc = "Toggle paste mode" })
vim.keymap.set("n", "<leader>vp", toggle_paste_mode, { desc = "Toggle paste mode" })
vim.keymap.set("n", "<leader>z", toggle_window_zoom, { desc = "Toggle window zoom" })
vim.keymap.set("n", "/", function()
  prompt_search_without_jump(true)
end, { desc = "Search without jumping" })
vim.keymap.set("n", "?", function()
  prompt_search_without_jump(false)
end, { desc = "Search backward without jumping" })
vim.keymap.set("n", "*", function()
  cword_search(true)
end, { desc = "Search word without jumping first" })
vim.keymap.set("n", "#", function()
  cword_search(false)
end, { desc = "Search word backward without jumping first" })

local function scroll_view(key)
  return function()
    local count = vim.v.count > 0 and vim.v.count or view_scroll_lines
    local keys = vim.api.nvim_replace_termcodes(tostring(count) .. key, true, false, true)
    vim.api.nvim_feedkeys(keys, "n", false)
  end
end

vim.keymap.set("n", "<C-d>", scroll_view("<C-e>"), { desc = "Scroll view down" })
vim.keymap.set("n", "<C-u>", scroll_view("<C-y>"), { desc = "Scroll view up" })

local external_change_group = vim.api.nvim_create_augroup("DotfilesExternalChanges", { clear = true })
local file_watchers = {}

local function stop_file_watcher(bufnr)
  local watcher = file_watchers[bufnr]
  if watcher then
    watcher:stop()
    watcher:close()
    file_watchers[bufnr] = nil
  end
end

local function start_file_watcher(bufnr)
  stop_file_watcher(bufnr)

  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" or vim.bo[bufnr].buftype ~= "" or vim.fn.isdirectory(path) == 1 then
    return
  end

  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return
  end

  local watcher = vim.uv.new_fs_event()
  if not watcher then
    return
  end

  local ok, err = watcher:start(path, {}, vim.schedule_wrap(function(fs_err)
    if fs_err or not vim.api.nvim_buf_is_valid(bufnr) then
      stop_file_watcher(bufnr)
      return
    end
    if vim.bo[bufnr].modified then
      return
    end
    vim.cmd(("silent! checktime %d"):format(bufnr))
  end))
  if not ok then
    watcher:close()
    vim.schedule(function()
      vim.notify("文件监听启动失败: " .. tostring(err), vim.log.levels.DEBUG)
    end)
    return
  end

  file_watchers[bufnr] = watcher
end

-- 用 oil.nvim 替代 netrw 做文件浏览，禁用内置 netrw 以免冲突
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- 任意已打开的文件里，<leader>yp 复制当前 buffer 的绝对路径
vim.keymap.set("n", "<leader>yp", function()
  local path = vim.fn.expand("%:p")
  if path == "" then
    vim.notify("当前 buffer 没有文件名", vim.log.levels.WARN)
    return
  end
  vim.fn.setreg("+", path)
  vim.fn.setreg('"', path)
  vim.notify("已复制: " .. path)
end, { desc = "Yank current buffer abs path" })

-- autoread 本身只在 nvim 有机会检查时才生效。终端里没有 FocusGained 事件，
-- Claude/外部工具改文件后 nvim 不会自动发现。这里在光标停顿、进入 buffer、
-- 终端获得焦点时主动调用 checktime，并在文件被外部改动后给出提示。
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI", "TermLeave" }, {
  group = external_change_group,
  callback = function()
    if vim.fn.mode() ~= "c" and vim.fn.getcmdwintype() == "" then
      vim.cmd("silent! checktime")
    end
  end,
})
vim.api.nvim_create_autocmd("FileChangedShellPost", {
  group = external_change_group,
  callback = function()
    vim.notify("文件被外部修改，已重新加载", vim.log.levels.WARN)
  end,
})
vim.api.nvim_create_autocmd({ "BufReadPost", "BufFilePost", "BufWritePost" }, {
  group = external_change_group,
  callback = function(args)
    start_file_watcher(args.buf)
  end,
})
vim.api.nvim_create_autocmd({ "BufDelete", "BufUnload", "BufWipeout" }, {
  group = external_change_group,
  callback = function(args)
    stop_file_watcher(args.buf)
  end,
})
-- 缩短 CursorHold 触发间隔（默认 4000ms），让外部改动几乎即时可见
vim.opt.updatetime = 500

local function open_full_terminal()
  local dir = buffer_context_dir(0)
  if not dir or vim.fn.isdirectory(dir) == 0 then
    dir = vim.fn.getcwd()
  end

  vim.cmd("enew")
  vim.fn.termopen(vim.o.shell, { cwd = dir })
  vim.schedule(function()
    if vim.bo.buftype == "terminal" then
      vim.cmd("startinsert")
    end
  end)
end

vim.keymap.set("n", "<leader>t", open_full_terminal, { desc = "Terminal in current context dir" })

local terminal_panel = {
  buf = nil,
  win = nil,
  win_options = nil,
  height = 12,
  default_height = 12,
  min_height = 5,
  step = 2,
}

local function restore_terminal_panel_window_options(win, options)
  if not win or not vim.api.nvim_win_is_valid(win) or not options then
    return
  end

  for name, value in pairs(options) do
    vim.wo[win][name] = value
  end
end

local function visible_terminal_panel_win()
  local win = terminal_panel.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    terminal_panel.win = nil
    terminal_panel.win_options = nil
    return nil
  end

  if not terminal_panel.buf
    or not vim.api.nvim_buf_is_valid(terminal_panel.buf)
    or vim.api.nvim_win_get_buf(win) ~= terminal_panel.buf
  then
    restore_terminal_panel_window_options(win, terminal_panel.win_options)
    terminal_panel.win = nil
    terminal_panel.win_options = nil
    return nil
  end

  return win
end

local function terminal_panel_job_running(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local job_id = vim.b[bufnr].terminal_job_id
  return type(job_id) == "number" and vim.fn.jobwait({ job_id }, 0)[1] == -1
end

local function open_terminal_panel()
  local dir = buffer_context_dir(0)
  if not dir or vim.fn.isdirectory(dir) == 0 then
    dir = vim.fn.getcwd()
  end

  vim.cmd("botright " .. terminal_panel.height .. "split")
  terminal_panel.win = vim.api.nvim_get_current_win()
  terminal_panel.win_options = {
    winfixheight = vim.wo[terminal_panel.win].winfixheight,
    number = vim.wo[terminal_panel.win].number,
    relativenumber = vim.wo[terminal_panel.win].relativenumber,
    signcolumn = vim.wo[terminal_panel.win].signcolumn,
  }
  vim.wo[terminal_panel.win].winfixheight = true
  vim.wo[terminal_panel.win].number = false
  vim.wo[terminal_panel.win].relativenumber = false
  vim.wo[terminal_panel.win].signcolumn = "no"

  if terminal_panel_job_running(terminal_panel.buf) then
    vim.api.nvim_win_set_buf(terminal_panel.win, terminal_panel.buf)
  else
    vim.cmd("enew")
    terminal_panel.buf = vim.api.nvim_get_current_buf()
    vim.bo[terminal_panel.buf].buflisted = false
    vim.bo[terminal_panel.buf].bufhidden = "hide"
    vim.fn.termopen(vim.o.shell, { cwd = dir })
  end

  local panel_win = terminal_panel.win
  vim.schedule(function()
    if terminal_panel.win == panel_win
      and vim.api.nvim_win_is_valid(panel_win)
      and vim.api.nvim_win_get_buf(panel_win) == terminal_panel.buf
    then
      vim.api.nvim_set_current_win(panel_win)
      vim.cmd("startinsert")
    end
  end)
end

local function terminal_panel_max_height()
  local screen_cap = math.max(terminal_panel.min_height, vim.o.lines - 5)
  return math.min(screen_cap, math.max(terminal_panel.min_height, math.floor(vim.o.lines * 0.7)))
end

local function set_terminal_panel_height(height)
  terminal_panel.height = math.max(terminal_panel.min_height, math.min(terminal_panel_max_height(), height))

  local panel_win = visible_terminal_panel_win()
  if panel_win then
    vim.api.nvim_win_set_height(panel_win, terminal_panel.height)
    vim.wo[panel_win].winfixheight = true
  end
end

local function resize_terminal_panel(delta)
  set_terminal_panel_height(terminal_panel.height + delta)
end

local function reset_terminal_panel_height()
  set_terminal_panel_height(terminal_panel.default_height)
end

local function toggle_terminal_panel()
  local panel_win = visible_terminal_panel_win()
  if panel_win then
    if #vim.api.nvim_tabpage_list_wins(0) == 1 then
      local replacement_buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_win_set_buf(panel_win, replacement_buf)
      restore_terminal_panel_window_options(panel_win, terminal_panel.win_options)
    else
      vim.api.nvim_win_close(panel_win, false)
    end
    terminal_panel.win = nil
    terminal_panel.win_options = nil
    return
  end

  open_terminal_panel()
end

for _, key in ipairs({ "<C-/>", "<C-_>" }) do
  vim.keymap.set({ "n", "i" }, key, toggle_terminal_panel, { desc = "Toggle terminal panel" })
  vim.keymap.set("t", key, function()
    vim.cmd("stopinsert")
    vim.schedule(toggle_terminal_panel)
  end, { desc = "Toggle terminal panel" })
end
for _, key in ipairs({ "<M-+>", "<M-=>" }) do
  vim.keymap.set({ "n", "i", "t" }, key, function()
    resize_terminal_panel(terminal_panel.step)
  end, { desc = "Increase terminal panel height" })
end
vim.keymap.set({ "n", "i", "t" }, "<M-->", function()
  resize_terminal_panel(-terminal_panel.step)
end, { desc = "Decrease terminal panel height" })
vim.keymap.set({ "n", "i", "t" }, "<M-0>", reset_terminal_panel_height, { desc = "Reset terminal panel height" })

vim.opt.termguicolors = true

-- 缩进后保持选中
vim.keymap.set("v", "<", "<gv")
vim.keymap.set("v", ">", ">gv")
vim.keymap.set("n", "<M-h>", "<<", { desc = "Indent left" })
vim.keymap.set("n", "<M-l>", ">>", { desc = "Indent right" })
vim.keymap.set("x", "<M-h>", "<gv", { desc = "Indent left" })
vim.keymap.set("x", "<M-l>", ">gv", { desc = "Indent right" })
vim.keymap.set({ "n", "x" }, "<M-Left>", "b", { desc = "Back word" })
vim.keymap.set({ "n", "x" }, "<M-Right>", "e", { desc = "Forward word end" })
vim.keymap.set("i", "<M-Left>", "<C-o>b", { desc = "Back word" })
vim.keymap.set("i", "<M-Right>", "<C-o>e", { desc = "Forward word end" })
vim.keymap.set("n", "<C-n>", "<cmd>enew<CR>", { desc = "New scratch buffer" })

vim.keymap.set("i", "<C-a>", "<C-o>^", { desc = "Line start nonblank" })
vim.keymap.set("i", "<C-e>", "<C-o>$", { desc = "Line end" })

vim.keymap.set("i", "<M-h>", function()
  shift_current_line(-1)
  vim.schedule(function()
    vim.cmd("startinsert")
  end)
end, { desc = "Indent left" })
vim.keymap.set("i", "<M-l>", function()
  shift_current_line(1)
  vim.schedule(function()
    vim.cmd("startinsert")
  end)
end, { desc = "Indent right" })

local function blank_line(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  return line:match("^%s*$") ~= nil
end

local function first_nonblank_col(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local idx = line:find("%S")
  return idx and idx - 1 or 0
end

local function adjacent_text_block_start(bufnr, lnum, direction)
  local last = vim.api.nvim_buf_line_count(bufnr)
  local cur = lnum

  if direction > 0 then
    while cur <= last and not blank_line(bufnr, cur) do
      cur = cur + 1
    end
    while cur <= last and blank_line(bufnr, cur) do
      cur = cur + 1
    end
    return cur <= last and cur or nil
  end

  while cur >= 1 and not blank_line(bufnr, cur) do
    cur = cur - 1
  end
  while cur >= 1 and blank_line(bufnr, cur) do
    cur = cur - 1
  end
  if cur < 1 then
    return nil
  end
  while cur >= 1 and not blank_line(bufnr, cur) do
    cur = cur - 1
  end
  return cur + 1
end

local function move_text_block(direction)
  local bufnr = vim.api.nvim_get_current_buf()
  local target = vim.api.nvim_win_get_cursor(0)[1]

  for _ = 1, vim.v.count1 do
    local next_target = adjacent_text_block_start(bufnr, target, direction)
    if not next_target then
      break
    end
    target = next_target
  end

  vim.api.nvim_win_set_cursor(0, { target, first_nonblank_col(bufnr, target) })
end

-- H/L 快速跳转行首行尾（原始 0/$ 仍可用）
vim.keymap.set({ "n", "v" }, "H", "^")
vim.keymap.set({ "n", "v" }, "L", "$")
vim.keymap.set({ "n", "x" }, "J", function()
  move_text_block(1)
end, { desc = "Move to next text block" })
vim.keymap.set({ "n", "x" }, "K", function()
  move_text_block(-1)
end, { desc = "Move to previous text block" })

vim.keymap.set("v", "(", "sa)", { remap = true })
vim.keymap.set("v", "[", "sa]", { remap = true })
vim.keymap.set("v", "{", "sa}", { remap = true })
vim.keymap.set("v", "'", "sa'", { remap = true })
vim.keymap.set("v", '"', 'sa"', { remap = true })
vim.keymap.set("v", "`", "sa`", { remap = true })

local function lsp_definition_vsplit()
  local source_win = vim.api.nvim_get_current_win()

  vim.lsp.buf.definition({
    on_list = function(options)
      local items = options.items or {}
      if #items == 0 then
        return
      end

      local item = items[1]
      local target_bufnr = item.bufnr
      if not target_bufnr or target_bufnr == 0 then
        if not item.filename then
          return
        end
        target_bufnr = vim.fn.bufadd(item.filename)
      end
      if target_bufnr == 0 then
        return
      end

      if vim.api.nvim_win_is_valid(source_win) then
        vim.api.nvim_set_current_win(source_win)
      end

      vim.cmd("rightbelow vertical split")
      vim.cmd("normal! m'")
      vim.fn.bufload(target_bufnr)
      vim.bo[target_bufnr].buflisted = true
      vim.api.nvim_win_set_buf(0, target_bufnr)
      vim.api.nvim_win_set_cursor(0, { item.lnum, math.max((item.col or 1) - 1, 0) })
      pcall(vim.cmd, "normal! zv")

      if #items > 1 then
        vim.fn.setloclist(0, {}, " ", {
          title = options.title or "LSP definitions",
          items = items,
        })
      end
    end,
  })
end

vim.api.nvim_create_autocmd("BufEnter", {
  callback = function(args)
    attach_smart_enter(args.buf)
  end,
})
attach_smart_enter(0)
vim.api.nvim_create_autocmd("FileType", {
  callback = function(args)
    disable_colon_reindent(args.buf)
  end,
})
disable_colon_reindent(0)
vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
  callback = function(args)
    attach_treesitter_folds(vim.api.nvim_get_current_win(), args.buf)
  end,
})
attach_treesitter_folds(0, 0)

require("lazy").setup({
  -- 文件浏览（替代 netrw）：把目录当 buffer 编辑，按 - 回到父目录
  {
    "stevearc/oil.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    lazy = false, -- 需要在启动时接管目录打开（nvim .）
    keys = {
      { "-", open_oil_from_context, desc = "Open directory view (oil)" },
    },
    opts = {
      default_file_explorer = true,
      watch_for_changes = true,
      view_options = {
        show_hidden = true,
      },
      keymaps = {
        ["<C-p>"] = {
          desc = "Find files in current oil directory",
          callback = function()
            local oil = require("oil")
            local dir = oil.get_current_dir()
            if not dir then
              return
            end

            require("telescope.builtin").find_files({ cwd = dir })
          end,
        },
        ["gy"] = {
          desc = "Yank abs path of entry under cursor",
          callback = function()
            local oil = require("oil")
            local entry = oil.get_cursor_entry()
            local dir = oil.get_current_dir()
            if not entry or not dir then return end
            local full = dir .. entry.name
            vim.fn.setreg("+", full)
            vim.fn.setreg('"', full)
            vim.notify("已复制: " .. full)
          end,
        },
      },
    },
    config = function(_, opts)
      require("oil").setup(opts)

      local function repair_startup_directory_buffer()
        local name = vim.api.nvim_buf_get_name(0)
        local is_empty_oil = name:match("^oil://")
          and vim.bo.filetype == ""
          and vim.api.nvim_buf_line_count(0) <= 1
        local is_raw_directory = name ~= "" and vim.fn.isdirectory(name) == 1
        if not is_empty_oil and not is_raw_directory then
          return
        end

        local path = name:gsub("^oil://", "")
        require("oil").open(path)
      end

      if vim.v.vim_did_enter == 1 then
        vim.schedule(repair_startup_directory_buffer)
      else
        vim.schedule(repair_startup_directory_buffer)
        vim.api.nvim_create_autocmd("VimEnter", {
          once = true,
          callback = function()
            vim.schedule(repair_startup_directory_buffer)
          end,
        })
      end
    end,
  },
  {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    config = function()
      vim.cmd.colorscheme("tokyonight")
      vim.api.nvim_set_hl(0, "TermCursor", { fg = terminal_cursor_fg, bg = terminal_cursor_bg, bold = true })
      vim.api.nvim_set_hl(0, "TermCursorNC", { fg = terminal_cursor_fg, bg = "#e0af68" })
    end,
  },
  {
    "folke/flash.nvim",
    event = "VeryLazy",
    opts = {},
    keys = {
      -- 绑定 s 键为向下/全局闪现
      { "s", mode = { "n", "x", "o" }, function() require("flash").jump() end, desc = "Flash Jump" },
      -- 绑定 S 键为基于代码结构的闪现
      { "S", mode = { "n", "x", "o" }, function() require("flash").treesitter() end, desc = "Flash Treesitter" },
    },
  },
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    event = "BufReadPost",
    config = function()
      local nvim_treesitter = require("nvim-treesitter")
      nvim_treesitter.setup({
        install_dir = vim.fn.stdpath("data") .. "/site",
      })
      nvim_treesitter.install(treesitter_languages)
    end,
  },
  -- 底部状态栏（箭头分隔符，显示模式/文件/路径/git 分支等）
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    event = "VeryLazy",
    opts = {
      options = {
        section_separators = { left = "", right = "" },
        component_separators = { left = "", right = "" },
      },
    },
  },
  -- 文件搜索（Ctrl+P 搜文件，<leader>fg 全局搜内容）
  {
    "nvim-telescope/telescope.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-telescope/telescope-file-browser.nvim",
    },
    config = function()
      local telescope = require("telescope")
      local actions = require("telescope.actions")
      local action_state = require("telescope.actions.state")
      local builtin = require("telescope.builtin")

      -- 找当前文件所在的项目根目录（git 根，没有则用文件目录）
      local function project_root()
        local file = vim.api.nvim_buf_get_name(0)
        local dir = (file ~= "" and vim.fn.fnamemodify(file, ":p:h")) or vim.fn.getcwd()
        local git = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })[1]
        if vim.v.shell_error == 0 and git and git ~= "" then return git end
        return dir
      end

      -- 切换显示隐藏文件 / 忽略 .gitignore，保留当前输入
      local function toggle_hidden(prompt_bufnr)
        local line = action_state.get_current_line()
        local picker = action_state.get_current_picker(prompt_bufnr)
        local cwd = picker.cwd or project_root()
        actions.close(prompt_bufnr)
        builtin.find_files({
          cwd = cwd,
          hidden = true,
          no_ignore = true,
          default_text = line,
        })
      end

      telescope.setup({
        defaults = {
          file_ignore_patterns = {
            "%.git/", "node_modules/", "%.DS_Store", "target/", "dist/", "build/",
          },
          mappings = {
            i = {
              ["<M-v>"] = "select_vertical",
              ["<M-s>"] = "select_horizontal",
              ["<C-h>"] = toggle_hidden,
            },
          },
        },
        extensions = {
          file_browser = {
            hijack_netrw = false, -- 交给 oil 处理
            hidden = true,
            grouped = true, -- 目录排在文件前
            respect_gitignore = false,
          },
        },
      })
      telescope.load_extension("file_browser")

      -- 目录浏览 picker：可钻进子目录，用 telescope 默认分屏键打开
      --   <CR>  当前窗口, <C-v> 左右分屏, <C-x> 上下分屏, <C-t> 新标签
      vim.keymap.set("n", "<leader>fe", function()
        telescope.extensions.file_browser.file_browser({
          path = project_root(),
          select_buffer = true,
        })
      end, { desc = "File browser (project root)" })

      vim.keymap.set("n", "<leader>fE", function()
        telescope.extensions.file_browser.file_browser({
          path = "%:p:h",
          select_buffer = true,
        })
      end, { desc = "File browser (current file dir)" })

      vim.keymap.set("n", "<C-p>", function()
        builtin.find_files({ cwd = project_root() })
      end, { desc = "Find files (project root)" })

      vim.keymap.set("n", "<leader>fg", function()
        builtin.live_grep({ cwd = project_root() })
      end, { desc = "Live grep (project root)" })

      vim.keymap.set("n", "<leader>fb", builtin.buffers, { desc = "Buffers" })
    end,
  },
  -- Git 侧边栏标记（增删改彩色竖条）
  {
    "lewis6991/gitsigns.nvim",
    event = { "BufReadPre", "BufNewFile" },
    keys = {
      {
        "]h",
        function()
          require("gitsigns").nav_hunk("next")
        end,
        desc = "Next git hunk",
      },
      {
        "[h",
        function()
          require("gitsigns").nav_hunk("prev")
        end,
        desc = "Prev git hunk",
      },
    },
    opts = {},
  },
  -- Git diff 可视化（:DiffviewOpen 打开 side-by-side diff）
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewFileHistory" },
    keys = {
      { "<leader>gd", "<cmd>DiffviewOpen<cr>", desc = "Git diff" },
      { "<leader>gh", "<cmd>DiffviewFileHistory %<cr>", desc = "File history" },
      { "<leader>gH", "<cmd>DiffviewFileHistory<cr>", desc = "Repository history" },
      { "<leader>gq", "<cmd>DiffviewClose<cr>", desc = "Close diff" },
    },
    opts = {
      hooks = {
        diff_buf_win_enter = function()
          -- Diffview defaults to foldlevel=0, which hides unchanged regions.
          vim.opt_local.foldlevel = 99
        end,
      },
    },
  },
  -- 注释：可视模式选中多行后按 # 切换对应语言的行注释
  {
    "numToStr/Comment.nvim",
    event = { "BufReadPre", "BufNewFile" },
    opts = function()
      local ft = require("Comment.ft")
      local utils = require("Comment.utils")

      return {
        -- 优先使用当前 buffer 的原生 commentstring，避免插件内置的
        -- treesitter 注释计算在某些文件里拿到 nil tree 后直接报错。
        pre_hook = function(ctx)
          if ctx.ctype == utils.ctype.linewise and vim.bo.commentstring ~= "" then
            return vim.bo.commentstring
          end
          return ft.get(vim.bo.filetype, ctx.ctype) or vim.bo.commentstring
        end,
      }
    end,
    config = function(_, opts)
      require("Comment").setup(opts)

      local api = require("Comment.api")
      local esc = vim.api.nvim_replace_termcodes("<ESC>", true, false, true)

      vim.keymap.set("n", "gc", api.call("toggle.linewise", "g@"), {
        expr = true,
        desc = "Toggle comment",
      })
      vim.keymap.set("n", "gcc", function()
        if vim.v.count == 0 then
          api.toggle.linewise.current()
        else
          api.toggle.linewise.count(vim.v.count)
        end
      end, {
        desc = "Toggle comment line",
      })
      vim.keymap.set("x", "gc", function()
        vim.api.nvim_feedkeys(esc, "nx", false)
        api.toggle.linewise(vim.fn.visualmode())
      end, {
        desc = "Toggle comment",
      })
      vim.keymap.set("x", "#", "gc", {
        remap = true,
        desc = "Toggle comment for selection",
      })
    end,
  },
  -- 光标残影动画
  {
    "sphamba/smear-cursor.nvim",
    event = "VeryLazy",
    opts = {},
  },
  -- LSP 配置
  {
    "williamboman/mason.nvim",
    opts = {},
  },
  {
    "williamboman/mason-lspconfig.nvim",
    dependencies = { "williamboman/mason.nvim", "neovim/nvim-lspconfig" },
    opts = {
      -- 不自动安装，避免在无网络/代理异常的机器上启动时报错
      -- 需要 LSP 时在对应机器上手动运行 :MasonInstall <server>
      -- 推荐安装：lua_ls, pyright, ts_ls
    },
  },
  {
    "neovim/nvim-lspconfig",
    event = { "BufReadPre", "BufNewFile" },
    dependencies = { "saghen/blink.cmp", "SmiteshP/nvim-navic" },
    config = function()
      local navic = require("nvim-navic")
      local function attach_navic(client, bufnr)
        if not client or not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        if not client.server_capabilities.documentSymbolProvider or navic.is_available(bufnr) then
          return
        end
        navic.attach(client, bufnr)
      end

      navic.setup({
        highlight = false,
        separator = " > ",
        depth_limit = 5,
        lazy_update_context = false,
        safe_output = true,
        lsp = {
          auto_attach = false,
        },
        icons = {
          enabled = false,
        },
      })

      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(args)
          local client = vim.lsp.get_client_by_id(args.data.client_id)
          attach_navic(client, args.buf)
        end,
      })

      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
          attach_navic(client, bufnr)
        end
      end

      vim.lsp.config("*", {
        capabilities = require("blink.cmp").get_lsp_capabilities(),
      })
      vim.lsp.config("lua_ls", {
        settings = {
          Lua = {
            workspace = { checkThirdParty = false },
            telemetry = { enable = false },
            diagnostics = { globals = { "vim" } },
          },
        },
      })
    end,
    keys = {
      { "gd", vim.lsp.buf.definition, desc = "Go to definition" },
      { "gD", lsp_definition_vsplit, desc = "Go to definition in vertical split" },
      { "gr", vim.lsp.buf.references, desc = "References" },
      { "<leader>k", vim.lsp.buf.hover, desc = "Hover" },
      { "<leader>rn", vim.lsp.buf.rename, desc = "Rename" },
      { "<leader>ca", vim.lsp.buf.code_action, desc = "Code action" },
      { "[d", vim.diagnostic.goto_prev, desc = "Prev diagnostic" },
      { "]d", vim.diagnostic.goto_next, desc = "Next diagnostic" },
    },
  },
  -- 补全插件
  {
    'saghen/blink.cmp',
    dependencies = 'rafamadriz/friendly-snippets', -- 可选：提供基础的补全代码片段
    version = '*', -- 使用最新的发布版本
    opts = {
      -- IDE 风格补全：
      -- <C-space> 触发补全
      -- <Up>/<Down> 或 <C-n>/<C-p> 选择候选项
      -- <Enter> 只在你明确选中候选项后确认补全，否则正常换行
      -- <Tab> / <S-Tab> 仅用于 snippet 跳转
      keymap = { preset = 'enter' },
      completion = {
        list = {
          selection = {
            preselect = false,
            auto_insert = false,
          },
        },
      },
      appearance = {
        use_nvim_cmp_as_default = true, -- 让它的外观模仿经典的 nvim-cmp
        nerd_font_variant = 'mono'
      },
      sources = {
        default = { 'lsp', 'path', 'snippets', 'buffer' },
      },
    },
  },
  {
      "echasnovski/mini.pairs",
      event = "VeryLazy",
      opts = {},
  },
  {
      "echasnovski/mini.surround",
      event = "VeryLazy",
      opts = {},
  }
})
