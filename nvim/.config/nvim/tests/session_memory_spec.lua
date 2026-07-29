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

local memory = require("dotfiles.session_memory")
local mib = 1024 * 1024
local sessions = {
  { session_id = "one", pid = 100, address = "/tmp/one.sock" },
  { session_id = "two", pid = 200, address = "/tmp/two.sock" },
}
local process_snapshot = [[
100 1 10 nvim --embed --listen /tmp/one.sock
110 100 20 node /opt/homebrew/bin/codex --yolo
111 110 30 /vendor/@openai/codex/bin/codex --yolo
120 100 40 node /mason/bin/pyright-langserver --stdio
121 120 50 python jedi/inference/compiled/subprocess/__main__.py
130 100 60 /bin/zsh
140 100 65 /opt/homebrew/bin/gopls
200 1 70 /tmp/.mount_nvim/usr/bin/nvim --embed --listen /tmp/two.sock
210 1 80 nvim --embed --listen /tmp/two.sock
300 1 90 nvim --clean --headless
301 300 100 node worker.js
]]
local bytes_by_pid = {}
for pid = 100, 301 do
  bytes_by_pid[pid] = pid * mib
end

local result = memory.collect(sessions, {
  ps_output = process_snapshot,
  bytes_by_pid = bytes_by_pid,
  metric = "fixture",
})

assert_equal(result.metric, "fixture", "fixture metric")
assert_equal(result.sessions.one.nvim, 100 * mib, "first session Nvim memory")
assert_equal(result.sessions.one.codex, (110 + 111) * mib, "Codex descendants")
assert_equal(result.sessions.one.lsp, (120 + 121 + 140) * mib, "LSP processes and descendants")
assert_equal(result.sessions.one.other, 130 * mib, "other descendants")
assert_equal(result.sessions.one.process_count, 7, "first session process count")
assert_equal(result.sessions.two.nvim, (200 + 210) * mib, "AppImage helper association")
assert_equal(result.sessions.two.process_count, 2, "second session process count")
assert_equal(result.unmanaged.nvim, 300 * mib, "unmanaged Nvim memory")
assert_equal(result.unmanaged.other, 301 * mib, "unmanaged descendant memory")
assert_equal(result.unmanaged.nvim_process_count, 1, "unmanaged Nvim count")
assert_equal(result.summary.nvim, (100 + 200 + 210 + 300) * mib, "summary Nvim memory")
assert_equal(result.summary.codex, (110 + 111) * mib, "summary Codex memory")
assert_equal(result.summary.lsp, (120 + 121 + 140) * mib, "summary LSP memory")
assert_equal(result.summary.other, (130 + 301) * mib, "summary other memory")
assert_equal(result.summary.process_count, 11, "summary process count")
assert_equal(result.summary.session_count, 2, "summary session count")

local footprint = memory._parse_macos_footprint([[
nvim [100]: 64-bit    Footprint: 123 B (16384 bytes per page)
Auxiliary data:
    phys_footprint: 456 B
node [110]: 64-bit    Footprint: 789 B (16384 bytes per page)
]])
assert_equal(footprint, { [100] = 456, [110] = 789 }, "macOS footprint parser")
assert_equal(
  memory._parse_linux_smaps("Rss: 40 kB\nPss: 30 kB\nSwapPss: 5 kB\n"),
  35 * 1024,
  "Linux PSS and swap parser"
)

print("session memory tests passed")
