local config_root = vim.fn.getcwd() .. "/nvim/.config/nvim"
package.path = config_root .. "/lua/?.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/lualine.nvim")

local list_uis = vim.api.nvim_list_uis
local schedule = vim.schedule
local uis = { { chan = 1 } }
vim.api.nvim_list_uis = function() return uis end
local scheduled = 0
vim.schedule = function(callback)
  scheduled = scheduled + 1
  schedule(callback)
end
local renders = 0
local lifecycle = require("dotfiles.lualine_lifecycle")
lifecycle.setup({
  options = { refresh = { statusline = 20, refresh_time = 5 } },
  sections = { lualine_a = { function() renders = renders + 1; return "fixture" end } },
  inactive_sections = {},
})
vim.wait(50)
assert(renders > 0, "statusline must render with an attached UI")
scheduled = 0
vim.wait(150, function() return false end, 5, true)
assert(scheduled <= 2, "blocked statusline and refresh checker must each queue at most one callback")

uis = {}
vim.api.nvim_exec_autocmds("UILeave", {})
local before = scheduled
local before_renders = renders
vim.wait(100)
assert(scheduled == before, "detached lualine must stop enqueuing work")
assert(renders == before_renders, "pre-detach callbacks must become stale")

uis = { { chan = 2 } }
vim.api.nvim_exec_autocmds("UIEnter", {})
assert(vim.wait(100, function() return renders > before_renders end), "reattach must resume lualine rendering")
before_renders = renders
-- UILeave with another UI remaining must keep the timers running.
vim.api.nvim_exec_autocmds("UILeave", {})
assert(vim.wait(100, function() return renders > before_renders end), "remaining UI must keep lualine alive")

uis = {}
vim.api.nvim_exec_autocmds("UILeave", {})
lifecycle.setup(require("lualine").get_config())
vim.wait(50)
before = scheduled
vim.wait(100)
assert(scheduled == before, "setup without a UI must leave all timers paused")
vim.api.nvim_exec_autocmds("VimLeavePre", {})
vim.api.nvim_list_uis = list_uis
vim.schedule = schedule
print("lualine queue bounds and UI lifecycle: ok")
