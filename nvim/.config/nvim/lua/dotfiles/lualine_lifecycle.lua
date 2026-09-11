local M = {}
local bindings = {}
local attached = false
local installed = false

local function has_ui(leaving_channel)
  for _, ui in ipairs(vim.api.nvim_list_uis()) do
    if ui.chan ~= leaving_channel then
      return true
    end
  end
  return false
end

local function pause(binding)
  if binding.timer:is_closing() or binding.paused then
    return
  end
  binding.generation = binding.generation + 1
  if binding.timer:is_active() then
    binding.repeat_ms = binding.timer:get_repeat()
    binding.paused = true
    binding.timer:stop()
  end
end

local function sync_uis(leaving_channel)
  attached = has_ui(leaving_channel)
  for timer, binding in pairs(bindings) do
    if timer:is_closing() then
      bindings[timer] = nil
    elseif not attached then
      pause(binding)
    elseif binding.paused then
      binding.paused = false
      timer:start(0, binding.repeat_ms, binding.callback)
    end
  end
end

local function install()
  if installed then
    return
  end
  installed = true
  attached = has_ui()
  local utils = require("lualine.utils.utils")
  local timer_call = utils.timer_call
  -- Keep lualine's error handling while bounding work before schedule_wrap.
  utils.timer_call = function(timer, augroup, fn, max_err, err_msg)
    local binding = { timer = timer, generation = 0, pending = false }
    bindings[timer] = binding
    local wrapped = timer_call(timer, augroup, function(...)
      binding.pending = false
      if attached and bindings[timer] == binding and binding.queued_generation == binding.generation then
        return fn(...)
      end
    end, max_err, err_msg)
    binding.callback = function(...)
      if not attached then
        pause(binding)
        return
      end
      if binding.pending then
        return
      end
      binding.pending = true
      binding.queued_generation = binding.generation
      return wrapped(...)
    end
    return binding.callback
  end

  local group = vim.api.nvim_create_augroup("DotfilesLualineLifecycle", { clear = true })
  vim.api.nvim_create_autocmd({ "UIEnter", "UILeave" }, {
    group = group,
    callback = function(event)
      sync_uis(event.event == "UILeave" and vim.v.event.chan or nil)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      attached = false
      for _, binding in pairs(bindings) do
        pause(binding)
      end
    end,
  })
end

function M.setup(opts)
  install()
  require("lualine").setup(opts)
  sync_uis()
end

return M
