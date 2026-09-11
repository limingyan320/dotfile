local config_root = vim.fn.getcwd() .. "/nvim/.config/nvim"
local temp_dir = "/tmp/dotfiles-ui-poll-" .. vim.fn.getpid()
vim.fn.mkdir(temp_dir, "p")
local address = temp_dir .. "/host.sock"
local job
local second_ui
local request_id = 0

local function child_exec(code, channel)
  request_id = request_id + 1
  local response_path = temp_dir .. "/reply-" .. request_id .. ".json"
  local request = string.format([[
    local ok, result = xpcall(function() %s end, debug.traceback)
    vim.fn.writefile({vim.json.encode({ok = ok, result = result})}, %q)
  ]], code, response_path)
  vim.rpcnotify(channel or job, "nvim_exec_lua", request, {})
  assert(vim.wait(2000, function() return vim.fn.filereadable(response_path) == 1 end, 10),
    "embedded host RPC must respond within two seconds")
  local response = vim.json.decode(table.concat(vim.fn.readfile(response_path), "\n"))
  assert(response.ok, response.result)
  return response.result
end

local function rss_kib(pid)
  local result = vim.system({ "ps", "-p", tostring(pid), "-o", "rss=" }, { text = true }):wait(1000)
  assert(result.code == 0, "test child must remain alive")
  return assert(tonumber(vim.trim(result.stdout)))
end

local function run()
  job = vim.fn.jobstart({ vim.v.progpath, "--embed", "--listen", address, "-u", "NONE", "-i", "NONE" }, { rpc = true })
  assert(job > 0, "start isolated embedded Nvim")
  local pid = vim.fn.jobpid(job)
  vim.rpcnotify(job, "nvim_ui_attach", 100, 35, { rgb = true })
  child_exec(string.format([[
    package.path = %q .. "/lua/?.lua;" .. package.path
    _G.fixture = { reads = 0, idle = 0, scheduled = 0 }
    local schedule = vim.schedule
    vim.schedule = function(callback)
      fixture.scheduled = fixture.scheduled + 1
      schedule(callback)
    end
    fixture.monitor = require("dotfiles.codex_terminal_activity").setup({
      poll_interval_ms = 5,
      idle_delay_ms = 80,
      read_title = function()
        fixture.reads = fixture.reads + 1
        return "project"
      end,
      read_state = function() return {state = "working", turn_id = "fixture-turn"} end,
      mark_idle = function() fixture.idle = fixture.idle + 1 end,
    })
    fixture.buf = vim.api.nvim_create_buf(false, true)
    fixture.monitor:attach(fixture.buf)
    fixture.dashboard = require("dotfiles.session_dashboard").setup({
      notes_dir = %q .. "/notes",
      discover_sessions = function() return {} end,
      stop_session = function() end,
      stop_current_session = function() end,
      detach_current_session = function() end,
      clear_agent = function() end,
    })
    fixture.dashboard.open()
    return #vim.api.nvim_list_uis()
  ]], config_root, temp_dir))

  vim.wait(300)
  local active = child_exec([[
    return {reads = fixture.reads, frame = fixture.dashboard._active_dashboard().animation_frame}
  ]])
  assert(active.reads > 5 and active.frame > 1, "attached UI must poll titles and animate the dashboard")

  second_ui = vim.fn.sockconnect("pipe", address, { rpc = true })
  assert(second_ui > 0, "connect second UI")
  vim.rpcnotify(second_ui, "nvim_ui_attach", 100, 35, { rgb = true })
  assert(child_exec("return #vim.api.nvim_list_uis()", second_ui) == 2, "two real UIs must attach")
  vim.rpcnotify(job, "nvim_ui_detach")
  assert(child_exec("return #vim.api.nvim_list_uis()") == 1, "detach first UI")
  vim.wait(100)
  assert(child_exec("return fixture.reads") > active.reads, "remaining UI must keep the poll alive")

  vim.rpcnotify(second_ui, "nvim_ui_detach")
  assert(child_exec("return #vim.api.nvim_list_uis()", second_ui) == 0, "detach last UI")
  local snapshot_code = [[
    return {reads = fixture.reads, idle = fixture.idle, scheduled = fixture.scheduled,
      frame = fixture.dashboard._active_dashboard().animation_frame}
  ]]
  local detached = child_exec(snapshot_code)
  local samples = { rss_kib(pid) }
  for _ = 1, 4 do
    vim.wait(2000)
    samples[#samples + 1] = rss_kib(pid)
  end
  local after = child_exec(snapshot_code)
  assert(vim.deep_equal(after, detached), "no-UI host must not poll, animate, mark idle, or enqueue callbacks")
  assert(samples[#samples] - samples[1] < 2048, "detached host RSS must remain stable within 2 MiB")
  print("detached embedded host RSS (KiB): " .. table.concat(samples, ", "))

  local blocked_path = temp_dir .. "/blocked.json"
  child_exec(string.format([[
    fixture.audit = vim.uv.new_timer()
    fixture.audit:start(50, 50, function()
      local file = assert(io.open(%q, "w"))
      file:write(vim.json.encode({scheduled = fixture.scheduled}))
      file:close()
    end)
  ]], blocked_path))
  vim.rpcnotify(job, "nvim_input", "g")
  vim.wait(300)
  local blocked = vim.json.decode(table.concat(vim.fn.readfile(blocked_path), "\n"))
  assert(blocked.scheduled == after.scheduled, "pending normal-mode input must not accumulate detached callbacks")
  vim.rpcnotify(job, "nvim_input", "<Esc>")
  child_exec("fixture.audit:stop(); fixture.audit:close()")

  child_exec([[
    fixture.new_buf = vim.api.nvim_create_buf(false, true)
    fixture.monitor:attach(fixture.new_buf)
  ]])
  vim.wait(100)
  assert(child_exec("return fixture.reads") == after.reads, "monitors created without a UI must remain paused")
  vim.rpcnotify(job, "nvim_ui_attach", 100, 35, { rgb = true })
  assert(child_exec("return #vim.api.nvim_list_uis()") == 1, "reattach UI")
  vim.wait(300)
  local resumed = child_exec(snapshot_code)
  assert(resumed.reads > after.reads and resumed.frame > after.frame, "reattach must resume both polls")
  assert(resumed.idle > after.idle, "reattach must re-arm the title idle deadline")

  child_exec([[
    local watcher = fixture.monitor.watchers[fixture.new_buf]
    vim.api.nvim_buf_delete(fixture.new_buf, {force = true})
    assert(watcher.poll_timer.closed and watcher.idle_timer:is_closing(), "buffer wipe must release timers")
    fixture.monitor:close()
    local dashboard = fixture.dashboard._active_dashboard()
    vim.api.nvim_win_close(dashboard.winid, true)
    assert(dashboard.timer.closed, "dashboard close must release its poll")
  ]])
  print("embedded UI detach/reattach and memory regression: ok")
end

local ok, err = xpcall(run, debug.traceback)
if second_ui and second_ui > 0 then
  pcall(vim.fn.chanclose, second_ui)
end
if job and job > 0 then
  pcall(vim.fn.jobstop, job)
  assert(vim.fn.jobwait({ job }, 2000)[1] ~= -1, "test child must exit during cleanup")
end
vim.fn.delete(temp_dir, "rf")
assert(ok, err)
