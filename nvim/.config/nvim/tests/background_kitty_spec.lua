local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(("%s: expected %s, got %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local root = vim.fn.getcwd()
package.path = table.concat({
  root .. "/nvim/.config/nvim/lua/?.lua",
  root .. "/nvim/.config/nvim/lua/?/init.lua",
  package.path,
}, ";")

local original_env = {
  KITTY_LISTEN_ON = vim.env.KITTY_LISTEN_ON,
  KITTY_WINDOW_ID = vim.env.KITTY_WINDOW_ID,
  TERM = vim.env.TERM,
}
vim.env.KITTY_LISTEN_ON = "unix:/tmp/test-kitty"
vim.env.KITTY_WINDOW_ID = "17"
vim.env.TERM = "xterm-kitty"

package.loaded["dotfiles.background_renderers.kitty"] = nil
local commands = {}
local function runner(command, _, callback)
  commands[#commands + 1] = vim.deepcopy(command)
  local action
  for _, argument in ipairs(command) do
    if argument == "ls" or argument == "set-background-image" or argument == "set-background-opacity" then
      action = argument
      break
    end
  end
  if action == "ls" then
    callback(true, {
      code = 0,
      stdout = vim.json.encode({
        {
          id = 3,
          is_focused = true,
          background_opacity = 0.82,
          tabs = {
            {
              is_active = true,
              windows = {
                { id = 17, is_active = true, columns = 120, lines = 40 },
              },
            },
          },
        },
      }),
    })
  else
    callback(true, { code = 0, stdout = "" })
  end
end

local kitty = require("dotfiles.background_renderers.kitty")
kitty.setup({ command = "/tmp/kitten", processor = false, runner = runner })

local probed = false
kitty.probe(function(ok, response)
  assert(ok, response and response.error or "Kitty probe failed")
  probed = true
end)
assert(probed, "Kitty probe should complete")

local transaction
kitty.begin(function(ok, value)
  assert(ok, "Kitty transaction should begin")
  transaction = value
end)
assert(transaction, "Kitty transaction should be available")
assert_equal(transaction.original_opacity, 0.82, "Kitty opacity snapshot")

local image = vim.fn.tempname() .. ".png"
vim.fn.writefile({ "test" }, image, "b")
local image_applied = false
kitty.commit({
  mode = "image",
  image_path = image,
  image_mode = "fill",
  image_blend = 0,
  transparency = 0,
  blur = 0,
}, transaction, function(ok, response)
  assert(ok, response and response.error or "Kitty image apply failed")
  image_applied = true
end)
assert(image_applied, "Kitty image should apply")

local image_command
for _, item in ipairs(commands) do
  if vim.tbl_contains(item, "set-background-image") and item[#item] == image then
    image_command = item
  end
end
assert(image_command, "Kitty image command should be issued")
assert_equal(image_command[#image_command], image, "Kitty image command path")
assert(vim.tbl_contains(image_command, "cscaled"), "Kitty fill should use cscaled layout")
assert(vim.tbl_contains(image_command, "id:17"), "Kitty command should target the leased window")

local transparent_applied = false
kitty.commit({
  mode = "transparent",
  image_path = "",
  image_mode = "fill",
  image_blend = 0,
  transparency = 40,
  blur = 0,
}, transaction, function(ok, response)
  assert(ok, response and response.error or "Kitty transparency apply failed")
  transparent_applied = true
end)
assert(transparent_applied, "Kitty transparency should apply")

local unsupported = vim.fn.tempname() .. ".avif"
vim.fn.writefile({ "test" }, unsupported, "b")
local unsupported_rejected = false
kitty.commit({
  mode = "image",
  image_path = unsupported,
  image_mode = "fill",
  image_blend = 0,
  transparency = 0,
  blur = 0,
}, transaction, function(ok, response)
  unsupported_rejected = not ok and response.error:find("ImageMagick", 1, true) ~= nil
end)
assert(unsupported_rejected, "Kitty should explain unsupported formats without ImageMagick")

local image_reapplied = false
kitty.commit({
  mode = "image",
  image_path = image,
  image_mode = "fill",
  image_blend = 0,
  transparency = 0,
  blur = 0,
}, transaction, function(ok)
  image_reapplied = ok
end)
assert(image_reapplied, "Kitty image should remain usable after a rejected format")

local clears_before_release = 0
for _, item in ipairs(commands) do
  if vim.tbl_contains(item, "set-background-image") and item[#item] == "none" then
    clears_before_release = clears_before_release + 1
  end
end

local released = false
kitty.release(function(ok, response)
  assert(ok, response and response.error or "Kitty release failed")
  released = true
end)
assert(released, "Kitty lease should release")

local clears_after_release = 0
local saw_restore_opacity = false
for _, item in ipairs(commands) do
  if vim.tbl_contains(item, "set-background-image") and item[#item] == "none" then
    clears_after_release = clears_after_release + 1
  end
  if vim.tbl_contains(item, "set-background-opacity") and item[#item] == "0.8200" then
    saw_restore_opacity = true
  end
end
assert(clears_after_release > clears_before_release, "Kitty release should remove the managed image")
assert(saw_restore_opacity, "Kitty release should restore the captured opacity")
assert_equal(kitty._layout_for_test("stretch"), "scaled", "Kitty stretch layout")
assert_equal(kitty._layout_for_test("tile"), "tiled", "Kitty tile layout")
assert_equal(kitty._blend_overlay_for_test(0), 100, "zero blend should hide the image")
assert_equal(kitty._blend_overlay_for_test(100), 0, "full blend should preserve the image")

pcall(vim.fn.delete, image)
pcall(vim.fn.delete, unsupported)
for name, value in pairs(original_env) do
  vim.env[name] = value
end

print("background kitty adapter: ok")
vim.cmd("qa!")
