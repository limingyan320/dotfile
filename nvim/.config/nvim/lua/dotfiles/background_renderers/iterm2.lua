local M = { id = "iterm2" }

local uv = vim.uv or vim.loop
local MAX_IMAGE_BYTES = 32 * 1024 * 1024
local IMAGE_EXTENSIONS = {
  avif = true,
  bmp = true,
  gif = true,
  heic = true,
  jpeg = true,
  jpg = true,
  png = true,
  tif = true,
  tiff = true,
  webp = true,
}

local socket_path
local tcp_host = "127.0.0.1"
local tcp_port = 47790
local explicit_address
local endpoint
local capabilities = {}
local online = false
local uploading = false
local on_status = function() end
local apply_serial = 0
local upload_cache = {}
local upload_waiters = {}
local clients = {}
local lease
local lease_waiters
local release_waiters = {}
local post_release_waiters = {}
local release_requested = false
local release_in_progress = false

local function notify_status()
  on_status()
end

local function close_handle(handle)
  clients[handle] = nil
  if handle and not handle:is_closing() then
    handle:close()
  end
end

local function parse_address(value)
  if not value or value == "" then
    return nil
  end
  if value:sub(1, 1) == "/" then
    return { kind = "unix", path = vim.fs.normalize(value) }
  end
  local host, port = value:match("^(.+):(%d+)$")
  if host and port then
    return { kind = "tcp", host = host, port = tonumber(port) }
  end
  return nil
end

local function candidate_endpoints()
  local result = {}
  local seen = {}
  local function add(value)
    if not value then
      return
    end
    local key = value.kind == "unix" and ("unix:" .. value.path) or ("tcp:" .. value.host .. ":" .. value.port)
    if not seen[key] then
      seen[key] = true
      result[#result + 1] = value
    end
  end
  add(parse_address(explicit_address))
  if socket_path and uv.fs_stat(socket_path) then
    add({ kind = "unix", path = socket_path })
  end
  add({ kind = "tcp", host = tcp_host, port = tcp_port })
  return result
end

local function request(target, payload, timeout_ms, callback)
  local client = target.kind == "unix" and uv.new_pipe(false) or uv.new_tcp()
  if not client then
    vim.schedule(function()
      callback(false, { error = "Cannot create renderer connection" })
    end)
    return
  end
  clients[client] = true
  local timer = uv.new_timer()
  clients[timer] = true
  local chunks = {}
  local finished = false
  local function finish(transport_ok, response)
    if finished then
      return
    end
    finished = true
    if timer then
      if not timer:is_closing() then
        timer:stop()
      end
      close_handle(timer)
    end
    close_handle(client)
    vim.schedule(function()
      callback(transport_ok, response)
    end)
  end
  timer:start(timeout_ms or 2000, 0, function()
    finish(false, { error = "Terminal renderer timed out" })
  end)
  local function connected(error_message)
    if error_message then
      finish(false, { error = tostring(error_message) })
      return
    end
    client:read_start(function(read_error, data)
      if read_error then
        finish(false, { error = tostring(read_error) })
      elseif data then
        chunks[#chunks + 1] = data
      else
        local raw = table.concat(chunks)
        local ok, response = pcall(vim.json.decode, raw)
        finish(ok, ok and response or { error = raw ~= "" and raw or "Empty renderer response" })
      end
    end)
    client:write(vim.json.encode(payload) .. "\n", function(write_error)
      if write_error then
        finish(false, { error = tostring(write_error) })
      end
    end)
  end
  if target.kind == "unix" then
    client:connect(target.path, connected)
  else
    client:connect(target.host, target.port, connected)
  end
end

local function send(payload, timeout_ms, callback)
  callback = callback or function() end
  if not endpoint then
    callback(false, { error = "iTerm2 renderer is not connected" })
    return
  end
  request(endpoint, payload, timeout_ms, function(transport_ok, response)
    if not transport_ok then
      online = false
      notify_status()
      callback(false, response)
      return
    end
    online = true
    callback(response and response.ok == true, response or { error = "Invalid renderer response" })
  end)
end

local function transaction_fields(transaction)
  if transaction and transaction.transaction_id then
    return { transaction_id = transaction.transaction_id }
  end
  return {}
end

local function image_identity(path)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil, "Selected image is not readable"
  end
  if stat.size > MAX_IMAGE_BYTES then
    return nil, "Selected image exceeds the 32 MiB bridge limit"
  end
  local extension = path:match("%.([^./]+)$")
  extension = extension and extension:lower() or ""
  if not IMAGE_EXTENSIONS[extension] then
    return nil, "Unsupported background image type"
  end
  local file, error_message = io.open(path, "rb")
  if not file then
    return nil, error_message
  end
  local data = file:read("*a")
  file:close()
  if not data then
    return nil, "Cannot read selected image"
  end
  local digest = vim.fn.sha256(data)
  local modified = stat.mtime and (stat.mtime.sec .. ":" .. stat.mtime.nsec) or "0"
  return {
    cache_key = table.concat({ path, stat.size, modified, digest }, ":"),
    data = data,
    digest = digest,
    extension = extension,
  }
end

local function finish_upload(key, ok, response)
  local waiters = upload_waiters[key] or {}
  upload_waiters[key] = nil
  uploading = next(upload_waiters) ~= nil
  notify_status()
  for _, callback in ipairs(waiters) do
    callback(ok, response)
  end
end

local function remote_image_ref(path, transaction, callback)
  local identity, error_message = image_identity(path)
  if not identity then
    callback(false, { error = error_message })
    return
  end
  if upload_cache[identity.cache_key] then
    callback(true, { image_ref = upload_cache[identity.cache_key] })
    return
  end
  if upload_waiters[identity.cache_key] then
    upload_waiters[identity.cache_key][#upload_waiters[identity.cache_key] + 1] = callback
    return
  end
  upload_waiters[identity.cache_key] = { callback }
  uploading = true
  notify_status()

  local authorization = transaction_fields(transaction)
  send(
    vim.tbl_extend("force", authorization, {
      action = "image_status",
      sha256 = identity.digest,
      extension = identity.extension,
    }),
    3000,
    function(status_ok, status_response)
      if status_ok and status_response.present and status_response.image_ref then
        upload_cache[identity.cache_key] = status_response.image_ref
        finish_upload(identity.cache_key, true, status_response)
        return
      end
      send(
        vim.tbl_extend("force", authorization, {
          action = "upload_image",
          sha256 = identity.digest,
          extension = identity.extension,
          data = vim.base64.encode(identity.data),
        }),
        20000,
        function(upload_ok, upload_response)
          if upload_ok and upload_response.image_ref then
            upload_cache[identity.cache_key] = upload_response.image_ref
          end
          finish_upload(identity.cache_key, upload_ok, upload_response)
        end
      )
    end
  )
end

local function resolve_image(settings, transaction, callback)
  if settings.mode ~= "image" or settings.image_path == "" then
    callback(true, {})
    return
  end
  if endpoint and endpoint.kind == "unix" then
    callback(true, { image_path = settings.image_path })
    return
  end
  remote_image_ref(settings.image_path, transaction, callback)
end

local function apply_settings(settings, transaction, callback)
  callback = callback or function() end
  apply_serial = apply_serial + 1
  local serial = apply_serial
  if settings.renderer == "nvim" then
    local authorization = transaction or lease
    if not authorization or not authorization.transaction_id then
      callback(true, { bypassed = true })
      return
    end
    send(vim.tbl_extend("force", transaction_fields(authorization), { action = "restore" }), 5000, callback)
    return
  end
  if settings.mode == "theme" or settings.mode == "tint" then
    send(vim.tbl_extend("force", transaction_fields(transaction), { action = "restore" }), 5000, callback)
    return
  end
  resolve_image(settings, transaction, function(image_ok, image_response)
    if serial ~= apply_serial then
      callback(false, { error = "Superseded background preview" })
      return
    end
    if not image_ok then
      callback(false, image_response)
      return
    end
    local payload = vim.tbl_extend("force", transaction_fields(transaction), {
      action = "apply",
      settings = {
        image_enabled = settings.mode == "image" and settings.image_path ~= "",
        image_path = image_response.image_path,
        image_ref = image_response.image_ref,
        image_mode = settings.image_mode,
        image_blend = settings.image_blend / 100,
        transparency = (settings.mode == "image" or settings.mode == "transparent") and settings.transparency / 100
          or 0,
        blur_radius = (settings.mode == "image" or settings.mode == "transparent") and settings.blur or 0,
      },
    })
    send(payload, 5000, callback)
  end)
end

local ensure_lease

local function finish_release(ok, response)
  release_in_progress = false
  release_requested = false
  lease = nil
  local callbacks = release_waiters
  release_waiters = {}
  for _, callback in ipairs(callbacks) do
    callback(ok, response)
  end

  local waiting = post_release_waiters
  post_release_waiters = {}
  for _, callback in ipairs(waiting) do
    ensure_lease(callback)
  end
end

local function release_lease()
  if release_in_progress then
    return
  end
  if not lease then
    finish_release(true, { released = false })
    return
  end
  release_in_progress = true
  local transaction = lease
  lease = nil
  send(vim.tbl_extend("force", transaction_fields(transaction), { action = "cancel" }), 3000, finish_release)
end

ensure_lease = function(callback)
  if lease and not release_in_progress then
    vim.schedule(function()
      callback(true, lease, { reused = true })
    end)
    return
  end
  if release_in_progress then
    post_release_waiters[#post_release_waiters + 1] = callback
    return
  end
  if lease_waiters then
    lease_waiters[#lease_waiters + 1] = callback
    return
  end

  lease_waiters = { callback }
  send({ action = "begin" }, 3000, function(ok, response)
    local callbacks = lease_waiters or {}
    lease_waiters = nil
    if ok then
      lease = {
        renderer = M.id,
        transaction_id = response.transaction_id,
        session_id = response.session_id,
      }
    end
    if release_requested then
      for _, waiter in ipairs(callbacks) do
        waiter(false, nil, { error = "Background renderer was released" })
      end
      if lease then
        release_lease()
      else
        finish_release(ok, response)
      end
      return
    end
    for _, waiter in ipairs(callbacks) do
      waiter(ok, lease, response)
    end
  end)
end

local function apply_with_lease(settings, callback)
  callback = callback or function() end
  ensure_lease(function(ok, transaction, response)
    if not ok then
      callback(false, response)
      return
    end
    apply_settings(settings, transaction, callback)
  end)
end

function M.setup(opts)
  opts = opts or {}
  socket_path = opts.socket_path or vim.fs.joinpath(vim.fn.expand("~/Library/Caches/dotfiles"), "iterm-background.sock")
  tcp_host = opts.tcp_host or "127.0.0.1"
  tcp_port = tonumber(opts.tcp_port or vim.env.DOTFILES_NVIM_BACKGROUND_PORT) or 47790
  explicit_address = opts.address or vim.env.DOTFILES_NVIM_BACKGROUND_ADDRESS
  on_status = opts.on_status or on_status
end

function M.probe(callback)
  local candidates = candidate_endpoints()
  local function try(index, last_error)
    local target = candidates[index]
    if not target then
      endpoint = nil
      online = false
      callback(false, { error = last_error or "iTerm2 helper unavailable" })
      return
    end
    request(target, { action = "ping", protocol = 1 }, 800, function(transport_ok, response)
      if not transport_ok then
        try(index + 1, response and response.error)
        return
      end
      if not response or response.ok ~= true or response.renderer ~= "iterm2" then
        try(index + 1, response and response.error or "Unexpected renderer response")
        return
      end
      if response.active ~= true then
        endpoint = nil
        online = false
        callback(false, { error = "iTerm2 is not the active terminal" })
        return
      end
      endpoint = target
      capabilities = response.capabilities or {}
      online = true
      notify_status()
      callback(true, response)
    end)
  end
  try(1)
end

function M.begin(callback)
  ensure_lease(callback)
end

function M.preview(settings, transaction)
  apply_settings(settings, transaction)
end

function M.apply(settings, callback)
  apply_with_lease(settings, callback)
end

function M.bypass(settings, callback)
  apply_settings(settings, nil, callback)
end

function M.commit(settings, transaction, callback)
  apply_settings(settings, transaction or lease, callback)
end

function M.restore(settings, transaction)
  apply_settings(settings, transaction or lease)
end

function M.release(callback)
  callback = callback or function() end
  release_waiters[#release_waiters + 1] = callback
  apply_serial = apply_serial + 1
  if release_in_progress then
    return
  end
  if lease_waiters then
    release_requested = true
    return
  end
  release_lease()
end

function M.status()
  local connection = endpoint and endpoint.kind == "tcp" and "SSH bridge" or "local bridge"
  local detail = uploading and (connection .. " · uploading image") or (connection .. " · image / opacity / blur")
  if not online then
    detail = connection .. " · disconnected"
  end
  return {
    label = "iTerm2",
    detail = detail,
    capabilities = vim.deepcopy(capabilities),
  }
end

function M.close()
  for handle in pairs(clients) do
    close_handle(handle)
  end
end

function M._endpoint_for_test()
  return endpoint
end

return M
