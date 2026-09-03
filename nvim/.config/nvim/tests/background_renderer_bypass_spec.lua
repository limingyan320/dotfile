local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(("%s: expected %s, got %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local background = require("dotfiles.background")

background._apply_for_test({ mode = "theme", renderer = "nvim" })
assert_equal(background.current().renderer, "nvim", "explicit renderer bypass")
assert_equal(background.renderer_status(), {
  label = "Renderer off",
  detail = "Nvim colors only",
  capabilities = { color = true },
}, "renderer bypass status")

background._apply_for_test({ mode = "theme", renderer = "invalid" })
assert_equal(background.current().renderer, "auto", "invalid renderer fallback")

background._apply_for_test({ mode = "theme", renderer = "nvim" })
require("dotfiles.background_panel").open(background)
vim.wait(100, function()
  return require("dotfiles.background_panel")._active_state() ~= nil
end)
local panel = require("dotfiles.background_panel")._active_state()
assert(panel and vim.api.nvim_buf_is_valid(panel.buf), "background panel should open")
local renderer_line = vim.api.nvim_buf_get_lines(panel.buf, 2, 3, false)[1]
assert(renderer_line:find("Off", 1, true), "background panel should expose the renderer bypass")

print("background renderer bypass: ok")
vim.cmd("qa!")
