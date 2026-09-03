local M = {}

local adapters = {}
local active
local configured = false
local detecting = false
local detect_waiters = {}
local detection_error

local function emit_status()
  vim.schedule(function()
    vim.api.nvim_exec_autocmds("User", { pattern = "DotfilesBackgroundRenderer", modeline = false })
  end)
end

local function terminal_hint()
  if vim.env.KITTY_WINDOW_ID or vim.env.KITTY_PID or tostring(vim.env.TERM or ""):find("kitty", 1, true) then
    return "Kitty control unavailable"
  end
  if vim.env.WEZTERM_PANE or vim.env.WEZTERM_EXECUTABLE then
    return "WezTerm detected"
  end
  local program = tostring(vim.env.TERM_PROGRAM or "")
  if program:lower():find("iterm", 1, true) then
    return "iTerm2 helper unavailable"
  end
  if program ~= "" then
    return program .. " detected"
  end
  if vim.env.SSH_CONNECTION or vim.env.SSH_TTY then
    return "SSH bridge unavailable"
  end
  return "No terminal renderer"
end

local function bypassed(settings)
  return type(settings) == "table" and settings.renderer == "nvim"
end

local function finish_detection(adapter, error_message)
  active = adapter
  detection_error = error_message
  detecting = false
  local waiters = detect_waiters
  detect_waiters = {}
  emit_status()
  for _, callback in ipairs(waiters) do
    vim.schedule(function()
      callback(active, detection_error)
    end)
  end
end

local function probe_next(index, errors)
  local adapter = adapters[index]
  if not adapter then
    finish_detection(nil, errors[#errors])
    return
  end
  adapter.probe(function(ok, response)
    if ok then
      finish_detection(adapter)
      return
    end
    errors[#errors + 1] = response and response.error or (adapter.id .. " unavailable")
    probe_next(index + 1, errors)
  end)
end

function M.setup(opts)
  if configured then
    return
  end
  configured = true
  opts = opts or {}
  if vim.env.DOTFILES_NVIM_BACKGROUND_RENDERER == "nvim" then
    adapters = {}
    return
  end
  local failures = {}
  local function register(name, adapter_opts)
    local ok, adapter = pcall(require, "dotfiles.background_renderers." .. name)
    if not ok or type(adapter) ~= "table" then
      failures[#failures + 1] = ok and (name .. " adapter returned an invalid module") or tostring(adapter)
      return
    end
    adapter.setup(vim.tbl_extend("force", adapter_opts or {}, { on_status = emit_status }))
    adapters[#adapters + 1] = adapter
  end
  adapters = {}
  register("kitty", opts.kitty)
  register("iterm2", opts.iterm2)
  if #adapters == 0 and #failures > 0 then
    detection_error = failures[#failures]
  end
end

function M.detect(callback, force)
  callback = callback or function() end
  if vim.env.DOTFILES_NVIM_BACKGROUND_RENDERER == "nvim" then
    active = nil
    detection_error = "Forced Nvim renderer"
    vim.schedule(function()
      callback(nil, detection_error)
    end)
    return
  end
  if active and not force then
    vim.schedule(function()
      callback(active)
    end)
    return
  end
  detect_waiters[#detect_waiters + 1] = callback
  if detecting then
    return
  end
  detecting = true
  detection_error = nil
  emit_status()
  probe_next(1, {})
end

function M.refresh(settings)
  if bypassed(settings) then
    if active and active.bypass then
      active.bypass(settings)
    end
    return
  end
  M.detect(function(adapter)
    if adapter then
      adapter.apply(settings)
    end
  end, true)
end

function M.begin(callback)
  M.detect(function(adapter, error_message)
    if not adapter then
      callback(false, nil, { error = error_message or "No terminal renderer" })
      return
    end
    adapter.begin(function(ok, transaction, response)
      if transaction then
        transaction._adapter = adapter
      end
      callback(ok, transaction, response)
    end)
  end, true)
end

function M.preview(settings, transaction)
  if transaction and transaction._adapter then
    transaction._adapter.preview(settings, transaction)
  end
end

function M.restore(settings, transaction)
  if transaction and transaction._adapter then
    local adapter = transaction._adapter
    if bypassed(settings) and adapter.release then
      adapter.release(function() end)
    else
      adapter.restore(settings, transaction)
    end
  end
end

function M.commit(settings, transaction, callback)
  callback = callback or function() end
  if transaction and transaction._adapter then
    local adapter = transaction._adapter
    if bypassed(settings) and adapter.release then
      adapter.release(callback)
    else
      adapter.commit(settings, transaction, callback)
    end
    return
  end
  if bypassed(settings) then
    if active and active.release then
      active.release(callback)
    elseif active and active.bypass then
      active.bypass(settings, callback)
    else
      vim.schedule(function()
        callback(true, { bypassed = true })
      end)
    end
    return
  end
  M.detect(function(adapter, error_message)
    if not adapter then
      callback(true, { fallback = true, detail = error_message or "Nvim colors only" })
      return
    end
    adapter.apply(settings, callback)
  end, true)
end

function M.release(callback)
  callback = callback or function() end
  local releasers = {}
  for _, adapter in ipairs(adapters) do
    if adapter.release then
      releasers[#releasers + 1] = adapter
    end
  end
  if #releasers == 0 then
    callback(true, { released = false })
    return
  end

  local pending = #releasers
  local succeeded = true
  local last_response
  for _, adapter in ipairs(releasers) do
    adapter.release(function(ok, response)
      succeeded = succeeded and ok
      last_response = response or last_response
      pending = pending - 1
      if pending == 0 then
        callback(succeeded, last_response)
      end
    end)
  end
end

function M.status()
  if detecting then
    return {
      label = "Detecting terminal",
      detail = "capability handshake",
      capabilities = {},
    }
  end
  if active then
    return active.status()
  end
  return {
    label = "Nvim colors only",
    detail = detection_error or terminal_hint(),
    capabilities = { color = true },
  }
end

function M.close()
  for _, adapter in ipairs(adapters) do
    if adapter.close then
      adapter.close()
    end
  end
end

function M._active_for_test()
  return active
end

return M
