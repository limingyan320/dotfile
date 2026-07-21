local uv = vim.uv or vim.loop

local M = {}
local Monitor = {}
Monitor.__index = Monitor

local function stop_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
  end
end

local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function close_watcher(watcher)
  if watcher then
    close_timer(watcher.poll_timer)
    close_timer(watcher.idle_timer)
  end
end

function Monitor:_working_turn()
  local ok, state = pcall(self.read_state)
  if not ok or type(state) ~= "table" or state.state ~= "working" then
    return nil
  end
  local turn_id = tostring(state.turn_id or "")
  return turn_id ~= "" and turn_id or nil
end

function Monitor:_mark_idle(turn_id, reason)
  if turn_id and turn_id ~= "" then
    pcall(self.mark_idle, turn_id, reason)
  end
end

function Monitor:title_activity(bufnr)
  local watcher = self.watchers[bufnr]
  if not watcher then
    return
  end

  stop_timer(watcher.idle_timer)
  local turn_id = self:_working_turn()
  if not turn_id then
    return
  end

  watcher.idle_timer:start(
    self.idle_delay_ms,
    0,
    vim.schedule_wrap(function()
      if self.watchers[bufnr] == watcher and self:_working_turn() == turn_id then
        self:_mark_idle(turn_id, "terminal-title-idle")
      end
    end)
  )
end

function Monitor:sample_title(bufnr)
  local watcher = self.watchers[bufnr]
  if not watcher then
    return
  end
  local ok, title = pcall(self.read_title, bufnr)
  if not ok then
    return
  end
  title = tostring(title or "")
  if title == watcher.last_title then
    return
  end
  watcher.last_title = title
  self:title_activity(bufnr)
end

function Monitor:terminal_exit(bufnr)
  local watcher = self.watchers[bufnr]
  if not watcher then
    return
  end
  self.watchers[bufnr] = nil
  close_watcher(watcher)
  self:_mark_idle(self:_working_turn(), "terminal-exit")
end

function Monitor:attach(bufnr)
  if self.watchers[bufnr] then
    return
  end
  local watcher = {
    poll_timer = assert(uv.new_timer()),
    idle_timer = assert(uv.new_timer()),
  }
  self.watchers[bufnr] = watcher
  self:sample_title(bufnr)
  watcher.poll_timer:start(
    self.poll_interval_ms,
    self.poll_interval_ms,
    vim.schedule_wrap(function()
      if self.watchers[bufnr] == watcher then
        self:sample_title(bufnr)
      end
    end)
  )
end

function Monitor:close()
  for bufnr, watcher in pairs(self.watchers) do
    self.watchers[bufnr] = nil
    close_watcher(watcher)
  end
end

function M.setup(opts)
  assert(type(opts) == "table", "Codex terminal activity setup requires options")
  assert(type(opts.read_state) == "function", "read_state callback is required")
  assert(type(opts.mark_idle) == "function", "mark_idle callback is required")

  local monitor = setmetatable({
    read_state = opts.read_state,
    read_title = opts.read_title or function(bufnr)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return ""
      end
      return vim.b[bufnr].term_title or ""
    end,
    mark_idle = opts.mark_idle,
    idle_delay_ms = tonumber(opts.idle_delay_ms) or 6000,
    poll_interval_ms = tonumber(opts.poll_interval_ms) or 200,
    watchers = {},
  }, Monitor)

  if opts.register_autocmds ~= false then
    local group = vim.api.nvim_create_augroup("DotfilesCodexTerminalActivity", { clear = true })
    vim.api.nvim_create_autocmd("TermClose", {
      group = group,
      callback = function(event)
        monitor:terminal_exit(event.buf)
      end,
    })
  end

  return monitor
end

return M
