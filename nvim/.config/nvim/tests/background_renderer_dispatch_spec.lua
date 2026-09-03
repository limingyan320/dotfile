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

vim.env.DOTFILES_NVIM_BACKGROUND_RENDERER = nil
package.loaded["dotfiles.background_renderer"] = nil
package.loaded["dotfiles.background_renderers.kitty"] = nil
package.loaded["dotfiles.background_renderers.iterm2"] = nil

local calls = {
  apply = 0,
  begin = 0,
  bypass = 0,
  commit = 0,
  probe = 0,
  release = 0,
  restore = 0,
}
local fake = { id = "fake" }

function fake.setup() end

function fake.probe(callback)
  calls.probe = calls.probe + 1
  callback(true, { renderer = "fake" })
end

function fake.apply(_, callback)
  calls.apply = calls.apply + 1
  if callback then
    callback(true, {})
  end
end

function fake.bypass(_, callback)
  calls.bypass = calls.bypass + 1
  if callback then
    callback(true, {})
  end
end

function fake.begin(callback)
  calls.begin = calls.begin + 1
  callback(true, { transaction_id = "test" }, {})
end

function fake.preview() end

function fake.restore(_, _, callback)
  calls.restore = calls.restore + 1
  if callback then
    callback(true, {})
  end
end

function fake.commit(_, _, callback)
  calls.commit = calls.commit + 1
  callback(true, {})
end

function fake.release(callback)
  calls.release = calls.release + 1
  callback(true, {})
end

function fake.status()
  return { label = "fake", capabilities = {} }
end

package.preload["dotfiles.background_renderers.iterm2"] = function()
  return fake
end
package.preload["dotfiles.background_renderers.kitty"] = function()
  return {
    id = "kitty",
    setup = function() end,
    probe = function(callback)
      callback(false, { error = "not kitty" })
    end,
    release = function(callback)
      callback(true, {})
    end,
    status = function()
      return { label = "Kitty", capabilities = {} }
    end,
  }
end

local renderer = require("dotfiles.background_renderer")
renderer.setup()

renderer.refresh({ renderer = "nvim" })
assert_equal(calls.probe, 0, "startup bypass should not probe")
assert_equal(calls.bypass, 0, "startup bypass without an active adapter")

local bypass_committed = false
renderer.commit({ renderer = "nvim" }, nil, function(ok)
  bypass_committed = ok
end)
vim.wait(100, function()
  return bypass_committed
end)
assert_equal(calls.probe, 0, "bypass commit should not probe")

renderer.refresh({ renderer = "auto" })
vim.wait(100, function()
  return calls.apply == 1
end)
assert_equal(calls.probe, 1, "auto renderer should probe")
assert_equal(calls.apply, 1, "auto renderer should apply")

renderer.refresh({ renderer = "nvim" })
assert_equal(calls.bypass, 1, "active renderer should restore on bypass")

local transaction
renderer.begin(function(ok, value)
  assert(ok, "renderer transaction should begin")
  transaction = value
end)
vim.wait(100, function()
  return transaction ~= nil
end)

local transaction_committed = false
renderer.commit({ renderer = "nvim" }, transaction, function(ok)
  transaction_committed = ok
end)
vim.wait(100, function()
  return transaction_committed
end)
assert_equal(calls.commit, 0, "transaction bypass should not reapply terminal settings")
assert_equal(calls.release, 1, "transaction bypass should release its renderer lease")

local cancelled_transaction
renderer.begin(function(ok, value)
  assert(ok, "cancelled renderer transaction should begin")
  cancelled_transaction = value
end)
vim.wait(100, function()
  return cancelled_transaction ~= nil
end)
renderer.restore({ renderer = "nvim" }, cancelled_transaction)
assert_equal(calls.restore, 0, "cancelled bypass should not reapply terminal settings")
assert_equal(calls.release, 2, "cancelled bypass should release its renderer lease")

print("background renderer dispatch: ok")
