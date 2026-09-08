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

local host_module = require("dotfiles.nvim_session_host")
local fixture_dir = "/tmp/dotfiles-nvim-host-spec"
local fixture_address = fixture_dir .. "/nvim-fixture.sock"

local commands = {}
local spawned
local killed = {}
local unlinked = {}
local session_running = true
local next_has_session_code
local host = host_module.new({
  session_dir = fixture_dir,
  tmux_server = "fixture-server",
  tmux = "/fixture/tmux",
  shell = "/bin/sh",
  run = function(argv)
    commands[#commands + 1] = vim.deepcopy(argv)
    local action = argv[4]
    if action == "has-session" then
      if next_has_session_code then
        local code = next_has_session_code
        next_has_session_code = nil
        return { code = code, stdout = "", stderr = "" }
      end
      return { code = session_running and 0 or 1, stdout = "", stderr = "" }
    end
    if action == "display-message" then
      return { code = 0, stdout = "4242\n", stderr = "" }
    end
    if action == "kill-session" then
      session_running = false
      return { code = 0, stdout = "", stderr = "" }
    end
    error("unexpected command: " .. vim.inspect(argv))
  end,
  spawn = function(argv, options)
    spawned = { argv = vim.deepcopy(argv), options = vim.deepcopy(options) }
    return { pid = 1234 }
  end,
  kill = function(pid, signal)
    killed[#killed + 1] = { pid = pid, signal = signal }
    return true
  end,
  fs_stat = function(address)
    return address == fixture_address and { type = "socket" } or nil
  end,
  fs_unlink = function(address)
    unlinked[#unlinked + 1] = address
    return true
  end,
})

assert_equal(host:session_id(fixture_address), "nvim-fixture", "managed session id")
assert_equal(host:session_id(fixture_dir .. "/other.sock"), nil, "reject unmanaged basename")
assert_equal(host:session_id("/tmp/elsewhere/nvim-fixture.sock"), nil, "reject unmanaged parent")

next_has_session_code = 124
local timed_out, timeout_err = host:has_session(fixture_address)
assert_equal(timed_out, nil, "tmux timeout is unknown, not exited")
assert(timeout_err:match("超时"), "tmux timeout should remain distinguishable from an exited session")

next_has_session_code = 2
local failed_check, failed_check_err = host:has_session(fixture_address)
assert_equal(failed_check, nil, "tmux command errors are unknown, not exited")
assert(failed_check_err:match("失败"), "tmux command errors should remain distinguishable from an exited session")

local stopped, stop_err = host:force_stop(fixture_address)
assert(stopped, stop_err)
assert_equal(killed, { { pid = 4242, signal = 9 } }, "force stop exact pane process")
assert_equal(unlinked, { fixture_address }, "force stop removes managed socket")
assert_equal(commands[#commands][4], "kill-session", "force stop removes only the target tmux session")

commands = {}
killed = {}
unlinked = {}
session_running = false
stopped, stop_err = host:force_stop(fixture_address)
assert(stopped, stop_err)
assert_equal(killed, {}, "already exited session does not signal a process")
assert_equal(unlinked, { fixture_address }, "already exited session still removes stale socket")

local armed, arm_err = host:arm_watchdog(fixture_address, 250)
assert(armed, arm_err)
assert_equal(spawned.argv[1], "/bin/sh", "watchdog shell")
assert_equal(spawned.argv[5], "0.250", "watchdog delay")
assert_equal(spawned.argv[8], "nvim-fixture", "watchdog tmux target")
assert_equal(spawned.argv[9], fixture_address, "watchdog socket target")
assert_equal(spawned.options.detach, true, "watchdog is detached from Nvim")

local integration_cleanup

local function run_integration_test()
  if vim.fn.executable("tmux") ~= 1 then
    print("nvim session host unit tests passed; tmux integration skipped")
    return
  end

  local unique = ("%d-%d"):format(vim.fn.getpid(), os.time())
  local temp_dir = "/tmp/dotfiles-nvim-watchdog-" .. unique
  local session_id = "nvim-watchdog-" .. unique
  local sibling_id = "sibling-" .. unique
  local address = vim.fs.joinpath(temp_dir, session_id .. ".sock")
  local init_path = vim.fs.joinpath(temp_dir, "init.lua")
  local tmux_server = "dotfiles-nvim-watchdog-test-" .. unique
  local tmux = vim.fn.exepath("tmux")
  local integration_host = host_module.new({
    session_dir = temp_dir,
    tmux_server = tmux_server,
    watchdog_delay_ms = 600,
  })

  integration_cleanup = function()
    vim.system({ tmux, "-L", tmux_server, "kill-server" }, {
      text = true,
      env = { TMUX = "" },
    }):wait(1000)
    vim.fn.delete(temp_dir, "rf")
  end

  vim.fn.mkdir(temp_dir, "p")
  vim.fn.writefile({
    "local timer = vim.uv.new_timer()",
    "timer:start(5, 5, vim.schedule_wrap(function() end))",
  }, init_path)

  local nvim_command = table.concat({
    vim.fn.shellescape(vim.v.progpath),
    "--embed",
    "--listen",
    vim.fn.shellescape(address),
    "-u",
    vim.fn.shellescape(init_path),
  }, " ")
  local created = vim.system({
    tmux,
    "-L",
    tmux_server,
    "-f",
    "/dev/null",
    "new-session",
    "-d",
    "-s",
    session_id,
    nvim_command,
  }, { text = true, env = { TMUX = "" } }):wait(2000)
  assert_equal(created.code, 0, "create isolated managed host")
  local sibling_created = vim.system({
    tmux,
    "-L",
    tmux_server,
    "new-session",
    "-d",
    "-s",
    sibling_id,
    "sleep 30",
  }, { text = true, env = { TMUX = "" } }):wait(2000)
  assert_equal(sibling_created.code, 0, "create sibling session on isolated server")
  local ready = vim.wait(2000, function()
    return integration_host:has_session(address) == true and (vim.uv or vim.loop).fs_stat(address) ~= nil
  end, 20)
  if not ready then
    local running, running_err = integration_host:has_session(address)
    local stat = (vim.uv or vim.loop).fs_stat(address)
    local sessions = vim.system({ tmux, "-L", tmux_server, "list-sessions", "-F", "#{session_name}" }, {
      text = true,
      env = { TMUX = "" },
    }):wait(1000)
    local debug_pid = integration_host:_pane_pid(session_id)
    local process = debug_pid and vim.system({ "ps", "-p", tostring(debug_pid), "-o", "command=" }, {
      text = true,
    }):wait(1000) or { stdout = "" }
    local detail = vim.system({ tmux, "-L", tmux_server, "capture-pane", "-p", "-t", session_id }, {
      text = true,
      env = { TMUX = "" },
    }):wait(1000)
    error(("isolated managed host should become ready: running=%s err=%s stat=%s sessions=%s process=%s pane=%s"):format(
      vim.inspect(running),
      vim.inspect(running_err),
      vim.inspect(stat),
      vim.inspect(vim.trim(sessions.stdout or sessions.stderr or "")),
      vim.inspect(vim.trim(process.stdout or process.stderr or "")),
      vim.inspect(vim.trim(detail.stderr or detail.stdout or ""))
    ))
  end

  local pane_pid = integration_host:_pane_pid(session_id)
  assert(pane_pid, "isolated managed host should expose a pane pid")
  armed, arm_err = integration_host:arm_watchdog(address)
  assert(armed, arm_err)
  vim.wait(150)
  assert_equal(integration_host:has_session(address), true, "fixture should remain alive before watchdog deadline")

  assert(vim.wait(3000, function()
    return integration_host:has_session(address) == false
  end, 20), "watchdog should remove a stuck managed session")
  assert(vim.wait(1000, function()
    return (vim.uv or vim.loop).fs_stat(address) == nil
  end, 20), "watchdog should remove the stale managed socket")
  local process_check = vim.system({ "ps", "-p", tostring(pane_pid), "-o", "pid=" }, { text = true }):wait(1000)
  assert(process_check.code ~= 0 or vim.trim(process_check.stdout or "") == "", "watchdog should terminate the pane process")
  local sibling_check = vim.system({ tmux, "-L", tmux_server, "has-session", "-t", sibling_id }, {
    text = true,
    env = { TMUX = "" },
  }):wait(1000)
  assert_equal(sibling_check.code, 0, "watchdog must not terminate the shared tmux server or sibling sessions")

  print("nvim session host tests passed")
end

local ok, err = xpcall(run_integration_test, debug.traceback)
-- The test server name is unique, so cleanup cannot affect real managed sessions.
if integration_cleanup then
  integration_cleanup()
end
if not ok then
  error(err)
end
