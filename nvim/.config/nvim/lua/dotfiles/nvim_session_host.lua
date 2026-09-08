local uv = vim.uv or vim.loop

local M = {}
local Host = {}
Host.__index = Host

local watchdog_script = [[
sleep "$1"

if "$2" -L "$3" has-session -t "$4" >/dev/null 2>&1; then
  pane_pid=$("$2" -L "$3" display-message -p -t "$4" '#{pane_pid}' 2>/dev/null)
  "$2" -L "$3" kill-session -t "$4" >/dev/null 2>&1 || :
  case "$pane_pid" in
    ''|*[!0-9]*) ;;
    *) kill -KILL "$pane_pid" >/dev/null 2>&1 || : ;;
  esac
fi

if ! "$2" -L "$3" has-session -t "$4" >/dev/null 2>&1 && [ -S "$5" ]; then
  rm -f "$5"
fi
]]

local function default_run(argv, timeout_ms)
  return vim.system(argv, { text = true, env = { TMUX = "" } }):wait(timeout_ms)
end

local function default_spawn(argv, options)
  return vim.system(argv, options)
end

local function default_kill(pid, signal)
  return uv.kill(pid, signal)
end

function Host:session_id(address)
  if type(address) ~= "string" or address == "" or self.session_dir == "" then
    return nil
  end

  local parent = vim.fs.normalize(vim.fn.fnamemodify(address, ":h"))
  if parent ~= self.session_dir then
    return nil
  end

  return vim.fn.fnamemodify(address, ":t"):match("^(nvim%-.+)%.sock$")
end

function Host:_run(argv)
  local ok, result = pcall(self.run, argv, self.timeout_ms)
  if not ok then
    return nil, tostring(result)
  end
  if type(result) ~= "table" or type(result.code) ~= "number" then
    return nil, "命令没有返回有效状态"
  end
  return result
end

function Host:has_session(address)
  local session_id = self:session_id(address)
  if not session_id then
    return nil, "不是受托管的 Nvim session"
  end
  if self.tmux == "" then
    return nil, "找不到 tmux，无法检查托管 session"
  end

  local result, err = self:_run({
    self.tmux,
    "-L",
    self.tmux_server,
    "has-session",
    "-t",
    session_id,
  })
  if not result then
    return nil, err
  end
  if result.code == 0 then
    return true
  end
  if result.code == 124 then
    return nil, "检查隐藏 tmux session 超时"
  end
  if result.code == 1 then
    return false
  end
  local detail = vim.trim(result.stderr or "")
  return nil, detail ~= "" and detail or "检查隐藏 tmux session 失败"
end

function Host:_pane_pid(session_id)
  local result = self:_run({
    self.tmux,
    "-L",
    self.tmux_server,
    "display-message",
    "-p",
    "-t",
    session_id,
    "#{pane_pid}",
  })
  if not result or result.code ~= 0 then
    return nil
  end
  local pid = tonumber(vim.trim(result.stdout or ""))
  if not pid or pid < 2 or pid % 1 ~= 0 then
    return nil
  end
  return pid
end

function Host:_cleanup_socket(address)
  if not self:session_id(address) then
    return false, "不是受托管的 Nvim session"
  end
  local stat = self.fs_stat(address)
  if not stat or stat.type ~= "socket" then
    return true
  end
  local ok, removed, err = pcall(self.fs_unlink, address)
  if not ok then
    return false, tostring(removed)
  end
  if removed == nil then
    return false, tostring(err or "无法删除失效的 Nvim socket")
  end
  return true
end

function Host:remove_stale_socket(address)
  local running, err = self:has_session(address)
  if running == nil then
    return false, err
  end
  if running then
    return false
  end
  return self:_cleanup_socket(address)
end

function Host:force_stop(address)
  local session_id = self:session_id(address)
  if not session_id then
    return false, "不是受托管的 Nvim session"
  end
  if self.tmux == "" then
    return false, "找不到 tmux，无法清理托管 session"
  end

  local running, check_err = self:has_session(address)
  if running == nil then
    return false, check_err
  end
  if not running then
    return self:_cleanup_socket(address)
  end

  local pane_pid = self:_pane_pid(session_id)
  local result, run_err = self:_run({
    self.tmux,
    "-L",
    self.tmux_server,
    "kill-session",
    "-t",
    session_id,
  })
  if not result then
    return false, run_err
  end
  if result.code ~= 0 then
    local still_running = self:has_session(address)
    if still_running ~= false then
      local detail = vim.trim(result.stderr or "")
      return false, detail ~= "" and detail or "隐藏 tmux session 未能停止"
    end
  end

  -- A Nvim stuck in wait_return can survive tmux's SIGHUP, so terminate the
  -- exact pane process captured before removing the session.
  if pane_pid then
    pcall(self.kill, pane_pid, 9)
  end
  return self:_cleanup_socket(address)
end

function Host:arm_watchdog(address, delay_ms)
  local session_id = self:session_id(address)
  if not session_id then
    return false, "不是受托管的 Nvim session"
  end
  if self.tmux == "" then
    return false, "找不到 tmux，无法启动 session watchdog"
  end
  if self.shell == "" then
    return false, "找不到 sh，无法启动 session watchdog"
  end

  local delay_seconds = math.max(tonumber(delay_ms) or self.watchdog_delay_ms, 100) / 1000
  local argv = {
    self.shell,
    "-c",
    watchdog_script,
    "dotfiles-nvim-session-watchdog",
    ("%.3f"):format(delay_seconds),
    self.tmux,
    self.tmux_server,
    session_id,
    address,
  }
  local ok, process = pcall(self.spawn, argv, {
    detach = true,
    stdin = false,
    stdout = false,
    stderr = false,
    env = { TMUX = "" },
  })
  if not ok or not process then
    return false, ok and "session watchdog 未能启动" or tostring(process)
  end
  return true
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.session_dir) == "string" and opts.session_dir ~= "", "session_dir is required")
  assert(type(opts.tmux_server) == "string" and opts.tmux_server ~= "", "tmux_server is required")

  return setmetatable({
    session_dir = vim.fs.normalize(opts.session_dir),
    tmux_server = opts.tmux_server,
    tmux = opts.tmux ~= nil and opts.tmux or vim.fn.exepath("tmux"),
    shell = opts.shell ~= nil and opts.shell or vim.fn.exepath("sh"),
    timeout_ms = tonumber(opts.timeout_ms) or 700,
    watchdog_delay_ms = tonumber(opts.watchdog_delay_ms) or 1200,
    run = opts.run or default_run,
    spawn = opts.spawn or default_spawn,
    kill = opts.kill or default_kill,
    fs_stat = opts.fs_stat or uv.fs_stat,
    fs_unlink = opts.fs_unlink or uv.fs_unlink,
  }, Host)
end

M._watchdog_script = watchdog_script

return M
