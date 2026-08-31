local M = {}

local uv = vim.uv or vim.loop
local renderer = require("dotfiles.background_renderer")

local CANVAS_GROUPS = { "Normal", "NormalNC", "SignColumn", "FoldColumn" }
local TERMINAL_GROUPS = {
  Normal = "DotfilesBackgroundTerminalNormal",
  NormalNC = "DotfilesBackgroundTerminalNormalNC",
  SignColumn = "DotfilesBackgroundTerminalSignColumn",
  FoldColumn = "DotfilesBackgroundTerminalFoldColumn",
}
local MODES = { theme = true, tint = true, image = true, transparent = true }
local IMAGE_MODES = { fill = true, fit = true, stretch = true, tile = true }
local DEFAULTS = {
  version = 1,
  mode = "theme",
  hue = 0,
  saturation = 0,
  lightness = 0,
  image_path = "",
  image_mode = "fill",
  image_blend = 35,
  transparency = 0,
  blur = 0,
}

local state = vim.deepcopy(DEFAULTS)
local theme = {}
local configured = false
local state_path
local state_watcher
local state_reload_timer

local function release_renderer(wait_for_completion)
  local finished = false
  renderer.release(function()
    finished = true
  end)
  if wait_for_completion and not finished then
    vim.wait(1000, function()
      return finished
    end, 10)
  end
end

local function clamp(value, low, high)
  return math.min(high, math.max(low, value))
end

local function round(value)
  return math.floor(value + 0.5)
end

local function normalize_settings(value)
  value = type(value) == "table" and value or {}
  local result = vim.deepcopy(DEFAULTS)
  result.mode = MODES[value.mode] and value.mode or result.mode
  result.image_mode = IMAGE_MODES[value.image_mode] and value.image_mode or result.image_mode
  result.hue = clamp(round(tonumber(value.hue) or result.hue), -180, 180)
  result.saturation = clamp(round(tonumber(value.saturation) or result.saturation), -100, 100)
  result.lightness = clamp(round(tonumber(value.lightness) or result.lightness), -50, 50)
  result.image_blend = clamp(round(tonumber(value.image_blend) or result.image_blend), 0, 100)
  result.transparency = clamp(round(tonumber(value.transparency) or result.transparency), 0, 100)
  result.blur = clamp(round(tonumber(value.blur) or result.blur), 0, 30)
  result.image_path = type(value.image_path) == "string" and vim.fs.normalize(value.image_path) or ""
  if result.image_path == "." then
    result.image_path = ""
  end
  return result
end

local function int_to_hex(value)
  if type(value) ~= "number" then
    return nil
  end
  return ("#%06x"):format(value)
end

local function hex_to_rgb(value)
  if type(value) == "number" then
    value = int_to_hex(value)
  end
  local red, green, blue = tostring(value or ""):match("^#?(%x%x)(%x%x)(%x%x)$")
  if not red then
    return nil
  end
  return tonumber(red, 16) / 255, tonumber(green, 16) / 255, tonumber(blue, 16) / 255
end

local function rgb_to_hsl(red, green, blue)
  local maximum = math.max(red, green, blue)
  local minimum = math.min(red, green, blue)
  local lightness = (maximum + minimum) / 2
  if maximum == minimum then
    return 0, 0, lightness
  end

  local delta = maximum - minimum
  local saturation = lightness > 0.5 and delta / (2 - maximum - minimum) or delta / (maximum + minimum)
  local hue
  if maximum == red then
    hue = (green - blue) / delta + (green < blue and 6 or 0)
  elseif maximum == green then
    hue = (blue - red) / delta + 2
  else
    hue = (red - green) / delta + 4
  end
  return hue * 60, saturation, lightness
end

local function hue_component(first, second, hue)
  hue = hue % 1
  if hue < 1 / 6 then
    return first + (second - first) * 6 * hue
  end
  if hue < 1 / 2 then
    return second
  end
  if hue < 2 / 3 then
    return first + (second - first) * (2 / 3 - hue) * 6
  end
  return first
end

local function hsl_to_rgb(hue, saturation, lightness)
  if saturation == 0 then
    return lightness, lightness, lightness
  end
  local second = lightness < 0.5 and lightness * (1 + saturation) or lightness + saturation - lightness * saturation
  local first = 2 * lightness - second
  local normalized = (hue % 360) / 360
  return hue_component(first, second, normalized + 1 / 3),
    hue_component(first, second, normalized),
    hue_component(first, second, normalized - 1 / 3)
end

local function transform_color(value, settings)
  local red, green, blue = hex_to_rgb(value)
  if not red then
    return nil
  end
  local hue, saturation, lightness = rgb_to_hsl(red, green, blue)
  hue = (hue + settings.hue) % 360
  saturation = clamp(saturation + settings.saturation / 100, 0, 1)
  lightness = clamp(lightness + settings.lightness / 100, 0, 1)
  red, green, blue = hsl_to_rgb(hue, saturation, lightness)
  return ("#%02x%02x%02x"):format(round(red * 255), round(green * 255), round(blue * 255))
end

local function highlight(name)
  local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and value or {}
end

local function set_highlight(name, base, background)
  local value = vim.deepcopy(base or {})
  value.link = nil
  value.bg = background and tonumber(background:sub(2), 16) or nil
  vim.api.nvim_set_hl(0, name, value)
end

local function remove_winhighlights(value, removals)
  local result = {}
  for entry in tostring(value or ""):gmatch("[^,]+") do
    local source, target = entry:match("^([^:]+):(.*)$")
    if source and target and removals[source] == nil then
      result[#result + 1] = source .. ":" .. target
    end
  end
  return table.concat(result, ",")
end

local function merge_winhighlight(value, replacements)
  local result = {}
  local base = remove_winhighlights(value, replacements)
  if base ~= "" then
    result[#result + 1] = base
  end
  for _, source in ipairs(CANVAS_GROUPS) do
    if replacements[source] then
      result[#result + 1] = source .. ":" .. replacements[source]
    end
  end
  return table.concat(result, ",")
end

local function apply_window_background(winid)
  if not vim.api.nvim_win_is_valid(winid) then
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local terminal = vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == "terminal"
  -- Buffer views retain window-local options, so keep our mappings as an idempotent overlay.
  local current = vim.wo[winid].winhighlight
  local updated
  if terminal then
    updated = merge_winhighlight(current, TERMINAL_GROUPS)
  else
    updated = remove_winhighlights(current, TERMINAL_GROUPS)
  end
  if updated ~= current then
    vim.wo[winid].winhighlight = updated
  end
  vim.w[winid].dotfiles_background_winhighlight = nil
end

local function apply_all_windows()
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    apply_window_background(winid)
  end
end

local function capture_theme()
  theme = {}
  for _, name in ipairs(CANVAS_GROUPS) do
    theme[name] = highlight(name)
  end
  theme.normal_bg = int_to_hex(theme.Normal and theme.Normal.bg)
  for source, target in pairs(TERMINAL_GROUPS) do
    set_highlight(target, theme[source], int_to_hex(theme[source] and theme[source].bg))
  end
end

local function computed_background(settings)
  local base = theme.normal_bg
  if settings.mode == "tint" and base then
    return transform_color(base, settings)
  end
  if settings.mode == "theme" then
    return base
  end
  return nil
end

local function apply_highlights(settings)
  local background = computed_background(settings)
  for _, name in ipairs(CANVAS_GROUPS) do
    local group_background = settings.mode == "theme" and int_to_hex(theme[name] and theme[name].bg) or background
    set_highlight(name, theme[name], group_background)
  end
  apply_all_windows()
  vim.cmd("redraw")
end

local function load_state()
  local file = io.open(state_path, "r")
  if not file then
    return vim.deepcopy(DEFAULTS), false
  end
  local raw = file:read("*a")
  file:close()
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return vim.deepcopy(DEFAULTS), false
  end
  return normalize_settings(decoded), true
end

local function save_state(settings)
  local directory = vim.fs.dirname(state_path)
  vim.fn.mkdir(directory, "p", "0700")
  local temporary = state_path .. ".tmp." .. vim.fn.getpid()
  local file, error_message = io.open(temporary, "w")
  if not file then
    return false, error_message
  end
  local payload = vim.deepcopy(settings)
  payload.version = DEFAULTS.version
  file:write(vim.json.encode(payload), "\n")
  file:close()
  uv.fs_chmod(temporary, 384)
  local ok, rename_error = uv.fs_rename(temporary, state_path)
  if not ok then
    pcall(uv.fs_unlink, temporary)
    return false, rename_error
  end
  return true
end

local function start_state_watcher()
  local directory = vim.fs.dirname(state_path)
  vim.fn.mkdir(directory, "p", "0700")
  state_watcher = uv.new_fs_event()
  state_reload_timer = uv.new_timer()
  if not state_watcher or not state_reload_timer then
    return
  end
  state_watcher:start(directory, {}, function(_, filename)
    if filename ~= vim.fs.basename(state_path) then
      return
    end
    state_reload_timer:stop()
    state_reload_timer:start(80, 0, function()
      vim.schedule(function()
        if package.loaded["dotfiles.background_panel"] and require("dotfiles.background_panel").is_open() then
          return
        end
        local loaded, managed = load_state()
        if managed and not vim.deep_equal(loaded, state) then
          state = loaded
          apply_highlights(state)
        end
      end)
    end)
  end)
end

function M.setup(opts)
  if configured then
    return
  end
  configured = true
  opts = opts or {}
  state_path = opts.state_path or vim.fs.joinpath(vim.fn.stdpath("state"), "dotfiles-background.json")
  renderer.setup(opts.renderer)
  state, M.managed = load_state()
  capture_theme()
  apply_highlights(state)
  vim.opt.fillchars:append({ eob = " " })

  local group = vim.api.nvim_create_augroup("DotfilesBackground", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      capture_theme()
      apply_highlights(state)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "TermOpen", "WinEnter", "WinNew" }, {
    group = group,
    callback = function()
      apply_all_windows()
    end,
  })
  vim.api.nvim_create_autocmd({ "UIEnter", "FocusGained" }, {
    group = group,
    callback = function()
      if M.managed then
        renderer.refresh(state)
      end
    end,
  })
  vim.api.nvim_create_autocmd("UILeave", {
    group = group,
    callback = function()
      vim.schedule(function()
        if #vim.api.nvim_list_uis() == 0 then
          release_renderer(false)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      release_renderer(true)
      for _, handle in ipairs({ state_watcher, state_reload_timer }) do
        if handle and not handle:is_closing() then
          handle:close()
        end
      end
      renderer.close()
    end,
  })
  start_state_watcher()
  vim.keymap.set("n", "<leader>bg", M.open, { desc = "Adjust editor background" })
end

function M.open()
  require("dotfiles.background_panel").open(M)
end

function M.current()
  return vim.deepcopy(state)
end

function M.defaults()
  return vim.deepcopy(DEFAULTS)
end

function M.preview(settings, transaction)
  state = normalize_settings(settings)
  apply_highlights(state)
  if transaction then
    renderer.preview(state, transaction)
  end
end

function M.save(settings)
  state = normalize_settings(settings)
  apply_highlights(state)
  M.managed = true
  local ok, error_message = save_state(state)
  if not ok then
    vim.notify("Background state save failed: " .. tostring(error_message), vim.log.levels.ERROR)
  end
  return ok
end

function M.commit(settings, transaction, callback)
  local saved = M.save(settings)
  renderer.commit(state, transaction, function(renderer_ok, response)
    if not renderer_ok and response and response.error then
      vim.notify("Terminal background update failed: " .. tostring(response.error), vim.log.levels.WARN)
    end
    if callback then
      callback(saved and renderer_ok, response)
    end
  end)
end

function M.restore(settings, transaction)
  state = normalize_settings(settings)
  apply_highlights(state)
  if transaction then
    renderer.restore(state, transaction)
  elseif M.managed then
    renderer.refresh(state)
  end
end

function M.begin_terminal_transaction(callback)
  renderer.begin(callback)
end

function M.computed_color(settings)
  return computed_background(normalize_settings(settings))
end

function M.renderer_status()
  return renderer.status()
end

function M.bridge_status()
  local status = renderer.status()
  return status.label .. (status.detail and (" · " .. status.detail) or ""), status.label ~= "Nvim colors only"
end

function M._transform_color(value, settings)
  return transform_color(value, normalize_settings(settings))
end

function M._apply_for_test(settings)
  state = normalize_settings(settings)
  apply_highlights(state)
end

function M._theme_for_test()
  return vim.deepcopy(theme)
end

return M
