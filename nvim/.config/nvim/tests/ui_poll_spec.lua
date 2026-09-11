local config_root = vim.fn.getcwd() .. "/nvim/.config/nvim"
package.path = config_root .. "/lua/?.lua;" .. package.path

local list_uis = vim.api.nvim_list_uis
local schedule = vim.schedule
local uis = { { chan = 1 } }
vim.api.nvim_list_uis = function()
  return uis
end
local scheduled = 0
vim.schedule = function(callback)
  scheduled = scheduled + 1
  schedule(callback)
end

local callbacks = 0
local poll = require("dotfiles.ui_poll").new({
  interval_ms = 5,
  callback = function()
    callbacks = callbacks + 1
  end,
})

-- Service libuv while deliberately starving the main-loop callback queue.
vim.wait(150, function() return false end, 5, true)
assert(scheduled == 1, "a blocked main loop must queue only one callback")
assert(callbacks == 0, "the main-loop callback must still be pending")

uis = {}
vim.api.nvim_exec_autocmds("UILeave", {})
assert(not poll.timer:is_active(), "last UI departure must stop the raw timer")
vim.wait(100, function() return false end, 5, true)
assert(scheduled == 1, "detached polls must not add callbacks")

uis = { { chan = 2 } }
vim.api.nvim_exec_autocmds("UIEnter", {})
assert(poll.timer:is_active(), "UI reattach must restart the raw timer")
vim.wait(100, function() return false end, 5, true)
assert(scheduled == 1, "reattaching must not bypass an outstanding callback")
-- Stop new ticks while consuming the callback queued before detach.
poll.timer:stop()
vim.wait(50, function() return not poll.pending end, 5)
assert(callbacks == 0, "callbacks queued before detach must become stale")

uis = {}
vim.api.nvim_exec_autocmds("UILeave", {})
uis = { { chan = 2 } }
vim.api.nvim_exec_autocmds("UIEnter", {})
assert(vim.wait(100, function() return callbacks > 0 end), "polling must resume")

poll:close()
local before_close = callbacks
vim.wait(50)
assert(callbacks == before_close, "closed polls must not run queued work")

uis = {}
local detached = require("dotfiles.ui_poll").new({ interval_ms = 5, callback = function() end })
assert(not detached.timer:is_active(), "a poll created without a UI must start paused")
vim.api.nvim_exec_autocmds("VimLeavePre", {})
assert(detached.closed, "shutdown must close paused polls too")

vim.schedule = schedule
vim.api.nvim_list_uis = list_uis
print("UI poll queue and lifecycle: ok")
