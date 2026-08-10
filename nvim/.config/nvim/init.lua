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
local session_statusline_bg = "#7dcfff"
local session_statusline_fg = "#1a1b26"
local session_statusline_max_width = 20
local agent_working_frames = { "●··", "·●·", "··●", "···" }
local agent_ready_frames = { " ! ", " · " }
-- Stop hooks have a 5s timeout; the title fallback must not race normal ready/unread.
local codex_terminal_idle_delay_ms = 6000

local resolved_init_path = uv.fs_realpath(vim.fn.stdpath("config") .. "/init.lua")
  or (vim.fn.stdpath("config") .. "/init.lua")
local dotfiles_root = vim.fn.fnamemodify(resolved_init_path, ":h:h:h:h")
local codex_agent_state_script = dotfiles_root .. "/codex-notifications/agent_state.py"

local function codex_agent_status_dir()
  local directory = vim.env.DOTFILES_NVIM_SESSION_DIR
  if not directory or directory == "" then
    local state_home = vim.env.XDG_STATE_HOME
    if state_home and state_home ~= "" then
      directory = state_home .. "/nvim/sessions"
    else
      directory = vim.fn.expand("~/.local/state/nvim/sessions")
    end
  end
  return vim.fs.normalize(directory .. "/agent-status")
end

local function codex_agent_state_path(address)
  address = vim.fs.normalize(tostring(address or ""))
  if address == "" then
    return nil
  end
  return codex_agent_status_dir() .. "/" .. vim.fn.sha256(address) .. ".json"
end

local function read_codex_agent_state(address)
  local path = codex_agent_state_path(address)
  if not path then
    return { state = "idle", unread = false }
  end
  local handle = io.open(path, "r")
  if not handle then
    return { state = "idle", unread = false }
  end
  local raw = handle:read("*a")
  handle:close()
  local ok, state = pcall(vim.json.decode, raw)
  if not ok or type(state) ~= "table"
    or state.nvim_server ~= vim.fs.normalize(tostring(address or ""))
  then
    return { state = "idle", unread = false }
  end
  if state.state ~= "working" and state.state ~= "ready" then
    state.state = "idle"
    state.unread = false
  end
  return state
end

local function run_codex_agent_state(action, address, wait, extra_args)
  address = tostring(address or vim.v.servername or "")
  if address == "" or vim.fn.executable("python3") ~= 1
    or vim.fn.filereadable(codex_agent_state_script) ~= 1
  then
    return
  end
  local command = { "python3", codex_agent_state_script, action, "--server", address }
  vim.list_extend(command, extra_args or {})
  if wait then
    vim.fn.system(command)
  else
    vim.system(command, { text = true }, function() end)
  end
end

local function acknowledge_codex_agent(address)
  run_codex_agent_state("ack", address, false)
end

local function clear_codex_agent(address, wait)
  run_codex_agent_state("clear", address, wait)
end

local function mark_codex_agent_idle(turn_id, reason)
  turn_id = tostring(turn_id or "")
  if turn_id == "" then
    return
  end
  run_codex_agent_state("idle", vim.v.servername, false, {
    "--turn-id",
    turn_id,
    "--reason",
    tostring(reason or "terminal-idle"),
  })
end

function _G.dotfiles_codex_agent_state()
  return read_codex_agent_state(vim.v.servername)
end

local function has_startup_arg(flag)
  for _, arg in ipairs(vim.v.argv or {}) do
    if arg == flag then
      return true
    end
  end
  return false
end

-- Nvim 0.12 的普通 TUI 服务端本身也以 --embed 启动，因此不能靠 argv
-- 区分用户会话和工具进程。真正接入过 UI 的实例才进入会话列表；纯 RPC
-- embed/headless 辅助进程不会触发 UIEnter，会自然被过滤掉。
local supports_nvim_sessions = vim.fn.has("nvim-0.12") == 1 and not has_startup_arg("--headless")

local function normalize_nvim_session_name(name)
  return vim.trim(tostring(name or ""):gsub("[\r\n\t]", " "):gsub("%s+", " "))
end

local function refresh_nvim_session_statusline()
  local lualine = package.loaded.lualine
  if lualine and lualine.refresh then
    lualine.refresh({ place = { "statusline" }, scope = "all", force = true })
  else
    vim.cmd("redrawstatus")
  end
end

vim.g.dotfiles_session_instance = 0
vim.g.dotfiles_session_last_active = os.time()
vim.g.dotfiles_session_detached_once = 0
vim.g.dotfiles_session_had_changes = 0
vim.g.dotfiles_ui_focused = 0
if vim.g.dotfiles_session_name == nil then
  vim.g.dotfiles_session_name = normalize_nvim_session_name(vim.env.DOTFILES_NVIM_SESSION_NAME)
end

local session_info_lua = [=[
if vim.g.dotfiles_session_instance ~= 1 then
  return nil
end

local cwd = vim.fn.getcwd()
local home = vim.uv.os_homedir()
local project = cwd == home and "~" or vim.fn.fnamemodify(cwd, ":t")
if project == "" then
  project = cwd
end

local bufnr = vim.api.nvim_get_current_buf()
local name = vim.api.nvim_buf_get_name(bufnr)
local buftype = vim.bo[bufnr].buftype
local current_buffer
if buftype == "terminal" then
  current_buffer = "[terminal]"
elseif name == "" then
  current_buffer = "[No Name]"
elseif vim.startswith(name, "oil://") then
  current_buffer = "Oil " .. vim.fn.fnamemodify(name:sub(7), ":~")
else
  current_buffer = vim.fn.fnamemodify(name, ":.")
  if current_buffer == name then
    current_buffer = vim.fn.fnamemodify(name, ":~")
  end
end
current_buffer = current_buffer:gsub("[\r\n\t]", " ")

local modified_count = 0
local terminal_count = 0
for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_valid(buffer) then
    if vim.bo[buffer].modified then
      modified_count = modified_count + 1
    end
    if vim.bo[buffer].buftype == "terminal" then
      terminal_count = terminal_count + 1
    end
  end
end

local window_count = 0
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_win_get_config(win).relative == "" then
    window_count = window_count + 1
  end
end

return {
  name = tostring(vim.g.dotfiles_session_name or ""):gsub("[\r\n\t]", " "),
  cwd = cwd,
  project = project,
  current_buffer = current_buffer,
  modified_count = modified_count,
  terminal_count = terminal_count,
  window_count = window_count,
  tab_count = #vim.api.nvim_list_tabpages(),
  ui_count = #vim.api.nvim_list_uis(),
  pid = vim.fn.getpid(),
  last_active = vim.g.dotfiles_session_last_active or 0,
  agent_state = _G.dotfiles_codex_agent_state and _G.dotfiles_codex_agent_state()
    or { state = "idle", unread = false },
}
]=]

local nvim_rpc_timeout_ms = 700

local function remote_nvim_expression(lua_code, args)
  local wrapped = ("assert(loadstring(%q))(unpack(vim.json.decode(%q)))")
    :format(lua_code, vim.json.encode(args or {}))
  return "json_encode(luaeval(" .. vim.fn.string(wrapped) .. "))"
end

local function decode_remote_nvim_result(result)
  if not result or result.code ~= 0 then
    local detail = result and vim.trim(result.stderr or "") or ""
    if result and result.code == 124 then
      detail = "RPC 请求超时"
    elseif detail == "" then
      detail = "RPC 请求失败"
    end
    return nil, detail
  end

  local output = vim.trim(result.stdout or "")
  if output == "" then
    return nil, "RPC 返回为空"
  end
  local decode_ok, value = pcall(vim.json.decode, output)
  if not decode_ok then
    return nil, "RPC 返回无法解析: " .. tostring(value)
  end
  return value
end

local function start_remote_nvim_request(address, lua_code, args, callback)
  local start_ok, process = pcall(vim.system, {
    vim.v.progpath,
    "--server",
    address,
    "--remote-expr",
    remote_nvim_expression(lua_code, args),
  }, { text = true }, function(result)
    vim.schedule(function()
      callback(decode_remote_nvim_result(result))
    end)
  end)
  if not start_ok then
    return nil, tostring(process)
  end
  return process
end

local function request_remote_nvim(address, lua_code, args)
  local start_ok, process = pcall(vim.system, {
    vim.v.progpath,
    "--server",
    address,
    "--remote-expr",
    remote_nvim_expression(lua_code, args),
  }, { text = true })
  if not start_ok then
    return nil, tostring(process)
  end
  return decode_remote_nvim_result(process:wait(nvim_rpc_timeout_ms))
end

local function fetch_nvim_session(address)
  local info, err = request_remote_nvim(address, session_info_lua)
  if type(info) ~= "table" then
    return nil, err
  end

  info.address = address
  info.current = false
  return info
end

local function fetch_nvim_sessions(addresses)
  local sessions = {}
  local probes = {}
  local pending = 0

  for _, address in ipairs(addresses) do
    local probe = { address = address, done = false, cancelled = false }
    probes[#probes + 1] = probe
    pending = pending + 1
    local process, err = start_remote_nvim_request(address, session_info_lua, nil, function(info, request_err)
      if probe.cancelled then
        return
      end
      probe.done = true
      probe.error = request_err
      pending = pending - 1
      if type(info) == "table" then
        info.address = address
        info.current = false
        sessions[#sessions + 1] = info
      end
    end)
    probe.process = process
    if not process then
      probe.done = true
      probe.error = err
      pending = pending - 1
    end
  end

  if pending > 0 then
    vim.wait(nvim_rpc_timeout_ms, function()
      return pending == 0
    end, 10)
  end

  local failed = {}
  for _, probe in ipairs(probes) do
    if not probe.done then
      probe.cancelled = true
      probe.error = "RPC 请求超时"
      if probe.process then
        pcall(probe.process.kill, probe.process, "sigkill")
      end
    end
    if probe.error then
      failed[#failed + 1] = probe.address
    end
  end

  return sessions, failed
end

local function current_nvim_session_info()
  if vim.g.dotfiles_session_instance ~= 1 then
    return nil
  end

  local chunk, load_err = loadstring(session_info_lua)
  if not chunk then
    vim.notify("读取当前 Nvim session 失败: " .. tostring(load_err), vim.log.levels.ERROR)
    return nil
  end
  local request_ok, info = pcall(chunk)
  if not request_ok or type(info) ~= "table" then
    return nil
  end

  info.address = vim.v.servername
  info.current = true
  return info
end

local managed_nvim_session_dir = vim.env.DOTFILES_NVIM_SESSION_DIR
local managed_nvim_tmux_server = vim.env.DOTFILES_NVIM_TMUX_SERVER or "dotfiles-nvim-host"

local function managed_nvim_session_id(address)
  if not managed_nvim_session_dir or managed_nvim_session_dir == "" then
    return nil
  end

  local parent = vim.fs.normalize(vim.fn.fnamemodify(address, ":h"))
  if parent ~= vim.fs.normalize(managed_nvim_session_dir) then
    return nil
  end

  return vim.fn.fnamemodify(address, ":t"):match("^(nvim%-.+)%.sock$")
end

local function current_nvim_session_is_managed()
  return vim.g.dotfiles_session_instance == 1 and managed_nvim_session_id(vim.v.servername) ~= nil
end

local function managed_nvim_session_addresses()
  if not managed_nvim_session_dir or managed_nvim_session_dir == "" then
    return {}
  end

  local addresses = {}
  local scan = uv.fs_scandir(managed_nvim_session_dir)
  if not scan then
    return addresses
  end

  while true do
    local name, file_type = uv.fs_scandir_next(scan)
    if not name then
      break
    end
    if file_type == "socket" and name:match("^nvim%-.+%.sock$") then
      table.insert(addresses, managed_nvim_session_dir .. "/" .. name)
    end
  end

  return addresses
end

local function remove_stale_managed_nvim_socket(address)
  local session_id = managed_nvim_session_id(address)
  if not session_id or vim.fn.executable("tmux") ~= 1 then
    return
  end

  local result = vim.system({
    "tmux",
    "-L",
    managed_nvim_tmux_server,
    "has-session",
    "-t",
    session_id,
  }, { text = true, env = { TMUX = "" } }):wait(nvim_rpc_timeout_ms)
  local stat = uv.fs_stat(address)
  if result.code ~= 0 and result.code ~= 124 and stat and stat.type == "socket" then
    uv.fs_unlink(address)
  end
end

local function discover_nvim_sessions()
  local list_ok, addresses = pcall(vim.fn.serverlist, { peer = true })
  if not list_ok or type(addresses) ~= "table" then
    addresses = {}
  end
  for _, address in ipairs(managed_nvim_session_addresses()) do
    table.insert(addresses, address)
  end

  local sessions = {}
  local seen = {}
  local pending_addresses = {}
  local current = current_nvim_session_info()
  if current then
    table.insert(sessions, current)
    seen[current.address] = true
  end

  for _, address in ipairs(addresses) do
    if not seen[address] then
      seen[address] = true
      pending_addresses[#pending_addresses + 1] = address
    end
  end

  local discovered, failed = fetch_nvim_sessions(pending_addresses)
  vim.list_extend(sessions, discovered)
  for _, address in ipairs(failed) do
    remove_stale_managed_nvim_socket(address)
  end

  table.sort(sessions, function(a, b)
    local function rank(session)
      if session.current then
        return 0
      end
      return session.ui_count == 0 and 1 or 2
    end

    local a_rank = rank(a)
    local b_rank = rank(b)
    if a_rank ~= b_rank then
      return a_rank < b_rank
    end
    if a.last_active ~= b.last_active then
      return a.last_active > b.last_active
    end
    if a.project ~= b.project then
      return a.project < b.project
    end
    return a.pid < b.pid
  end)

  return sessions
end

local function current_session_should_survive_switch()
  if normalize_nvim_session_name(vim.g.dotfiles_session_name) ~= ""
    or vim.g.dotfiles_session_detached_once == 1
    or vim.g.dotfiles_session_had_changes == 1
  then
    return true
  end

  if #vim.api.nvim_list_tabpages() > 1 then
    return true
  end

  local normal_windows = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      normal_windows = normal_windows + 1
    end
  end
  if normal_windows > 1 then
    return true
  end

  local named_file_buffers = 0
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      if vim.bo[bufnr].modified or vim.bo[bufnr].buftype == "terminal" then
        return true
      end
      if vim.bo[bufnr].buflisted
        and vim.bo[bufnr].buftype == ""
        and vim.api.nvim_buf_get_name(bufnr) ~= ""
      then
        named_file_buffers = named_file_buffers + 1
      end
    end
  end

  return named_file_buffers > 1
end

local session_environment_names = {
  "PATH",
  "HOME",
  "SHELL",
  "LANG",
  "LC_ALL",
  "LC_CTYPE",
  "SSH_AUTH_SOCK",
  "SSH_AGENT_PID",
  "SSH_CONNECTION",
  "SSH_CLIENT",
  "SSH_TTY",
  "DISPLAY",
  "WAYLAND_DISPLAY",
  "XDG_RUNTIME_DIR",
  "XDG_CONFIG_HOME",
  "XDG_DATA_HOME",
  "XDG_STATE_HOME",
  "XDG_CACHE_HOME",
  "CODEX_HOME",
  "CODEX_NOTIFY_LISTEN_PORT",
  "CODEX_NOTIFY_LISTENER_URL",
  "CODEX_NOTIFY_FORWARD_URL",
}

local sync_session_environment_lua = [=[
local environment = ...
for name, value in pairs(environment) do
  if value == false then
    vim.env[name] = nil
  else
    vim.env[name] = value
  end
end
return true
]=]

local function sync_nvim_session_environment(address)
  local environment = {}
  for _, name in ipairs(session_environment_names) do
    local value = vim.env[name]
    environment[name] = value and value ~= "" and value or false
  end

  local accepted, err = request_remote_nvim(address, sync_session_environment_lua, { environment })
  return accepted == true, err
end

local set_session_name_lua = [=[
local value = ...
local name = tostring(value or "")
name = vim.trim(name:gsub("[\r\n\t]", " "):gsub("%s+", " "))
vim.g.dotfiles_session_name = name
local lualine = package.loaded.lualine
if lualine and lualine.refresh then
  lualine.refresh({ place = { "statusline" }, scope = "all", force = true })
else
  vim.cmd("redrawstatus")
end
return name
]=]

local function set_nvim_session_name(session, name)
  name = normalize_nvim_session_name(name)
  if session.current or session.address == vim.v.servername then
    vim.g.dotfiles_session_name = name
    refresh_nvim_session_statusline()
    return true
  end

  local result, err = request_remote_nvim(session.address, set_session_name_lua, { name })
  if result == nil then
    return false, err or "目标 session 已不可用"
  end
  return true
end

local function create_managed_nvim_session(name, cwd, callback)
  name = normalize_nvim_session_name(name)
  local shell = vim.o.shell ~= "" and vim.o.shell or vim.env.SHELL
  if not shell or shell == "" then
    callback(nil, "找不到可用于创建 session 的 shell")
    return
  end

  local command = {
    shell,
    "-c",
    'source "$HOME/.shared_rc" && __dotfiles_nvim_start_host',
  }
  local options = {
    cwd = cwd,
    text = true,
    env = {
      DOTFILES_NVIM_SESSION_NAME = name,
      NVIM = "",
      NVIM_LISTEN_ADDRESS = "",
    },
  }

  local start_ok, err = pcall(vim.system, command, options, function(result)
    vim.schedule(function()
      local output = vim.trim(result.stdout or "")
      local lines = vim.split(output, "\n", { plain = true, trimempty = true })
      local address = lines[#lines]
      local stat = address and uv.fs_stat(address) or nil
      if result.code ~= 0 or not managed_nvim_session_id(address or "") or not stat or stat.type ~= "socket" then
        local detail = vim.trim(result.stderr or "")
        callback(nil, detail ~= "" and detail or "隐藏 Nvim host 未能启动")
        return
      end
      callback(address)
    end)
  end)
  if not start_ok then
    callback(nil, tostring(err))
  end
end

local function stop_managed_nvim_session(address)
  local session_id = managed_nvim_session_id(address)
  if not session_id then
    return false, "不是受托管的 Nvim session"
  end
  if vim.fn.executable("tmux") ~= 1 then
    return false, "找不到 tmux，无法清理托管 session"
  end

  local result = vim.system({
    "tmux",
    "-L",
    managed_nvim_tmux_server,
    "kill-session",
    "-t",
    session_id,
  }, { text = true, env = { TMUX = "" } }):wait(nvim_rpc_timeout_ms)
  if result.code ~= 0 then
    local detail = vim.trim(result.stderr or "")
    return false, detail ~= "" and detail or "隐藏 tmux session 未能停止"
  end
  local stat = uv.fs_stat(address)
  if stat and stat.type == "socket" then
    uv.fs_unlink(address)
  end
  return true
end

local stop_session_lua = [=[
vim.schedule(function()
  vim.cmd("qa!")
end)
return true
]=]

local function stop_nvim_session(session, callback)
  if session.current or session.address == vim.v.servername then
    callback(false, "当前 session 必须由本地 UI 退出，不能对自身发送停止 RPC")
    return
  end

  local function force_stop_managed()
    local stopped, err = stop_managed_nvim_session(session.address)
    callback(stopped, err)
  end

  -- 让目标 Nvim 在当前 RPC 返回后自行退出，避免 qa! 让请求半途断开。
  local accepted, err = request_remote_nvim(session.address, stop_session_lua)
  if accepted ~= true then
    if managed_nvim_session_id(session.address) then
      force_stop_managed()
    else
      callback(false, err or "目标 session 已不可用")
    end
    return
  end

  local attempts = 0
  local function wait_for_exit()
    attempts = attempts + 1
    if not fetch_nvim_session(session.address) then
      callback(true)
    elseif attempts < 5 then
      vim.defer_fn(wait_for_exit, 100)
    elseif managed_nvim_session_id(session.address) then
      force_stop_managed()
    else
      callback(false, "目标 session 未能退出")
    end
  end
  vim.defer_fn(wait_for_exit, 100)
end

local function stop_current_nvim_session()
  vim.schedule(function()
    local ok, err = pcall(vim.cmd, "qa!")
    if not ok then
      vim.notify("删除当前 Nvim session 失败: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

local function connect_to_nvim_session(address, keep_current)
  if address == vim.v.servername then
    return true
  end
  vim.g.dotfiles_session_last_active = os.time()
  local sync_ok, sync_err = sync_nvim_session_environment(address)
  if not sync_ok then
    vim.notify("连接 Nvim 会话失败: " .. tostring(sync_err or "目标 session 已不可用"), vim.log.levels.ERROR)
    return false
  end
  local command = keep_current and "connect " or "connect! "
  local ok, err = pcall(vim.cmd, command .. vim.fn.fnameescape(address))
  if not ok then
    vim.notify("连接 Nvim 会话失败: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
end

local function detach_nvim_session()
  if vim.g.dotfiles_session_instance ~= 1 or vim.fn.exists(":detach") ~= 2 then
    vim.notify("会话脱离需要 Neovim 0.12+ 的普通 TUI 实例", vim.log.levels.ERROR)
    return
  end

  vim.g.dotfiles_session_detached_once = 1
  vim.g.dotfiles_session_last_active = os.time()
  vim.cmd("detach")
end

local session_dashboard
if supports_nvim_sessions then
  local session_activity_group = vim.api.nvim_create_augroup("DotfilesNvimSessions", { clear = true })

  vim.api.nvim_create_autocmd("UIEnter", {
    group = session_activity_group,
    callback = function()
      vim.g.dotfiles_session_instance = 1
      vim.g.dotfiles_session_last_active = os.time()
      vim.g.dotfiles_ui_focused = 1
    end,
  })

  vim.api.nvim_create_autocmd("FocusGained", {
    group = session_activity_group,
    callback = function()
      vim.g.dotfiles_ui_focused = 1
    end,
  })

  vim.api.nvim_create_autocmd("FocusLost", {
    group = session_activity_group,
    callback = function()
      vim.g.dotfiles_ui_focused = 0
    end,
  })

  vim.api.nvim_create_autocmd({ "BufEnter", "CursorMoved", "CursorMovedI", "FocusGained" }, {
    group = session_activity_group,
    callback = function()
      if vim.g.dotfiles_session_instance ~= 1 then
        return
      end
      local now = os.time()
      if vim.g.dotfiles_session_last_active ~= now then
        vim.g.dotfiles_session_last_active = now
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = session_activity_group,
    callback = function(args)
      if vim.g.dotfiles_session_instance == 1
        and vim.api.nvim_buf_is_valid(args.buf)
        and vim.bo[args.buf].buftype == ""
        and vim.bo[args.buf].modified
      then
        vim.g.dotfiles_session_had_changes = 1
      end
    end,
  })

  vim.api.nvim_create_autocmd("UILeave", {
    group = session_activity_group,
    callback = function()
      if vim.g.dotfiles_session_instance == 1 then
        vim.g.dotfiles_session_detached_once = 1
        vim.g.dotfiles_session_last_active = os.time()
        if #vim.api.nvim_list_uis() <= 1 then
          vim.g.dotfiles_ui_focused = 0
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimEnter", {
    group = session_activity_group,
    once = true,
    callback = function()
      vim.defer_fn(function()
        if not current_nvim_session_is_managed() or #vim.api.nvim_list_uis() == 0 then
          return
        end
        local sessions = discover_nvim_sessions()
        if session_dashboard then
          session_dashboard.cleanup_expired(sessions)
        end
        local detached_count = 0
        for _, session in ipairs(sessions) do
          if session.ui_count == 0 and not session.trashed then
            detached_count = detached_count + 1
          end
        end
        if detached_count > 0 then
          vim.notify(("发现 %d 个已脱离的 Nvim 会话（Space f s）"):format(detached_count))
        end
      end, 150)
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = session_activity_group,
    once = true,
    callback = function()
      if vim.g.dotfiles_session_instance == 1 then
        clear_codex_agent(vim.v.servername, true)
      end
    end,
  })
end

if supports_nvim_sessions then
  session_dashboard = require("dotfiles.session_dashboard").setup({
    session_dir = managed_nvim_session_dir,
    discover_sessions = discover_nvim_sessions,
    read_agent_state = read_codex_agent_state,
    agent_working_frames = agent_working_frames,
    agent_ready_frames = agent_ready_frames,
    normalize_name = normalize_nvim_session_name,
    connect_session = function(session)
      return connect_to_nvim_session(session.address, current_session_should_survive_switch())
    end,
    create_session = create_managed_nvim_session,
    connect_created_session = function(address)
      if not connect_to_nvim_session(address, true) then
        stop_managed_nvim_session(address)
      end
    end,
    rename_session = set_nvim_session_name,
    stop_session = stop_nvim_session,
    stop_current_session = stop_current_nvim_session,
    detach_current_session = function()
      detach_nvim_session()
    end,
    clear_agent = function(address)
      clear_codex_agent(address, false)
    end,
  })

  vim.keymap.set("n", "<leader>fs", function()
    session_dashboard.open()
  end, { desc = "Nvim session dashboard" })
  vim.keymap.set("n", "<leader>fS", function()
    session_dashboard.open({ current_notes = true })
  end, { desc = "Current Nvim session tags" })
end

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

local function truncate_statusline_text(text, max_width)
  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end

  local suffix = "…"
  local available_width = max_width - vim.fn.strdisplaywidth(suffix)
  local width = 0
  local result = {}
  for index = 0, vim.fn.strchars(text) - 1 do
    local character = vim.fn.strcharpart(text, index, 1)
    local character_width = vim.fn.strdisplaywidth(character)
    if width + character_width > available_width then
      break
    end
    table.insert(result, character)
    width = width + character_width
  end
  return table.concat(result) .. suffix
end

local function nvim_session_statusline_label()
  if not current_nvim_session_is_managed() then
    return ""
  end

  local name = normalize_nvim_session_name(vim.g.dotfiles_session_name)
  if name == "" then
    local cwd = vim.fn.getcwd()
    local home = uv.os_homedir()
    name = cwd == home and "~" or vim.fn.fnamemodify(cwd, ":t")
    if name == "" then
      name = cwd
    end
    name = normalize_nvim_session_name(name)
  end

  return truncate_statusline_text(name, session_statusline_max_width)
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

local toggle_window_zoom_impl
local function toggle_window_zoom()
  if toggle_window_zoom_impl then
    toggle_window_zoom_impl()
    return
  end
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

local function project_context_dir(bufnr)
  local dir = buffer_context_dir(bufnr)
  if not dir or vim.fn.isdirectory(dir) == 0 then
    dir = vim.fn.getcwd()
  end

  if vim.fn.executable("git") == 1 then
    local git_root = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })[1]
    if vim.v.shell_error == 0 and git_root and git_root ~= "" then
      return vim.trim(git_root)
    end
  end

  return dir
end

local drawer_editor_target
local function open_oil_from_context()
  local dir = buffer_context_dir(0)
  if not dir or vim.fn.isdirectory(dir) == 0 then
    dir = vim.fn.getcwd()
  end

  local target = drawer_editor_target and drawer_editor_target() or nil
  if target then
    vim.api.nvim_set_current_win(target)
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
vim.keymap.set("n", "<leader>d", detach_nvim_session, { desc = "Detach Nvim session" })
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

  local target = drawer_editor_target and drawer_editor_target() or nil
  if target then
    vim.api.nvim_set_current_win(target)
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

local terminal_drawer = {
  win = nil,
  win_options = nil,
  return_win = nil,
  active = "shell",
  visible = false,
  mutation_depth = 0,
  repair_scheduled = false,
  shutting_down = false,
  min_height = 5,
  step = 2,
}

local terminal_sessions = {
  shell = {
    buf = nil,
    drawer = true,
    command = function()
      return vim.o.shell
    end,
    context_dir = buffer_context_dir,
    start_insert = true,
    default_height = function()
      return 12
    end,
  },
  codex = {
    buf = nil,
    drawer = false,
    command = { "codex", "--yolo", "--no-alt-screen" },
    label = "Codex",
    executable = "codex",
    is_agent = true,
    context_dir = project_context_dir,
    start_insert = false,
    default_height = function()
      return math.max(12, math.floor(vim.o.lines * 0.45))
    end,
  },
  grok = {
    buf = nil,
    drawer = false,
    command = { "grok", "--yolo" },
    label = "Grok",
    executable = "grok",
    is_agent = true,
    context_dir = project_context_dir,
    start_insert = false,
    default_height = function()
      return math.max(12, math.floor(vim.o.lines * 0.45))
    end,
  },
}

local agent_order = { "codex", "grok" }
local selected_agent_path = vim.fs.joinpath(vim.fn.stdpath("state"), "dotfiles-selected-agent")

local function available_agent_names()
  local names = {}
  for _, name in ipairs(agent_order) do
    local session = terminal_sessions[name]
    if session and session.is_agent and vim.fn.executable(session.executable) == 1 then
      names[#names + 1] = name
    end
  end
  return names
end

local function selected_agent_name()
  if vim.fn.filereadable(selected_agent_path) == 1 then
    local ok, lines = pcall(vim.fn.readfile, selected_agent_path, "", 1)
    if ok then
      local name = vim.trim(lines[1] or "")
      local session = terminal_sessions[name]
      if session and session.is_agent and vim.fn.executable(session.executable) == 1 then
        return name
      end
    end
  end

  return available_agent_names()[1]
end

local function save_selected_agent(name)
  local ok, result = pcall(vim.fn.writefile, { name }, selected_agent_path)
  if not ok or result ~= 0 then
    vim.notify("无法保存默认 agent: " .. tostring(result), vim.log.levels.WARN)
    return false
  end
  return true
end

local codex_terminal_activity = require("dotfiles.codex_terminal_activity").setup({
  idle_delay_ms = codex_terminal_idle_delay_ms,
  read_state = function()
    return read_codex_agent_state(vim.v.servername)
  end,
  mark_idle = mark_codex_agent_idle,
})

local function terminal_drawer_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  for _, session in pairs(terminal_sessions) do
    if session.drawer and session.buf == bufnr then
      return true
    end
  end
  return false
end

local function terminal_drawer_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  return win == terminal_drawer.win or terminal_drawer_buffer(vim.api.nvim_win_get_buf(win))
end

local function terminal_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  return vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "terminal"
end

local function agent_session_for_buffer(bufnr)
  for name, session in pairs(terminal_sessions) do
    if session.is_agent and session.buf == bufnr then
      return name, session
    end
  end
  return nil, nil
end

local protected_window_command
local function run_window_command(command)
  if protected_window_command then
    protected_window_command(command)
    return
  end
  vim.cmd(command)
end

local function counted_wincmd(key)
  local count = vim.v.count
  if count > 0 then
    return tostring(count) .. "wincmd " .. key
  end
  return "wincmd " .. key
end

local window_commands = {
  { key = "v", command = "vsplit", desc = "Split left and focus" },
  { key = "s", command = "split", desc = "Split above and focus" },
  { key = "V", command = "rightbelow vsplit", desc = "Split right and focus" },
  { key = "S", command = "rightbelow split", desc = "Split below and focus" },
  { key = "n", command = "new", desc = "New split" },
  { key = "c", command = "close", desc = "Close window" },
  { key = "q", command = "close", desc = "Close window" },
  { key = "o", command = "only", desc = "Keep only current editor window" },
}
for _, item in ipairs(window_commands) do
  vim.keymap.set("n", "<C-w>" .. item.key, function()
    run_window_command(item.command)
  end, { desc = item.desc })
end

for _, key in ipairs({ "H", "J", "K", "L", "r", "R", "x", "T", "=", "+", "-", "_", "|", ">", "<", "^" }) do
  vim.keymap.set("n", "<C-w>" .. key, function()
    run_window_command(counted_wincmd(key))
  end, { desc = "Editor-only window command " .. key })
end

local function open_new_buffer()
  local target = drawer_editor_target and drawer_editor_target() or nil
  if target then
    vim.api.nvim_set_current_win(target)
  end
  vim.cmd("enew")
end

local function editor_target_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) or win == terminal_drawer.win then
    return false
  end
  if vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then
    return false
  end
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return false
  end

  return vim.bo[vim.api.nvim_win_get_buf(win)].buftype ~= "terminal"
end

local function buffer_picker_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then
    return false
  end
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return false
  end
  return not terminal_drawer_buffer(vim.api.nvim_win_get_buf(win))
end

local function terminal_editor_target_window()
  local alternate_number = vim.fn.winnr("#")
  if alternate_number > 0 then
    local alternate = vim.fn.win_getid(alternate_number)
    if editor_target_window(alternate) then
      return alternate
    end
  end

  if editor_target_window(terminal_drawer.return_win) then
    return terminal_drawer.return_win
  end

  local drawer_pos = { vim.o.lines, 0 }
  if terminal_drawer.win and vim.api.nvim_win_is_valid(terminal_drawer.win) then
    drawer_pos = vim.api.nvim_win_get_position(terminal_drawer.win)
  end
  local best_win = nil
  local best_distance = math.huge
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if editor_target_window(win) then
      local pos = vim.api.nvim_win_get_position(win)
      local bottom = pos[1] + vim.api.nvim_win_get_height(win)
      local distance = math.abs(drawer_pos[1] - bottom) * 1000 + math.abs(drawer_pos[2] - pos[2])
      if distance < best_distance then
        best_win = win
        best_distance = distance
      end
    end
  end

  if best_win then
    return best_win
  end

  local current_win = vim.api.nvim_get_current_win()
  local _, session = agent_session_for_buffer(vim.api.nvim_win_get_buf(current_win))
  if session
    and not session.drawer
    and vim.api.nvim_win_get_config(current_win).relative == ""
  then
    return current_win
  end

  return nil
end

local function buffer_picker_target_window()
  local editor_win = terminal_editor_target_window()
  if buffer_picker_window(editor_win) then
    return editor_win
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if buffer_picker_window(win) then
      return win
    end
  end
  return nil
end

local function focus_editor_from_terminal()
  local current_win = vim.api.nvim_get_current_win()
  if not terminal_window(current_win) then
    return
  end

  local target_win = terminal_editor_target_window()
  if not editor_target_window(target_win) then
    local _, session = agent_session_for_buffer(vim.api.nvim_get_current_buf())
    if session
      and not session.drawer
      and session.return_buf
      and vim.api.nvim_buf_is_valid(session.return_buf)
      and session.return_buf ~= session.buf
    then
      vim.api.nvim_win_set_buf(current_win, session.return_buf)
      return
    end
    vim.notify("当前 tab 没有可切换的普通编辑窗口", vim.log.levels.WARN)
    return
  end

  vim.api.nvim_set_current_win(target_win)
end

local buffer_picker = require("dotfiles.buffer_picker").setup({
  is_protected_buffer = terminal_drawer_buffer,
  is_editor_window = buffer_picker_window,
  find_editor_window = buffer_picker_target_window,
})

local function terminal_hyperlink_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, -1, { row, col }, { row, col }, {
    details = true,
    overlap = true,
    type = "highlight",
  })

  for _, extmark in ipairs(extmarks) do
    local details = extmark[4]
    if details and details.url then
      return details.url
    end
  end

  return nil
end

local function delimited_reference_at_cursor(line, cursor_col, pattern)
  local offset = 1
  while true do
    local start_col, end_col, reference = line:find(pattern, offset)
    if not start_col then
      return nil
    end
    if cursor_col >= start_col and cursor_col <= end_col then
      return reference
    end
    offset = end_col + 1
  end
end

local codex_reference_unicode_suffixes = {
  "。",
  "，",
  "；",
  "！",
  "？",
  "、",
  "）",
  "】",
  "》",
  "」",
  "』",
  "”",
  "’",
}

local function trim_codex_reference_suffix(reference)
  reference = reference:gsub("[%[%]%(%)%{%}<>,;.!?`'\"|]+$", "")
  while reference ~= "" do
    local trimmed = false
    for _, suffix in ipairs(codex_reference_unicode_suffixes) do
      if vim.endswith(reference, suffix) then
        reference = reference:sub(1, #reference - #suffix)
        reference = reference:gsub("[%[%]%(%)%{%}<>,;.!?`'\"|]+$", "")
        trimmed = true
        break
      end
    end
    if not trimmed then
      break
    end
  end
  return reference
end

local codex_reference_location_patterns = {
  "^(.+:%d+:%d+)()",
  "^(.+:%d+)()",
  "^(.+#L%d+C%d+)()",
  "^(.+#L%d+)()",
}

local function truncate_codex_reference_context(reference, cursor_col)
  for _, pattern in ipairs(codex_reference_location_patterns) do
    local location, context_col = reference:match(pattern)
    if location then
      local separator_length = reference:sub(context_col, context_col):match("[,;.!?]") and 1 or nil
      if not separator_length then
        for _, separator in ipairs(codex_reference_unicode_suffixes) do
          if reference:sub(context_col, context_col + #separator - 1) == separator then
            separator_length = #separator
            break
          end
        end
      end

      if separator_length then
        if cursor_col <= #location + separator_length then
          return location
        end
        return nil
      end
    end
  end
  return reference
end

local function codex_reference_at_cursor()
  local hyperlink = terminal_hyperlink_at_cursor()
  if hyperlink then
    return hyperlink
  end

  local line = vim.api.nvim_get_current_line()
  local cursor_col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local reference = delimited_reference_at_cursor(line, cursor_col, "%[[^%]]+%]%(([^%)]+)%)")
    or delimited_reference_at_cursor(line, cursor_col, "`([^`]+)`")
  if reference then
    return vim.trim(reference)
  end

  if line:sub(cursor_col, cursor_col):match("%s") then
    return nil
  end

  local start_col = cursor_col
  while start_col > 1 and not line:sub(start_col - 1, start_col - 1):match("%s") do
    start_col = start_col - 1
  end
  local end_col = cursor_col
  while end_col < #line and not line:sub(end_col + 1, end_col + 1):match("%s") do
    end_col = end_col + 1
  end

  reference = line:sub(start_col, end_col)
  reference = truncate_codex_reference_context(reference, cursor_col - start_col + 1)
  if not reference then
    return nil
  end
  reference = reference:gsub("^[%[%]%(%)%{%}<>`'\"|]+", "")
  reference = trim_codex_reference_suffix(reference)
  return reference ~= "" and reference or nil
end

local function codex_reference_from_selection()
  if vim.fn.mode() ~= "v" then
    return nil
  end

  local region = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = "v" })
  if #region ~= 1 then
    return nil
  end

  local reference = vim.trim(region[1])
  reference = reference:gsub("^[%[%]%(%)%{%}<>`'\"|]+", "")
  reference = trim_codex_reference_suffix(reference)
  return reference ~= "" and reference or nil
end

local function split_path_location(reference)
  local path, line, column = reference:match("^(.-):(%d+):(%d+)$")
  if not path then
    path, line = reference:match("^(.-):(%d+)$")
  end
  if not path then
    path, line, column = reference:match("^(.-)#L(%d+)C(%d+)$")
  end
  if not path then
    path, line = reference:match("^(.-)#L(%d+)$")
  end

  return path or reference, tonumber(line), tonumber(column)
end

local function parse_codex_reference(reference)
  if reference:match("^%a[%w+.-]*://") and not vim.startswith(reference, "file://") then
    return { url = reference }
  end

  if vim.startswith(reference, "file://") then
    local file_uri, fragment = reference:match("^(file://[^#]+)#(.+)$")
    file_uri = file_uri or reference
    local path, line, column = split_path_location(file_uri)
    if fragment then
      local fragment_line, fragment_column = fragment:match("^L(%d+)C(%d+)$")
      fragment_line = fragment_line or fragment:match("^L(%d+)$")
      line = tonumber(fragment_line) or line
      column = tonumber(fragment_column) or column
    end
    return { path = vim.uri_to_fname(path), line = line, column = column }
  end

  local path, line, column = split_path_location(reference)
  return { path = path, line = line, column = column }
end

local function resolve_codex_path(session, path)
  path = vim.fs.normalize(path)
  if vim.fn.isabsolutepath(path) == 0 then
    local root = session.cwd or terminal_buffer_cwd(session.buf) or vim.fn.getcwd()
    path = vim.fs.normalize(vim.fs.joinpath(root, path))
  end
  return path
end

local function open_codex_reference(session, reference)
  reference = reference or codex_reference_at_cursor()
  if not reference then
    vim.notify("光标下没有可打开的 Codex 路径", vim.log.levels.WARN)
    return
  end

  local target = parse_codex_reference(reference)
  if target.url then
    local _, err = vim.ui.open(target.url)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
    end
    return
  end

  local path = resolve_codex_path(session, target.path)
  local stat = uv.fs_stat(path)
  if not stat then
    vim.notify("找不到 Codex 引用路径: " .. path, vim.log.levels.WARN)
    return
  end

  local target_win = terminal_editor_target_window()
  if not target_win then
    vim.notify("当前 tab 没有可用于打开路径的编辑窗口", vim.log.levels.WARN)
    return
  end

  vim.api.nvim_set_current_win(target_win)
  local ok, err = pcall(vim.api.nvim_cmd, { cmd = "edit", args = { path } }, {})
  if not ok then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  if stat.type == "file" and target.line then
    local line = math.min(math.max(target.line, 1), vim.api.nvim_buf_line_count(0))
    local text = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ""
    local column = math.min(math.max((target.column or 1) - 1, 0), #text)
    vim.api.nvim_win_set_cursor(target_win, { line, column })
    vim.cmd("normal! zvzz")
  end
end

local function codex_line_has_marker(line, marker)
  local text = line:gsub("^%s+", "")
  return text == marker or vim.startswith(text, marker .. " ")
end

local function codex_response_starts(bufnr)
  local starts = {}
  local waiting_for_response = false
  for line_number, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if codex_line_has_marker(line, "›") then
      waiting_for_response = true
    elseif waiting_for_response and codex_line_has_marker(line, "•") then
      starts[#starts + 1] = line_number
      waiting_for_response = false
    end
  end
  return starts
end

local function jump_codex_response(session, direction)
  if vim.api.nvim_get_current_buf() ~= session.buf then
    return
  end

  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  local remaining = vim.v.count1
  local target
  local starts = codex_response_starts(session.buf)
  if direction < 0 then
    for index = #starts, 1, -1 do
      if starts[index] < current_line then
        remaining = remaining - 1
        if remaining == 0 then
          target = starts[index]
          break
        end
      end
    end
  else
    for _, line_number in ipairs(starts) do
      if line_number > current_line then
        remaining = remaining - 1
        if remaining == 0 then
          target = line_number
          break
        end
      end
    end
  end

  if not target then
    vim.notify(direction < 0 and "没有更早的 Codex 回答" or "没有更晚的 Codex 回答", vim.log.levels.INFO)
    return
  end

  vim.api.nvim_win_set_cursor(0, { target, 0 })
  vim.cmd("normal! zt")
  local view = vim.fn.winsaveview()
  local changedtick = vim.api.nvim_buf_get_changedtick(session.buf)
  session.scroll_lock = { view = view, changedtick = changedtick }
  session.scroll_changedtick = changedtick
  session.view = vim.deepcopy(view)
end

local function configure_codex_buffer(session)
  codex_terminal_activity:attach(session.buf)
  vim.keymap.set("n", "[a", function()
    jump_codex_response(session, -1)
  end, { buffer = session.buf, desc = "Previous Codex response" })
  vim.keymap.set("n", "]a", function()
    jump_codex_response(session, 1)
  end, { buffer = session.buf, desc = "Next Codex response" })
  vim.keymap.set("n", "gx", function()
    open_codex_reference(session)
  end, { buffer = session.buf, desc = "Open Codex path in editor window" })
  vim.keymap.set("x", "gx", function()
    local reference = codex_reference_from_selection()
    vim.cmd("normal! \27")
    if not reference then
      vim.notify("请选择同一行内的 Codex 路径", vim.log.levels.WARN)
      return
    end
    open_codex_reference(session, reference)
  end, { buffer = session.buf, desc = "Open selected Codex path in editor window" })
end

local function configure_agent_buffer(session)
  vim.keymap.set("n", "G", function()
    local count = vim.v.count
    local last_line = vim.api.nvim_buf_line_count(session.buf)
    local unlock = count == 0 or count >= last_line
    if unlock then
      session.scroll_lock = nil
      session.scroll_changedtick = vim.api.nvim_buf_get_changedtick(session.buf)
    end
    vim.cmd("normal! " .. (count > 0 and tostring(count) or "") .. "G")
    if unlock and vim.api.nvim_get_current_buf() == session.buf then
      session.view = vim.fn.winsaveview()
    end
  end, { buffer = session.buf, desc = "Go to latest agent output" })
end

local function restore_terminal_drawer_window_options(win, options)
  if not win or not vim.api.nvim_win_is_valid(win) or not options then
    return
  end

  for name, value in pairs(options) do
    vim.wo[win][name] = value
  end
end

local function with_terminal_drawer_mutation(callback)
  terminal_drawer.mutation_depth = terminal_drawer.mutation_depth + 1
  local ok, result = xpcall(callback, debug.traceback)
  terminal_drawer.mutation_depth = terminal_drawer.mutation_depth - 1
  if not ok then
    error(result)
  end
  return result
end

local function save_terminal_drawer_view(win)
  local session = terminal_sessions[terminal_drawer.active]
  if not session or not session.buf or not vim.api.nvim_buf_is_valid(session.buf) then
    return
  end
  if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= session.buf then
    return
  end
  if session.is_agent and session.scroll_lock and session.scroll_lock.view then
    session.view = vim.deepcopy(session.scroll_lock.view)
    return
  end
  session.view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
end

local function visible_terminal_drawer_win()
  local win = terminal_drawer.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    terminal_drawer.win = nil
    terminal_drawer.win_options = nil
    return nil
  end
  return win
end

local function terminal_window_is_at_latest_output(win, bufnr)
  if not win or not vim.api.nvim_win_is_valid(win)
    or not bufnr or not vim.api.nvim_buf_is_valid(bufnr)
  then
    return false
  end
  local last_visible_line = vim.api.nvim_win_call(win, function()
    return vim.fn.line("w$")
  end)
  return last_visible_line >= vim.api.nvim_buf_line_count(bufnr)
end

local function current_agent_window()
  local win = vim.api.nvim_get_current_win()
  local name, session = agent_session_for_buffer(vim.api.nvim_win_get_buf(win))
  if not session then
    return nil, nil
  end
  if session.drawer then
    local drawer_win = visible_terminal_drawer_win()
    if win ~= drawer_win or terminal_drawer.active ~= name then
      return nil, nil
    end
  end
  return session, win
end

local function clear_agent_scroll_lock(session)
  if session then
    session.scroll_lock = nil
  end
end

local function restore_agent_scroll_lock(session, win)
  local lock = session and session.scroll_lock
  if not lock or lock.restoring or not lock.view then
    return
  end
  if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= session.buf then
    return
  end

  lock.restoring = true
  local view = vim.deepcopy(lock.view)
  local last_line = math.max(1, vim.api.nvim_buf_line_count(session.buf))
  view.lnum = math.max(1, math.min(last_line, tonumber(view.lnum) or 1))
  view.topline = math.max(1, math.min(last_line, tonumber(view.topline) or view.lnum))
  local ok = pcall(vim.api.nvim_win_call, win, function()
    vim.fn.winrestview(view)
  end)
  if ok then
    local restored = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    lock.view = restored
    session.view = vim.deepcopy(restored)
  end
  lock.changedtick = vim.api.nvim_buf_get_changedtick(session.buf)
  session.scroll_changedtick = lock.changedtick
  lock.restoring = false
end

local function schedule_agent_scroll_restore(session)
  local lock = session and session.scroll_lock
  if not lock or lock.restore_scheduled then
    return
  end
  lock.restore_scheduled = true
  vim.schedule(function()
    if session.scroll_lock ~= lock then
      return
    end
    lock.restore_scheduled = false
    for _, win in ipairs(vim.fn.win_findbuf(session.buf)) do
      if vim.api.nvim_win_is_valid(win) then
        restore_agent_scroll_lock(session, win)
        break
      end
    end
  end)
end

local function update_agent_scroll_lock()
  local session, win = current_agent_window()
  if not session then
    return
  end
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "t" then
    clear_agent_scroll_lock(session)
    return
  end

  local changedtick = vim.api.nvim_buf_get_changedtick(session.buf)
  local lock = session.scroll_lock
  if lock and lock.restoring then
    return
  end
  if lock and changedtick ~= lock.changedtick then
    schedule_agent_scroll_restore(session)
    return
  end
  if not lock and session.scroll_changedtick ~= changedtick then
    session.scroll_changedtick = changedtick
    return
  end
  if terminal_window_is_at_latest_output(win, session.buf) then
    clear_agent_scroll_lock(session)
    session.view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    return
  end

  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  session.scroll_lock = {
    view = view,
    changedtick = changedtick,
  }
  session.view = vim.deepcopy(view)
end

function _G.dotfiles_codex_is_observed()
  if vim.g.dotfiles_ui_focused ~= 1 or #vim.api.nvim_list_uis() == 0 then
    return false
  end
  local session = terminal_sessions.codex
  if not session.buf or not vim.api.nvim_buf_is_valid(session.buf) then
    return false
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= session.buf then
    return false
  end
  restore_agent_scroll_lock(session, win)
  return terminal_window_is_at_latest_output(win, session.buf)
end

local codex_observation_scheduled = false
local codex_observation_retry_scheduled = false

local function acknowledge_codex_if_observed()
  local state = read_codex_agent_state(vim.v.servername)
  if state.state == "ready" and state.unread
    and _G.dotfiles_codex_is_observed()
  then
    acknowledge_codex_agent(vim.v.servername)
  end
end

local function schedule_codex_observation()
  if codex_observation_scheduled then
    return
  end
  codex_observation_scheduled = true
  vim.schedule(function()
    codex_observation_scheduled = false
    acknowledge_codex_if_observed()
  end)
end

local function schedule_codex_observation_retry()
  schedule_codex_observation()
  if codex_observation_retry_scheduled then
    return
  end
  codex_observation_retry_scheduled = true
  vim.defer_fn(function()
    codex_observation_retry_scheduled = false
    schedule_codex_observation()
  end, 300)
end

local codex_observation_group = vim.api.nvim_create_augroup("dotfiles_codex_observation", { clear = true })
vim.api.nvim_create_autocmd({
  "UIEnter",
  "FocusGained",
  "WinEnter",
  "BufEnter",
  "WinScrolled",
  "CursorMoved",
  "CursorHold",
  "TermEnter",
}, {
  group = codex_observation_group,
  callback = schedule_codex_observation,
})
vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedT" }, {
  group = codex_observation_group,
  callback = function(args)
    if terminal_sessions.codex.buf == args.buf then
      schedule_codex_observation_retry()
    end
  end,
})

local agent_scroll_lock_group = vim.api.nvim_create_augroup("DotfilesAgentScrollLock", { clear = true })
vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
  group = agent_scroll_lock_group,
  callback = update_agent_scroll_lock,
})
vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedT" }, {
  group = agent_scroll_lock_group,
  callback = function(args)
    local _, session = agent_session_for_buffer(args.buf)
    if not session then
      return
    end
    session.scroll_changedtick = vim.api.nvim_buf_get_changedtick(args.buf)
    if session.scroll_lock then
      schedule_agent_scroll_restore(session)
    end
  end,
})
vim.api.nvim_create_autocmd("TermEnter", {
  group = agent_scroll_lock_group,
  callback = function(args)
    local _, session = agent_session_for_buffer(args.buf)
    clear_agent_scroll_lock(session)
  end,
})

local function terminal_job_running(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local job_id = vim.b[bufnr].terminal_job_id
  return type(job_id) == "number" and vim.fn.jobwait({ job_id }, 0)[1] == -1
end

local function terminal_drawer_max_height()
  local screen_cap = math.max(terminal_drawer.min_height, vim.o.lines - 5)
  return math.min(screen_cap, math.max(terminal_drawer.min_height, math.floor(vim.o.lines * 0.7)))
end

local function clamp_terminal_height(height)
  return math.max(terminal_drawer.min_height, math.min(terminal_drawer_max_height(), height))
end

local function terminal_session_height(session)
  if not session.height then
    session.height = session.default_height()
  end
  return clamp_terminal_height(session.height)
end

local function current_tab_editor_windows()
  local windows = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" and win ~= terminal_drawer.win then
      windows[#windows + 1] = win
    end
  end
  return windows
end

local function ensure_current_tab_editor_window()
  local current_win = vim.api.nvim_get_current_win()
  if
    vim.api.nvim_win_get_config(current_win).relative == ""
    and current_win ~= terminal_drawer.win
  then
    return current_win
  end

  local editors = current_tab_editor_windows()
  if editors[1] then
    return editors[1]
  end

  local drawer_win = visible_terminal_drawer_win()
  if drawer_win and vim.api.nvim_win_get_tabpage(drawer_win) == vim.api.nvim_get_current_tabpage() then
    return vim.api.nvim_win_call(drawer_win, function()
      vim.cmd("aboveleft new")
      return vim.api.nvim_get_current_win()
    end)
  end
  return nil
end

local function create_terminal_drawer(height)
  local anchor = ensure_current_tab_editor_window()
  if not anchor then
    return nil
  end

  terminal_drawer.win = vim.api.nvim_win_call(anchor, function()
    vim.cmd("botright " .. height .. "split")
    return vim.api.nvim_get_current_win()
  end)
  terminal_drawer.win_options = {
    winfixheight = vim.wo[terminal_drawer.win].winfixheight,
    number = vim.wo[terminal_drawer.win].number,
    relativenumber = vim.wo[terminal_drawer.win].relativenumber,
    signcolumn = vim.wo[terminal_drawer.win].signcolumn,
  }
  vim.wo[terminal_drawer.win].winfixheight = true
  vim.wo[terminal_drawer.win].number = false
  vim.wo[terminal_drawer.win].relativenumber = false
  vim.wo[terminal_drawer.win].signcolumn = "no"
  return terminal_drawer.win
end

local function detach_terminal_drawer_view()
  local drawer_win = visible_terminal_drawer_win()
  if not drawer_win then
    return true
  end

  save_terminal_drawer_view(drawer_win)
  local drawer_tab = vim.api.nvim_win_get_tabpage(drawer_win)
  local regular_windows = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(drawer_tab)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      regular_windows = regular_windows + 1
    end
  end

  local ok
  if regular_windows > 1 then
    ok = pcall(vim.api.nvim_win_close, drawer_win, false)
  else
    local replacement_buf = vim.api.nvim_create_buf(true, false)
    ok = pcall(vim.api.nvim_win_set_buf, drawer_win, replacement_buf)
    if ok then
      restore_terminal_drawer_window_options(drawer_win, terminal_drawer.win_options)
    end
  end
  if ok then
    terminal_drawer.win = nil
    terminal_drawer.win_options = nil
  end
  return ok
end

local function terminal_drawer_is_bottom(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then
    return false
  end
  local layout = vim.fn.winlayout()
  if layout[1] ~= "col" or type(layout[2]) ~= "table" or #layout[2] < 2 then
    return false
  end
  local last = layout[2][#layout[2]]
  return last[1] == "leaf" and last[2] == win
end

local function place_terminal_drawer_at_bottom(win, height)
  if not terminal_drawer_is_bottom(win) then
    vim.api.nvim_win_call(win, function()
      vim.cmd("wincmd J")
    end)
  end
  vim.api.nvim_win_set_height(win, height)
  vim.wo[win].winfixheight = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
end

local function start_terminal_session(session, target_win, dir)
  if session.buf and vim.api.nvim_buf_is_valid(session.buf) then
    pcall(vim.api.nvim_buf_delete, session.buf, { force = true })
  end
  session.view = nil
  session.scroll_lock = nil
  session.scroll_changedtick = nil
  vim.api.nvim_win_call(target_win, function()
    vim.cmd("enew")
    session.buf = vim.api.nvim_get_current_buf()
    vim.bo[session.buf].buflisted = not session.drawer
    vim.bo[session.buf].bufhidden = "hide"
    local command = type(session.command) == "function" and session.command() or session.command
    vim.fn.termopen(command, { cwd = dir })
  end)
  session.scroll_changedtick = vim.api.nvim_buf_get_changedtick(session.buf)
  session.cwd = dir
end

local function attach_terminal_session(name, drawer_win, dir, restart_exited)
  local session = terminal_sessions[name]
  if not session then
    return nil
  end

  if not session.buf or not vim.api.nvim_buf_is_valid(session.buf)
    or (restart_exited and not terminal_job_running(session.buf))
  then
    start_terminal_session(session, drawer_win, dir)
  else
    vim.api.nvim_win_set_buf(drawer_win, session.buf)
  end

  if name == "codex" then
    configure_codex_buffer(session)
  end
  if session.is_agent then
    configure_agent_buffer(session)
  end
  local saved_view = session.scroll_lock and session.scroll_lock.view or session.view
  if saved_view then
    pcall(vim.api.nvim_win_call, drawer_win, function()
      vim.fn.winrestview(saved_view)
    end)
  end
  return session
end

local function open_terminal_session(name, opts)
  opts = opts or {}
  local session = terminal_sessions[name]
  if not session then
    return
  end
  if session.executable and vim.fn.executable(session.executable) ~= 1 then
    vim.notify(session.executable .. " 不在 PATH 中，无法启动 agent", vim.log.levels.ERROR)
    return
  end

  local source_buf = vim.api.nvim_get_current_buf()
  local dir = session.context_dir(source_buf)
  if not dir or vim.fn.isdirectory(dir) == 0 then
    dir = vim.fn.getcwd()
  end

  local current_win = vim.api.nvim_get_current_win()
  local drawer_win = visible_terminal_drawer_win()
  if opts.update_return ~= false and current_win ~= drawer_win and editor_target_window(current_win) then
    terminal_drawer.return_win = current_win
  end
  local height = terminal_session_height(session)
  drawer_win = with_terminal_drawer_mutation(function()
    local tracked = visible_terminal_drawer_win()
    if tracked then
      save_terminal_drawer_view(tracked)
      if vim.api.nvim_win_get_tabpage(tracked) ~= vim.api.nvim_get_current_tabpage() then
        detach_terminal_drawer_view()
        tracked = nil
      end
    end

    terminal_drawer.visible = true
    terminal_drawer.active = name
    tracked = tracked or create_terminal_drawer(height)
    if not tracked then
      return nil
    end
    ensure_current_tab_editor_window()
    attach_terminal_session(name, tracked, dir, opts.restart_exited ~= false)
    place_terminal_drawer_at_bottom(tracked, height)
    return tracked
  end)
  if not drawer_win then
    vim.notify("无法创建底部 terminal drawer", vim.log.levels.ERROR)
    return
  end

  local session_buf = session.buf
  if opts.focus == false then
    return drawer_win
  end
  vim.schedule(function()
    if terminal_drawer.win == drawer_win
      and terminal_drawer.visible
      and terminal_drawer.active == name
      and vim.api.nvim_win_is_valid(drawer_win)
      and vim.api.nvim_win_get_buf(drawer_win) == session_buf
    then
      vim.api.nvim_set_current_win(drawer_win)
      vim.cmd(session.start_insert and "startinsert" or "stopinsert")
    end
  end)
  return drawer_win
end

local function set_active_terminal_height(height)
  local session = terminal_sessions[terminal_drawer.active]
  if not session then
    return
  end
  session.height = math.max(terminal_drawer.min_height, height)

  local drawer_win = visible_terminal_drawer_win()
  if drawer_win then
    with_terminal_drawer_mutation(function()
      place_terminal_drawer_at_bottom(drawer_win, terminal_session_height(session))
    end)
  end
end

local function resize_active_terminal(delta)
  local session = terminal_sessions[terminal_drawer.active]
  if session then
    set_active_terminal_height(terminal_session_height(session) + delta)
  end
end

local function hide_terminal_drawer()
  terminal_drawer.visible = false
  with_terminal_drawer_mutation(detach_terminal_drawer_view)
end

local function toggle_terminal_session(name)
  if terminal_drawer.visible and terminal_drawer.active == name then
    hide_terminal_drawer()
    return
  end

  open_terminal_session(name)
end

local function full_agent_window(session)
  if not session.buf or not vim.api.nvim_buf_is_valid(session.buf) then
    return nil
  end
  for _, win in ipairs(vim.fn.win_findbuf(session.buf)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
  return nil
end

local function full_agent_target_window()
  local current_win = vim.api.nvim_get_current_win()
  if terminal_drawer_window(current_win) then
    return terminal_editor_target_window() or ensure_current_tab_editor_window()
  end
  if vim.api.nvim_win_get_config(current_win).relative == "" then
    return current_win
  end
  return terminal_editor_target_window() or ensure_current_tab_editor_window()
end

local function hide_full_agent_session(session, win)
  local view = session.scroll_lock and session.scroll_lock.view
    or vim.api.nvim_win_call(win, vim.fn.winsaveview)
  session.view = vim.deepcopy(view)

  local replacement = session.return_buf
  if not replacement or not vim.api.nvim_buf_is_valid(replacement) or replacement == session.buf then
    replacement = vim.api.nvim_create_buf(true, false)
  end
  vim.api.nvim_win_set_buf(win, replacement)
end

local function toggle_full_agent_session(name)
  local session = terminal_sessions[name]
  if not session or session.drawer then
    return
  end
  if vim.fn.executable(session.executable) ~= 1 then
    vim.notify(session.executable .. " 不在 PATH 中，无法启动 agent", vim.log.levels.ERROR)
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  if session.buf
    and vim.api.nvim_buf_is_valid(session.buf)
    and vim.api.nvim_win_get_buf(current_win) == session.buf
  then
    hide_full_agent_session(session, current_win)
    return
  end

  local visible_win = full_agent_window(session)
  if visible_win then
    if terminal_drawer.visible then
      hide_terminal_drawer()
    end
    vim.api.nvim_set_current_win(visible_win)
    vim.cmd("stopinsert")
    return
  end

  local target_win = full_agent_target_window()
  local source_buf = vim.api.nvim_win_get_buf(target_win)
  local dir = session.context_dir(source_buf)
  if not dir or vim.fn.isdirectory(dir) == 0 then
    dir = vim.fn.getcwd()
  end
  session.return_buf = source_buf

  if terminal_drawer.visible then
    hide_terminal_drawer()
  end
  vim.api.nvim_set_current_win(target_win)
  attach_terminal_session(name, target_win, dir, true)
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(target_win)
      and session.buf
      and vim.api.nvim_buf_is_valid(session.buf)
      and vim.api.nvim_win_get_buf(target_win) == session.buf
    then
      vim.api.nvim_set_current_win(target_win)
      vim.cmd("stopinsert")
    end
  end)
end

local function ensure_terminal_drawer()
  if not terminal_drawer.visible or terminal_drawer.shutting_down then
    return
  end
  open_terminal_session(terminal_drawer.active, {
    focus = false,
    restart_exited = false,
    update_return = false,
  })
end

local function schedule_terminal_drawer_repair()
  if
    not terminal_drawer.visible
    or terminal_drawer.shutting_down
    or terminal_drawer.mutation_depth > 0
    or terminal_drawer.repair_scheduled
  then
    return
  end
  terminal_drawer.repair_scheduled = true
  vim.schedule(function()
    terminal_drawer.repair_scheduled = false
    if
      not terminal_drawer.visible
      or terminal_drawer.shutting_down
      or terminal_drawer.mutation_depth > 0
    then
      return
    end
    local ok, err = pcall(ensure_terminal_drawer)
    if not ok then
      vim.notify("无法恢复底部 terminal drawer: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

protected_window_command = function(command)
  local current_win = vim.api.nvim_get_current_win()
  if terminal_drawer_window(current_win) then
    vim.notify("底部 shell drawer 不参与窗口布局操作", vim.log.levels.INFO)
    return
  end

  local command_ok, command_err
  with_terminal_drawer_mutation(function()
    if terminal_drawer.visible then
      detach_terminal_drawer_view()
    end
    command_ok, command_err = pcall(vim.cmd, command)
    if terminal_drawer.visible then
      ensure_terminal_drawer()
    end
  end)
  if not command_ok then
    vim.notify(tostring(command_err), vim.log.levels.WARN)
  end
end

drawer_editor_target = function()
  if not terminal_drawer_window(vim.api.nvim_get_current_win()) then
    return nil
  end
  return terminal_editor_target_window() or ensure_current_tab_editor_window()
end

toggle_window_zoom_impl = function()
  if terminal_drawer_window(vim.api.nvim_get_current_win()) then
    vim.notify("请在普通 session window 执行 <leader>z", vim.log.levels.INFO)
    return
  end
  if vim.t.dotfiles_zoomed then
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("tabclose")
    else
      vim.notify("没有可恢复的原始布局", vim.log.levels.WARN)
    end
    return
  end

  if #current_tab_editor_windows() <= 1 then
    vim.notify("当前 tab 只有一个普通 session window", vim.log.levels.INFO)
    return
  end
  vim.cmd("tab split")
  vim.t.dotfiles_zoomed = true
  schedule_terminal_drawer_repair()
end

local terminal_drawer_guard_group = vim.api.nvim_create_augroup("DotfilesTerminalDrawerGuard", { clear = true })
vim.api.nvim_create_autocmd({
  "TabEnter",
  "WinEnter",
  "WinNew",
  "WinClosed",
  "WinResized",
  "VimResized",
  "BufWinEnter",
}, {
  group = terminal_drawer_guard_group,
  callback = schedule_terminal_drawer_repair,
})
vim.api.nvim_create_autocmd("CmdlineLeave", {
  group = terminal_drawer_guard_group,
  pattern = ":",
  callback = schedule_terminal_drawer_repair,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = terminal_drawer_guard_group,
  callback = function()
    terminal_drawer.shutting_down = true
  end,
})

local function toggle_selected_agent()
  local name = selected_agent_name()
  if not name then
    vim.notify("没有找到可用的 agent CLI", vim.log.levels.ERROR)
    return
  end
  local session = terminal_sessions[name]
  if session.drawer then
    toggle_terminal_session(name)
  else
    toggle_full_agent_session(name)
  end
end

local function select_terminal_agent()
  local current = selected_agent_name()
  local available = available_agent_names()
  if #available == 0 then
    vim.notify("没有找到可用的 agent CLI", vim.log.levels.ERROR)
    return
  end

  local choices = {}
  if current then
    choices[#choices + 1] = current
  end
  for _, name in ipairs(available) do
    if name ~= current then
      choices[#choices + 1] = name
    end
  end

  vim.ui.select(choices, {
    prompt = "Select agent",
    kind = "dotfiles_agent_select",
    format_item = function(name)
      local label = terminal_sessions[name].label or name
      return name == current and (label .. " (current)") or label
    end,
  }, function(name)
    if not name or name == current then
      return
    end
    if save_selected_agent(name) then
      vim.notify("默认 agent 已切换为 " .. (terminal_sessions[name].label or name))
    end
  end)
end

local function map_terminal_action(keys, action, desc)
  for _, key in ipairs(keys) do
    vim.keymap.set("n", key, action, { desc = desc })
    vim.keymap.set({ "i", "t" }, key, function()
      vim.cmd("stopinsert")
      vim.schedule(function()
        action()
      end)
    end, { desc = desc })
  end
end

map_terminal_action({ "<C-/>", "<C-_>" }, function()
  toggle_terminal_session("shell")
end, "Toggle shell terminal")
map_terminal_action({ "<M-/>" }, toggle_selected_agent, "Toggle selected agent")
map_terminal_action({ "<M-a>" }, select_terminal_agent, "Select terminal agent")

local terminal_navigation_group = vim.api.nvim_create_augroup("DotfilesTerminalNavigation", { clear = true })
vim.api.nvim_create_autocmd("TermOpen", {
  group = terminal_navigation_group,
  callback = function(args)
    vim.keymap.set("n", "<C-S-Del>", focus_editor_from_terminal, {
      buffer = args.buf,
      desc = "Focus editor from terminal",
    })
    vim.keymap.set("t", "<C-S-Del>", function()
      vim.cmd("stopinsert")
      vim.schedule(focus_editor_from_terminal)
    end, {
      buffer = args.buf,
      desc = "Focus editor from terminal",
    })
  end,
})

for _, key in ipairs({ "<M-+>", "<M-=>" }) do
  vim.keymap.set({ "n", "i", "t" }, key, function()
    resize_active_terminal(terminal_drawer.step)
  end, { desc = "Increase active terminal height" })
end
vim.keymap.set({ "n", "i", "t" }, "<M-->", function()
  resize_active_terminal(-terminal_drawer.step)
end, { desc = "Decrease active terminal height" })

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
vim.keymap.set("n", "<C-n>", open_new_buffer, { desc = "New scratch buffer" })

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
      sections = {
        lualine_a = {
          {
            nvim_session_statusline_label,
            cond = function()
              return current_nvim_session_is_managed()
            end,
            color = { fg = session_statusline_fg, bg = session_statusline_bg, gui = "bold" },
            separator = { right = "" },
          },
          "mode",
        },
      },
    },
  },
  {
    "stevearc/dressing.nvim",
    lazy = false,
    opts = {
      input = {
        relative = "editor",
        title_pos = "center",
        prefer_width = 40,
        get_config = function(opts)
          if opts.kind == "dotfiles_buffer_save_as" then
            return {
              relative = "win",
              min_width = 1,
              max_width = 0.9,
            }
          end
        end,
      },
      select = {
        enabled = true,
        get_config = function(opts)
          if opts.kind == "dotfiles_agent_select" then
            return {
              backend = "builtin",
              builtin = {
                show_numbers = false,
                min_height = 2,
                max_height = 8,
                min_width = { 24, 0.2 },
                max_width = { 60, 0.6 },
              },
            }
          end
          if opts.kind == "dotfiles_buffer_delete" or opts.kind == "dotfiles_terminal_buffer_delete" then
            return {
              backend = "builtin",
              builtin = {
                relative = "win",
                show_numbers = false,
                min_height = 1,
                max_height = opts.kind == "dotfiles_terminal_buffer_delete" and 2 or 3,
                min_width = 1,
                max_width = 0.9,
              },
            }
          end
          if opts.kind == "dotfiles_nvim_session_delete"
            or opts.kind == "dotfiles_nvim_session_note_delete"
          then
            return {
              backend = "builtin",
              builtin = {
                show_numbers = false,
                min_height = 2,
                max_height = 2,
                min_width = { 40, 0.2 },
                max_width = { 100, 0.8 },
              },
            }
          end
          return { enabled = false }
        end,
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

      vim.keymap.set("n", "<leader>fb", buffer_picker.open, { desc = "Manage session buffers" })
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
