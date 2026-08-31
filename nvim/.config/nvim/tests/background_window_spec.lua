local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(("%s: expected %s, got %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local terminal_groups = {
  Normal = "DotfilesBackgroundTerminalNormal",
  NormalNC = "DotfilesBackgroundTerminalNormalNC",
  SignColumn = "DotfilesBackgroundTerminalSignColumn",
  FoldColumn = "DotfilesBackgroundTerminalFoldColumn",
}

local function winhighlight_map(winid)
  local result = {}
  for entry in vim.wo[winid].winhighlight:gmatch("[^,]+") do
    local source, target = entry:match("^([^:]+):(.*)$")
    if source and target then
      result[source] = target
    end
  end
  return result
end

local function assert_terminal_background(winid, expected, message)
  local mappings = winhighlight_map(winid)
  for source, target in pairs(terminal_groups) do
    assert_equal(mappings[source], expected and target or nil, message .. " " .. source)
  end
end

require("dotfiles.background")._apply_for_test({ mode = "transparent" })

vim.cmd("tabnew")
local winid = vim.api.nvim_get_current_win()
local ordinary_buf = vim.api.nvim_get_current_buf()
vim.bo[ordinary_buf].bufhidden = "hide"
vim.wo[winid].winhighlight = "CursorLine:Visual,MatchParen:"

local terminal_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(winid, terminal_buf)
local terminal_job = vim.fn.termopen({ vim.o.shell, "-c", "sleep 30" })
assert_equal(vim.bo[terminal_buf].buftype, "terminal", "terminal buffer type")
assert_terminal_background(winid, true, "first terminal display")

vim.api.nvim_win_set_buf(winid, ordinary_buf)
assert_terminal_background(winid, false, "ordinary buffer after first terminal display")
assert_equal(winhighlight_map(winid).CursorLine, "Visual", "ordinary buffer custom mapping after first display")
assert_equal(winhighlight_map(winid).MatchParen, "", "ordinary buffer empty mapping after first display")

vim.api.nvim_win_set_buf(winid, terminal_buf)
assert_terminal_background(winid, true, "second terminal display")
vim.api.nvim_win_set_buf(winid, ordinary_buf)
assert_terminal_background(winid, false, "ordinary buffer after second terminal display")
assert_equal(winhighlight_map(winid).CursorLine, "Visual", "ordinary buffer custom mapping after second display")
assert_equal(winhighlight_map(winid).MatchParen, "", "ordinary buffer empty mapping after second display")

vim.api.nvim_win_set_buf(winid, terminal_buf)
local fresh_ordinary_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(winid, fresh_ordinary_buf)
assert_terminal_background(winid, false, "new ordinary buffer created from a terminal window")

pcall(vim.fn.jobstop, terminal_job)
print("background window integration: ok")
vim.cmd("qa!")
