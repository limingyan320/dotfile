local M = { id = "kitty" }

local uv = vim.uv or vim.loop
local LAYOUTS = {
  fill = "cscaled",
  fit = "cscaled",
  stretch = "scaled",
  tile = "tiled",
}
local NATIVE_IMAGE_EXTENSIONS = {
  bmp = true,
  gif = true,
  jpeg = true,
  jpg = true,
  png = true,
  tif = true,
  tiff = true,
  webp = true,
}
local CACHE_VERSION = 2
local PASSWORD = "dotfiles nvim background"

local command
local processor
local runner
local explicit_address
local on_status = function() end
local online = false
local processing = false
local target
local lease
local apply_serial = 0
local processes = {}

local function schedule(callback, ...)
  local args = { ... }
  vim.schedule(function()
    callback(unpack(args))
  end)
end

local function default_runner(args, opts, callback)
  local process
  local ok, error_message = pcall(function()
    process = vim.system(args, {
      text = true,
      timeout = opts.timeout,
    }, function(result)
      processes[process] = nil
      schedule(callback, result.code == 0, result)
    end)
  end)
  if not ok then
    schedule(callback, false, { code = -1, stderr = tostring(error_message) })
    return
  end
  processes[process] = true
end

local function notify_status()
  on_status()
end

local function environment_is_kitty()
  if vim.env.KITTY_WINDOW_ID or vim.env.KITTY_PID or vim.env.KITTY_LISTEN_ON then
    return true
  end
  if tostring(vim.env.TERM or ""):lower():find("kitty", 1, true) then
    return true
  end
  return tostring(vim.env.TERM_PROGRAM or ""):lower() == "kitty"
end

local function find_command(explicit)
  if explicit and explicit ~= "" then
    return explicit
  end
  local kitten = vim.fn.exepath("kitten")
  if kitten ~= "" then
    return kitten
  end
  local bundled = "/Applications/kitty.app/Contents/MacOS/kitten"
  if vim.fn.executable(bundled) == 1 then
    return bundled
  end
  local kitty = vim.fn.exepath("kitty")
  if kitty ~= "" then
    return kitty
  end
  return nil
end

local function control_command(action, extra)
  local result = { command, "@" }
  if explicit_address and explicit_address ~= "" then
    result[#result + 1] = "--to"
    result[#result + 1] = explicit_address
  end
  if not vim.env.KITTY_LISTEN_ON then
    result[#result + 1] = "--password"
    result[#result + 1] = PASSWORD
  end
  result[#result + 1] = action
  vim.list_extend(result, extra or {})
  return result
end

local function error_message(result, fallback)
  local message = result and (result.stderr or result.stdout) or ""
  message = tostring(message or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return message ~= "" and message or fallback
end

local function run_control(action, extra, timeout, callback)
  if not command then
    schedule(callback, false, { error = "Kitty control client is not installed" })
    return
  end
  runner(control_command(action, extra), { timeout = timeout or 3000 }, function(ok, result)
    if not ok then
      online = false
      notify_status()
      callback(false, { error = error_message(result, "Kitty remote control failed") })
      return
    end
    online = true
    callback(true, result or {})
  end)
end

local function focused_target(raw)
  local ok, os_windows = pcall(vim.json.decode, raw or "")
  if not ok or type(os_windows) ~= "table" then
    return nil, "Kitty returned invalid window data"
  end
  local fallback
  local inherited_id = tonumber(vim.env.KITTY_WINDOW_ID)
  for _, os_window in ipairs(os_windows) do
    for _, tab in ipairs(os_window.tabs or {}) do
      for _, window in ipairs(tab.windows or {}) do
        local candidate = {
          window_id = tonumber(window.id),
          os_window_id = tonumber(os_window.id),
          background_opacity = tonumber(os_window.background_opacity) or 1,
          columns = tonumber(window.columns) or vim.o.columns,
          lines = tonumber(window.lines) or vim.o.lines,
        }
        if os_window.is_focused and tab.is_active and window.is_active then
          return candidate
        end
        if inherited_id and candidate.window_id == inherited_id then
          fallback = candidate
        end
      end
    end
  end
  return fallback, fallback and nil or "Cannot identify the active Kitty window"
end

local function image_background()
  for _, group in ipairs({ "DotfilesBackgroundTerminalNormal", "Normal" }) do
    local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    if ok and value.bg then
      return ("#%06x"):format(value.bg)
    end
  end
  return "#1a1b26"
end

local function cache_path(path, settings, current_target)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil, "Selected image is not readable"
  end
  local modified = stat.mtime and (stat.mtime.sec .. ":" .. stat.mtime.nsec) or "0"
  local key = table.concat({
    CACHE_VERSION,
    path,
    stat.size,
    modified,
    settings.image_mode,
    settings.image_blend,
    settings.transparency,
    settings.blur,
    current_target.columns,
    current_target.lines,
    image_background(),
  }, ":")
  local directory = vim.fs.joinpath(vim.fn.stdpath("cache"), "dotfiles-background", "kitty")
  vim.fn.mkdir(directory, "p", "0700")
  return vim.fs.joinpath(directory, vim.fn.sha256(key) .. ".png")
end

local function native_image(path)
  local extension = path:match("%.([^./]+)$")
  return extension and NATIVE_IMAGE_EXTENSIONS[extension:lower()] == true
end

local function needs_processing(path, settings)
  return settings.image_mode == "fit"
    or settings.image_blend < 100
    or settings.transparency > 0
    or settings.blur > 0
    or not native_image(path)
end

local function prepare_image(path, settings, current_target, serial, callback)
  if not needs_processing(path, settings) then
    callback(true, path)
    return
  end
  if not processor then
    if not native_image(path) then
      callback(false, { error = "Kitty needs ImageMagick to convert this image format" })
    else
      callback(true, path)
    end
    return
  end
  local output, path_error = cache_path(path, settings, current_target)
  if not output then
    callback(false, { error = path_error })
    return
  end
  if vim.fn.filereadable(output) == 1 then
    callback(true, output)
    return
  end

  local temporary = output .. ".tmp." .. vim.fn.getpid() .. "." .. serial .. ".png"
  local args = { processor, path .. "[0]" }
  if settings.image_mode == "fit" then
    local width = math.max(64, math.min(3000, current_target.columns * 10))
    local height = math.max(64, math.min(2400, current_target.lines * 20))
    vim.list_extend(args, {
      "-resize",
      width .. "x" .. height,
      "-background",
      image_background(),
      "-gravity",
      "center",
      "-extent",
      width .. "x" .. height,
    })
  end
  if settings.blur > 0 then
    vim.list_extend(args, { "-blur", "0x" .. settings.blur })
  end
  if settings.image_blend < 100 then
    vim.list_extend(args, { "-fill", image_background(), "-colorize", (100 - settings.image_blend) .. "%" })
  end
  if settings.transparency > 0 then
    vim.list_extend(args, {
      "-alpha",
      "on",
      "-channel",
      "A",
      "-evaluate",
      "multiply",
      ("%.4f"):format(1 - settings.transparency / 100),
      "+channel",
    })
  end
  args[#args + 1] = temporary

  processing = true
  notify_status()
  runner(args, { timeout = 20000 }, function(ok, result)
    processing = false
    notify_status()
    if serial ~= apply_serial then
      pcall(uv.fs_unlink, temporary)
      callback(false, { error = "Superseded background preview" })
      return
    end
    if not ok then
      pcall(uv.fs_unlink, temporary)
      callback(false, { error = error_message(result, "ImageMagick background processing failed") })
      return
    end
    local renamed, rename_error = uv.fs_rename(temporary, output)
    if not renamed and vim.fn.filereadable(output) ~= 1 then
      callback(false, { error = tostring(rename_error or "Cannot cache processed background") })
      return
    end
    callback(true, output)
  end)
end

local function match_args(current_target)
  return { "--match", "id:" .. current_target.window_id }
end

local function set_opacity(current_lease, opacity, callback)
  opacity = math.max(0, math.min(1, opacity))
  if current_lease.current_opacity and math.abs(current_lease.current_opacity - opacity) < 0.0001 then
    callback(true, {})
    return
  end
  local args = match_args(current_lease.target)
  args[#args + 1] = ("%.4f"):format(opacity)
  run_control("set-background-opacity", args, 3000, function(ok, response)
    if ok then
      current_lease.current_opacity = opacity
      current_lease.opacity_touched = true
    end
    callback(ok, response)
  end)
end

local function set_image(current_lease, path, layout, callback)
  local args = match_args(current_lease.target)
  vim.list_extend(args, { "--layout", layout, path })
  run_control("set-background-image", args, 20000, function(ok, response)
    if ok then
      current_lease.image_touched = true
    end
    callback(ok, response)
  end)
end

local function clear_image(current_lease, callback)
  if not current_lease.image_touched then
    callback(true, {})
    return
  end
  local args = match_args(current_lease.target)
  args[#args + 1] = "none"
  run_control("set-background-image", args, 5000, function(ok, response)
    if ok then
      current_lease.image_touched = false
    end
    callback(ok, response)
  end)
end

local function apply_settings(settings, transaction, callback)
  callback = callback or function() end
  local current_lease = transaction or lease
  if not current_lease or not current_lease.target then
    callback(false, { error = "Kitty renderer has no active lease" })
    return
  end
  apply_serial = apply_serial + 1
  local serial = apply_serial
  local opacity = 1 - settings.transparency / 100

  if settings.mode ~= "image" or settings.image_path == "" then
    clear_image(current_lease, function(image_ok, image_response)
      if not image_ok then
        callback(false, image_response)
        return
      end
      local desired = settings.mode == "transparent" and opacity or current_lease.original_opacity
      set_opacity(current_lease, desired, callback)
    end)
    return
  end

  prepare_image(settings.image_path, settings, current_lease.target, serial, function(image_ok, image_or_error)
    if not image_ok then
      callback(false, image_or_error)
      return
    end
    if serial ~= apply_serial then
      callback(false, { error = "Superseded background preview" })
      return
    end
    set_image(current_lease, image_or_error, LAYOUTS[settings.image_mode] or "cscaled", function(set_ok, response)
      if not set_ok then
        callback(false, response)
        return
      end
      set_opacity(current_lease, opacity, callback)
    end)
  end)
end

local function release_lease(current_lease, callback)
  apply_serial = apply_serial + 1
  clear_image(current_lease, function(image_ok, image_response)
    local function finish(opacity_ok, opacity_response)
      if lease == current_lease then
        lease = nil
      end
      callback(image_ok and opacity_ok, opacity_ok and image_response or opacity_response)
    end
    if not current_lease.opacity_touched then
      finish(true, {})
      return
    end
    set_opacity(current_lease, current_lease.original_opacity, finish)
  end)
end

function M.setup(opts)
  opts = opts or {}
  command = find_command(opts.command)
  explicit_address = opts.address or vim.env.DOTFILES_NVIM_KITTY_ADDRESS
  on_status = opts.on_status or on_status
  runner = opts.runner or default_runner
  local magick = opts.processor
  if magick ~= false and (not magick or magick == "") then
    magick = vim.fn.exepath("magick")
    if magick == "" then
      magick = vim.fn.exepath("convert")
    end
  end
  processor = magick and magick ~= "" and magick or nil
end

function M.probe(callback)
  if not environment_is_kitty() then
    callback(false, { error = "Not running inside Kitty" })
    return
  end
  if not command then
    callback(false, { error = "Kitty detected but kitten is not installed" })
    return
  end
  run_control("ls", {}, 1200, function(ok, response)
    if not ok then
      target = nil
      callback(false, response)
      return
    end
    local found, target_error = focused_target(response.stdout)
    if not found then
      target = nil
      online = false
      callback(false, { error = target_error })
      return
    end
    target = found
    online = true
    notify_status()
    callback(true, { renderer = M.id, target = vim.deepcopy(target) })
  end)
end

function M.begin(callback)
  if lease and target and lease.target.window_id == target.window_id then
    schedule(callback, true, lease, { reused = true })
    return
  end
  local function create()
    if not target then
      callback(false, nil, { error = "Kitty renderer is not connected" })
      return
    end
    lease = {
      renderer = M.id,
      target = vim.deepcopy(target),
      original_opacity = target.background_opacity,
      current_opacity = target.background_opacity,
      image_touched = false,
      opacity_touched = false,
    }
    callback(true, lease, {})
  end
  if lease then
    release_lease(lease, function()
      create()
    end)
  else
    create()
  end
end

function M.preview(settings, transaction)
  apply_settings(settings, transaction)
end

function M.apply(settings, callback)
  callback = callback or function() end
  M.begin(function(ok, transaction, response)
    if not ok then
      callback(false, response)
      return
    end
    apply_settings(settings, transaction, callback)
  end)
end

function M.bypass(_, callback)
  M.release(callback)
end

function M.commit(settings, transaction, callback)
  apply_settings(settings, transaction or lease, callback)
end

function M.restore(settings, transaction)
  apply_settings(settings, transaction or lease)
end

function M.release(callback)
  callback = callback or function() end
  if not lease then
    callback(true, { released = false })
    return
  end
  release_lease(lease, callback)
end

function M.status()
  local transport = vim.env.KITTY_LISTEN_ON and "local socket" or "terminal control"
  local effects = processor and "ImageMagick effects" or "raw images"
  local detail = transport .. " · image / layout / opacity · " .. effects
  if processing then
    detail = transport .. " · processing image"
  elseif not online then
    detail = transport .. " · disconnected"
  end
  return {
    label = "Kitty",
    detail = detail,
    capabilities = {
      color = true,
      image = true,
      image_layout = true,
      image_blend = processor ~= nil,
      transparency = true,
      blur = processor ~= nil,
    },
  }
end

function M.close()
  for process in pairs(processes) do
    pcall(process.kill, process, 15)
  end
  processes = {}
end

function M._layout_for_test(value)
  return LAYOUTS[value]
end

function M._blend_overlay_for_test(value)
  return 100 - value
end

return M
