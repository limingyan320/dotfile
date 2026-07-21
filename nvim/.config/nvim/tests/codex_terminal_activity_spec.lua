local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(("%s: expected %s, got %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local config_root = vim.fs.normalize(vim.fn.getcwd() .. "/nvim/.config/nvim")
package.path = table.concat({
  vim.fs.joinpath(config_root, "lua", "?.lua"),
  vim.fs.joinpath(config_root, "lua", "?", "init.lua"),
  package.path,
}, ";")

local activity = require("dotfiles.codex_terminal_activity")

local state = { state = "working", turn_id = "turn-1" }
local idle_calls = {}
local monitor = activity.setup({
  idle_delay_ms = 40,
  poll_interval_ms = 1000,
  register_autocmds = false,
  read_title = function()
    return "project"
  end,
  read_state = function()
    return vim.deepcopy(state)
  end,
  mark_idle = function(turn_id, reason)
    idle_calls[#idle_calls + 1] = { turn_id = turn_id, reason = reason }
    if state.state == "working" and state.turn_id == turn_id then
      state.state = "idle"
    end
  end,
})

local first_buf = vim.api.nvim_create_buf(false, true)
monitor:attach(first_buf)
monitor:title_activity(first_buf)
assert(
  vim.wait(200, function()
    return #idle_calls == 1
  end),
  "quiet terminal title should settle working state"
)
assert_equal(idle_calls[1], {
  turn_id = "turn-1",
  reason = "terminal-title-idle",
}, "title idle transition")

state = { state = "working", turn_id = "turn-debounce" }
idle_calls = {}
monitor:title_activity(first_buf)
vim.wait(25)
monitor:title_activity(first_buf)
vim.wait(25)
assert_equal(#idle_calls, 0, "new title activity should reset the idle deadline")
assert(
  vim.wait(100, function()
    return #idle_calls == 1
  end),
  "debounced title should eventually settle"
)

state = { state = "working", turn_id = "turn-2" }
idle_calls = {}
monitor:title_activity(first_buf)
vim.defer_fn(function()
  state = { state = "ready", turn_id = "turn-2", unread = true }
end, 10)
vim.wait(100)
assert_equal(#idle_calls, 0, "normal completion should not request an idle transition")
assert_equal(state.state, "ready", "normal completion must remain ready")

state = { state = "working", turn_id = "turn-3" }
idle_calls = {}
monitor:title_activity(first_buf)
vim.defer_fn(function()
  state = { state = "working", turn_id = "turn-4" }
end, 10)
vim.wait(100)
assert_equal(#idle_calls, 0, "stale timer should not request an idle transition")
assert_equal(state.turn_id, "turn-4", "stale timer must not clear a newer turn")
assert_equal(state.state, "working", "newer turn should remain working")

state = { state = "working", turn_id = "turn-5" }
idle_calls = {}
local second_buf = vim.api.nvim_create_buf(false, true)
monitor:attach(second_buf)
monitor:terminal_exit(second_buf)
assert_equal(idle_calls[1], {
  turn_id = "turn-5",
  reason = "terminal-exit",
}, "terminal exit transition")
assert_equal(state.state, "idle", "terminal exit should settle working state")

monitor:close()

state = { state = "working", turn_id = "turn-osc" }
idle_calls = {}
local osc_monitor = activity.setup({
  idle_delay_ms = 200,
  poll_interval_ms = 10,
  read_state = function()
    return vim.deepcopy(state)
  end,
  mark_idle = function(turn_id, reason)
    idle_calls[#idle_calls + 1] = { turn_id = turn_id, reason = reason }
    if state.state == "working" and state.turn_id == turn_id then
      state.state = "idle"
    end
  end,
})
local osc_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(osc_buf)
local osc_job = vim.fn.termopen({
  "sh",
  "-c",
  "sleep 0.05; printf '\\033]0;busy\\007'; sleep 0.50",
})
osc_monitor:attach(osc_buf)
local title_seen = vim.wait(250, function()
  return vim.b[osc_buf].term_title == "busy"
end)
assert(title_seen, "terminal should apply the OSC title update, got " .. vim.inspect(vim.b[osc_buf].term_title))
vim.wait(160)
assert_equal(#idle_calls, 0, "polled OSC title should reset the initial idle deadline")
assert(
  vim.wait(150, function()
    return #idle_calls == 1
  end),
  "title polling should observe an OSC title update"
)
assert_equal(idle_calls[1], {
  turn_id = "turn-osc",
  reason = "terminal-title-idle",
}, "OSC title integration")
pcall(vim.fn.jobstop, osc_job)
osc_monitor:close()

print("codex terminal activity: ok")
vim.cmd("qa!")
