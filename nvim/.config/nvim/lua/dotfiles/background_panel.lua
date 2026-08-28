local M = {}

local active

local ROWS = {
  "mode",
  "image_path",
  "image_mode",
  "hue",
  "saturation",
  "lightness",
  "image_blend",
  "transparency",
  "blur",
}
local MODE_ORDER = { "theme", "tint", "image", "transparent" }
local MODE_LABELS = { theme = "Theme", tint = "Tint", image = "Image", transparent = "Transparent" }
local IMAGE_MODE_ORDER = { "fill", "fit", "stretch", "tile" }
local IMAGE_MODE_LABELS = { fill = "Fill", fit = "Fit", stretch = "Stretch", tile = "Tile" }
local NUMERIC = {
  hue = { label = "Hue", minimum = -180, maximum = 180, small = 2, large = 10, suffix = " deg" },
  saturation = { label = "Saturation", minimum = -100, maximum = 100, small = 2, large = 10, suffix = "%" },
  lightness = { label = "Lightness", minimum = -50, maximum = 50, small = 1, large = 5, suffix = "%" },
  image_blend = { label = "Image blend", minimum = 0, maximum = 100, small = 2, large = 10, suffix = "%" },
  transparency = { label = "Transparency", minimum = 0, maximum = 100, small = 2, large = 10, suffix = "%" },
  blur = { label = "Blur", minimum = 0, maximum = 30, small = 1, large = 5, suffix = "" },
}
local IMAGE_EXTENSIONS = {
  avif = true,
  bmp = true,
  gif = true,
  heic = true,
  jpeg = true,
  jpg = true,
  png = true,
  tiff = true,
  tif = true,
  webp = true,
}

local function clamp(value, low, high)
  return math.min(high, math.max(low, value))
end

local function valid(state)
  return state
    and state.buf
    and vim.api.nvim_buf_is_valid(state.buf)
    and state.win
    and vim.api.nvim_win_is_valid(state.win)
end

local function truncate_display(value, width)
  value = tostring(value or "")
  if vim.fn.strdisplaywidth(value) <= width then
    return value
  end
  local suffix = "..."
  local result = ""
  for character in value:gmatch("[\1-\127\194-\244][\128-\191]*") do
    if vim.fn.strdisplaywidth(result .. character .. suffix) > width then
      break
    end
    result = result .. character
  end
  return result .. suffix
end

local function define_highlights(settings, backend)
  local canvas = backend.computed_color(settings) or "#222436"
  vim.api.nvim_set_hl(0, "DotfilesBackgroundPanelTitle", { link = "TelescopeTitle" })
  vim.api.nvim_set_hl(0, "DotfilesBackgroundPanelLabel", { link = "TelescopePromptPrefix" })
  vim.api.nvim_set_hl(0, "DotfilesBackgroundPanelMuted", { link = "Comment" })
  vim.api.nvim_set_hl(0, "DotfilesBackgroundPanelActive", { link = "Visual" })
  vim.api.nvim_set_hl(0, "DotfilesBackgroundPanelSelected", { link = "Search" })
  vim.api.nvim_set_hl(0, "DotfilesBackgroundPanelTrack", { link = "NonText" })
  vim.api.nvim_set_hl(0, "DotfilesBackgroundPanelFill", { link = "Function" })
  vim.api.nvim_set_hl(0, "DotfilesBackgroundPanelSwatch", { bg = canvas })
end

local function add_highlight(bufnr, namespace, group, line, first, last)
  vim.api.nvim_buf_set_extmark(bufnr, namespace, line - 1, first, {
    end_col = last,
    hl_group = group,
    priority = 120,
  })
end

local function slider_line(key, value, width)
  local spec = NUMERIC[key]
  local track_width = math.max(12, width - 32)
  local ratio = (value - spec.minimum) / (spec.maximum - spec.minimum)
  local thumb = clamp(math.floor(ratio * (track_width - 1) + 0.5) + 1, 1, track_width)
  local track = string.rep("=", thumb - 1) .. "o" .. string.rep("-", track_width - thumb)
  local value_text = (value > 0 and "+" or "") .. value .. spec.suffix
  local prefix = ("%-14s ["):format(spec.label)
  local line = prefix .. track .. "] " .. value_text
  return line,
    {
      start_col = #prefix,
      end_col = #prefix + track_width,
      fill_end = #prefix + thumb,
      minimum = spec.minimum,
      maximum = spec.maximum,
    }
end

local function segmented_line(label, order, labels, selected)
  local line = ("%-14s "):format(label)
  local boxes = {}
  local selected_range
  for _, value in ipairs(order) do
    local text = "[ " .. labels[value] .. " ]"
    local first = #line
    line = line .. text .. " "
    local box = { value = value, start_col = first, end_col = first + #text }
    boxes[#boxes + 1] = box
    if value == selected then
      selected_range = box
    end
  end
  return line, boxes, selected_range
end

local function render(state)
  if not valid(state) then
    return
  end
  define_highlights(state.settings, state.backend)
  local width = vim.api.nvim_win_get_width(state.win)
  local lines = {}
  local metadata = {}
  state.hitboxes = {}

  lines[#lines + 1] = ""
  metadata[#lines] = { muted = true }

  local mode_line, mode_boxes, selected_mode = segmented_line("Mode", MODE_ORDER, MODE_LABELS, state.settings.mode)
  lines[#lines + 1] = mode_line
  metadata[#lines] = { label = true, selected = selected_mode }
  state.hitboxes[#lines] = { kind = "segments", boxes = mode_boxes }

  local image = state.settings.image_path ~= "" and state.settings.image_path or "None"
  lines[#lines + 1] = ("%-14s %s"):format("Image", truncate_display(image, math.max(8, width - 17)))
  metadata[#lines] = { label = true }

  local layout_line, layout_boxes, selected_layout =
    segmented_line("Image layout", IMAGE_MODE_ORDER, IMAGE_MODE_LABELS, state.settings.image_mode)
  lines[#lines + 1] = layout_line
  metadata[#lines] = { label = true, selected = selected_layout }
  state.hitboxes[#lines] = { kind = "segments", boxes = layout_boxes }

  for _, key in ipairs({ "hue", "saturation", "lightness", "image_blend", "transparency", "blur" }) do
    local line, hitbox = slider_line(key, state.settings[key], width)
    lines[#lines + 1] = line
    metadata[#lines] = { label = true, slider = hitbox }
    state.hitboxes[#lines] = vim.tbl_extend("force", { kind = "slider", key = key }, hitbox)
  end

  local color = state.backend.computed_color(state.settings)
  local swatch = color and "        " or "transparent"
  lines[#lines + 1] = ("%-14s %s  %s"):format("Canvas", swatch, color or "")
  metadata[#lines] = { label = true, swatch = color and { 15, 23 } or nil }

  local renderer = state.backend.renderer_status()
  local chooser = vim.fn.executable("yazi") == 1 and "Yazi" or "path input"
  local preview = vim.fn.executable("chafa") == 1 and "Chafa" or "no image preview"
  local renderer_text = renderer.label .. (renderer.detail and (" · " .. renderer.detail) or "")
  renderer_text = renderer_text .. " | " .. chooser .. " + " .. preview
  lines[#lines + 1] = ("%-14s %s"):format("Renderer", truncate_display(renderer_text, math.max(8, width - 15)))
  metadata[#lines] = { label = true, muted = true }

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(state.buf, state.namespace, 0, -1)
  for line_number, item in ipairs(metadata) do
    if item.label then
      add_highlight(state.buf, state.namespace, "DotfilesBackgroundPanelLabel", line_number, 0, 14)
    end
    if item.muted then
      add_highlight(state.buf, state.namespace, "DotfilesBackgroundPanelMuted", line_number, 0, #lines[line_number])
    end
    if item.selected then
      add_highlight(
        state.buf,
        state.namespace,
        "DotfilesBackgroundPanelSelected",
        line_number,
        item.selected.start_col,
        item.selected.end_col
      )
    end
    if item.slider then
      add_highlight(
        state.buf,
        state.namespace,
        "DotfilesBackgroundPanelTrack",
        line_number,
        item.slider.start_col,
        item.slider.end_col
      )
      add_highlight(
        state.buf,
        state.namespace,
        "DotfilesBackgroundPanelFill",
        line_number,
        item.slider.start_col,
        item.slider.fill_end
      )
    end
    if item.swatch then
      add_highlight(
        state.buf,
        state.namespace,
        "DotfilesBackgroundPanelSwatch",
        line_number,
        item.swatch[1],
        item.swatch[2]
      )
    end
  end

  local active_line = state.selected + 1
  vim.api.nvim_buf_set_extmark(state.buf, state.namespace, active_line - 1, 0, {
    end_row = active_line,
    hl_group = "DotfilesBackgroundPanelActive",
    hl_eol = true,
    priority = 80,
  })
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_win_set_cursor(state.win, { active_line, 0 })
end

local function preview(state)
  state.backend.preview(state.settings, state.transaction)
  render(state)
end

local function cycle(order, current, delta)
  local index = 1
  for position, value in ipairs(order) do
    if value == current then
      index = position
      break
    end
  end
  return order[((index - 1 + delta) % #order) + 1]
end

local function selected_key(state)
  return ROWS[state.selected]
end

local function adjust(state, direction, large)
  local key = selected_key(state)
  if key == "mode" then
    state.settings.mode = cycle(MODE_ORDER, state.settings.mode, direction)
  elseif key == "image_mode" then
    state.settings.image_mode = cycle(IMAGE_MODE_ORDER, state.settings.image_mode, direction)
  elseif NUMERIC[key] then
    local spec = NUMERIC[key]
    local step = large and spec.large or spec.small
    state.settings[key] = clamp(state.settings[key] + direction * step, spec.minimum, spec.maximum)
    if key == "hue" or key == "saturation" or key == "lightness" then
      state.settings.mode = "tint"
    elseif key == "image_blend" and state.settings.image_path ~= "" then
      state.settings.mode = "image"
    elseif (key == "transparency" or key == "blur") and state.settings.mode ~= "image" then
      state.settings.mode = "transparent"
    end
  end
  preview(state)
end

local function is_image(path)
  if type(path) ~= "string" or path == "" or vim.fn.filereadable(path) ~= 1 then
    return false
  end
  local extension = path:match("%.([^./]+)$")
  return extension and IMAGE_EXTENSIONS[extension:lower()] == true
end

local function accept_image(state, path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  if not is_image(path) then
    vim.notify("Please choose a readable image file", vim.log.levels.WARN)
    return
  end
  state.settings.image_path = path
  state.settings.mode = "image"
  preview(state)
end

local function fallback_image_input(state)
  vim.ui.input({ prompt = "Background image: ", default = state.settings.image_path }, function(path)
    if path and valid(state) then
      accept_image(state, vim.fn.expand(path))
    end
  end)
end

local function open_yazi(state)
  if vim.fn.executable("yazi") ~= 1 then
    fallback_image_input(state)
    return
  end
  if state.chooser and state.chooser.win and vim.api.nvim_win_is_valid(state.chooser.win) then
    vim.api.nvim_set_current_win(state.chooser.win)
    return
  end

  local chooser_file = vim.fn.tempname()
  local start_dir = state.settings.image_path ~= "" and vim.fs.dirname(state.settings.image_path)
    or (vim.fn.isdirectory(vim.fn.expand("~/Pictures")) == 1 and vim.fn.expand("~/Pictures") or vim.fn.getcwd())
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  local columns = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight
  local width = math.max(30, columns - 4)
  local height = math.max(10, lines - 4)
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " Choose background image ",
    title_pos = "center",
    width = width,
    height = height,
    row = math.max(0, math.floor((lines - height) / 2)),
    col = math.max(0, math.floor((columns - width) / 2)),
    zindex = 90,
  })
  state.chooser = { buf = bufnr, win = winid, file = chooser_file }
  vim.wo[winid].winhighlight =
    "Normal:TelescopeNormal,NormalFloat:TelescopeNormal,FloatBorder:TelescopeBorder,FloatTitle:TelescopeTitle"

  vim.fn.termopen({ "yazi", start_dir, "--chooser-file=" .. chooser_file }, {
    on_exit = function()
      vim.schedule(function()
        local choices = vim.fn.filereadable(chooser_file) == 1 and vim.fn.readfile(chooser_file) or {}
        pcall(vim.fn.delete, chooser_file)
        if vim.api.nvim_win_is_valid(winid) then
          pcall(vim.api.nvim_win_close, winid, true)
        end
        if vim.api.nvim_buf_is_valid(bufnr) then
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
        state.chooser = nil
        if valid(state) then
          vim.api.nvim_set_current_win(state.win)
          if choices[1] then
            accept_image(state, choices[1])
          else
            render(state)
          end
        end
      end)
    end,
  })
  vim.cmd("startinsert")
end

local function close_panel(state, outcome)
  if not state or state.closed then
    return
  end
  state.closed = true
  state.outcome = outcome
  local settings = vim.deepcopy(state.settings)
  if outcome == "commit" then
    if state.transaction_pending then
      state.backend.save(settings)
    else
      state.backend.commit(settings, state.transaction)
    end
  else
    state.backend.restore(state.original, state.transaction)
  end
  if state.chooser and state.chooser.win and vim.api.nvim_win_is_valid(state.chooser.win) then
    pcall(vim.api.nvim_win_close, state.chooser.win, true)
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  if active == state then
    active = nil
  end
end

local function reset_current(state)
  local key = selected_key(state)
  local defaults = state.backend.defaults()
  if key == "image_path" then
    state.settings.image_path = ""
    if state.settings.mode == "image" then
      state.settings.mode = "theme"
    end
  else
    state.settings[key] = defaults[key]
  end
  preview(state)
end

local function exact_input(state)
  local key = selected_key(state)
  local spec = NUMERIC[key]
  if not spec then
    return
  end
  vim.ui.input({ prompt = spec.label .. ": ", default = tostring(state.settings[key]) }, function(value)
    if not value or not valid(state) then
      return
    end
    local number = tonumber(value)
    if not number then
      vim.notify("Expected a number", vim.log.levels.WARN)
      return
    end
    state.settings[key] = clamp(math.floor(number + 0.5), spec.minimum, spec.maximum)
    preview(state)
  end)
end

local function mouse_select(state)
  local mouse = vim.fn.getmousepos()
  if mouse.winid ~= state.win then
    return
  end
  local row = mouse.line - 1
  if row < 1 or row > #ROWS then
    return
  end
  state.selected = row
  local hitbox = state.hitboxes[mouse.line]
  local column = math.max(0, mouse.column - 1)
  if hitbox and hitbox.kind == "slider" and column >= hitbox.start_col and column <= hitbox.end_col then
    local ratio = (column - hitbox.start_col) / math.max(1, hitbox.end_col - hitbox.start_col)
    state.settings[hitbox.key] = math.floor(hitbox.minimum + ratio * (hitbox.maximum - hitbox.minimum) + 0.5)
    preview(state)
    return
  end
  if hitbox and hitbox.kind == "segments" then
    for _, box in ipairs(hitbox.boxes) do
      if column >= box.start_col and column < box.end_col then
        local key = selected_key(state)
        state.settings[key] = box.value
        preview(state)
        return
      end
    end
  end
  render(state)
end

local function set_keymaps(state)
  local opts = { buffer = state.buf, nowait = true, silent = true }
  local function map(keys, callback, description)
    keys = type(keys) == "table" and keys or { keys }
    for _, key in ipairs(keys) do
      vim.keymap.set("n", key, callback, vim.tbl_extend("force", opts, { desc = description }))
    end
  end
  map({ "j", "<Down>" }, function()
    state.selected = (state.selected % #ROWS) + 1
    render(state)
  end, "Next background setting")
  map({ "k", "<Up>" }, function()
    state.selected = ((state.selected - 2) % #ROWS) + 1
    render(state)
  end, "Previous background setting")
  map({ "h", "<Left>" }, function()
    adjust(state, -1, false)
  end, "Decrease background setting")
  map({ "l", "<Right>" }, function()
    adjust(state, 1, false)
  end, "Increase background setting")
  map("H", function()
    adjust(state, -1, true)
  end, "Decrease background setting quickly")
  map("L", function()
    adjust(state, 1, true)
  end, "Increase background setting quickly")
  map("o", function()
    open_yazi(state)
  end, "Choose background image")
  map("c", function()
    state.settings.image_path = ""
    if state.settings.mode == "image" then
      state.settings.mode = "theme"
    end
    preview(state)
  end, "Clear background image")
  map("i", function()
    exact_input(state)
  end, "Enter exact background value")
  map("r", function()
    reset_current(state)
  end, "Reset current background setting")
  map("R", function()
    state.settings = state.backend.defaults()
    preview(state)
  end, "Reset all background settings")
  map("<CR>", function()
    if selected_key(state) == "image_path" then
      open_yazi(state)
    else
      close_panel(state, "commit")
    end
  end, "Choose image or save background")
  map("s", function()
    close_panel(state, "commit")
  end, "Save background")
  map({ "q", "<Esc>" }, function()
    close_panel(state, "cancel")
  end, "Cancel background changes")
  map("<LeftMouse>", function()
    mouse_select(state)
  end, "Select background control")
  map("<ScrollWheelUp>", function()
    adjust(state, 1, false)
  end, "Increase background setting")
  map("<ScrollWheelDown>", function()
    adjust(state, -1, false)
  end, "Decrease background setting")
end

local function dimensions()
  local columns = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight
  local width = math.min(76, math.max(32, columns - 4))
  local height = math.min(13, math.max(10, lines - 4))
  return {
    width = width,
    height = height,
    row = math.max(0, math.floor((lines - height) / 2)),
    col = math.max(0, math.floor((columns - width) / 2)),
  }
end

function M.open(backend)
  if valid(active) then
    vim.api.nvim_set_current_win(active.win)
    return
  end
  local size = dimensions()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "dotfiles-background"
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " Background ",
    title_pos = "center",
    width = size.width,
    height = size.height,
    row = size.row,
    col = size.col,
    zindex = 70,
  })
  vim.wo[winid].cursorline = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].wrap = false
  vim.wo[winid].winhighlight =
    "Normal:TelescopeNormal,NormalFloat:TelescopeNormal,FloatBorder:TelescopeBorder,FloatTitle:TelescopeTitle"

  local state = {
    backend = backend,
    buf = bufnr,
    win = winid,
    namespace = vim.api.nvim_create_namespace("DotfilesBackgroundPanel" .. bufnr),
    selected = 1,
    original = backend.current(),
    settings = backend.current(),
    transaction_pending = true,
  }
  active = state
  render(state)
  set_keymaps(state)

  backend.begin_terminal_transaction(function(ok, transaction)
    state.transaction_pending = false
    state.transaction = transaction
    if state.closed then
      if ok and transaction then
        if state.outcome == "commit" then
          backend.commit(state.settings, transaction)
        else
          backend.restore(state.original, transaction)
        end
      end
      return
    end
    if ok then
      preview(state)
    else
      render(state)
    end
  end)

  local group = vim.api.nvim_create_augroup("DotfilesBackgroundPanel" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DotfilesBackgroundRenderer",
    callback = function()
      render(state)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if not valid(state) then
        return
      end
      local resized = dimensions()
      vim.api.nvim_win_set_config(state.win, {
        relative = "editor",
        width = resized.width,
        height = resized.height,
        row = resized.row,
        col = resized.col,
      })
      render(state)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function()
      if not state.closed then
        state.backend.restore(state.original, state.transaction)
      end
      if active == state then
        active = nil
      end
    end,
  })
end

function M.is_open()
  return valid(active)
end

function M._active_state()
  return active
end

return M
