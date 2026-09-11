local uv = vim.uv or vim.loop

local M = {}
local Poll = {}
Poll.__index = Poll
local polls = {}

local function has_ui(leaving_channel)
  for _, ui in ipairs(vim.api.nvim_list_uis()) do
    if ui.chan ~= leaving_channel then
      return true
    end
  end
  return false
end

function Poll:pause()
  if not self.running then
    return
  end
  self.running = false
  self.generation = self.generation + 1
  self.timer:stop()
  if self.on_pause then
    self.on_pause()
  end
end

function Poll:resume()
  if self.closed or self.running then
    return
  end
  self.running = true
  if self.on_resume then
    self.on_resume()
  end
  self.timer:start(self.interval_ms, self.interval_ms, function()
    -- A blocked main loop must retain at most one scheduled callback per poll.
    if self.pending or not self.running then
      return
    end
    self.pending = true
    local generation = self.generation
    vim.schedule(function()
      self.pending = false
      if self.running and not self.closed and self.generation == generation then
        self.callback()
      end
    end)
  end)
end

function Poll:close()
  if self.closed then
    return
  end
  self:pause()
  self.closed = true
  polls[self] = nil
  self.timer:close()
end

function M.new(opts)
  local poll = setmetatable({
    timer = assert(uv.new_timer()),
    interval_ms = assert(opts.interval_ms),
    callback = assert(opts.callback),
    on_resume = opts.on_resume,
    on_pause = opts.on_pause,
    generation = 0,
    pending = false,
    running = false,
    closed = false,
  }, Poll)
  polls[poll] = true
  if has_ui() then
    poll:resume()
  end
  return poll
end

local group = vim.api.nvim_create_augroup("DotfilesUIPolls", { clear = true })
vim.api.nvim_create_autocmd({ "UIEnter", "UILeave" }, {
  group = group,
  callback = function(event)
    local attached = has_ui(event.event == "UILeave" and vim.v.event.chan or nil)
    for poll in pairs(polls) do
      if attached then
        poll:resume()
      else
        poll:pause()
      end
    end
  end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    for poll in pairs(polls) do
      poll:close()
    end
  end,
})

return M
