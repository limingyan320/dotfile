local M = {}

local UNMANAGED_SESSION_ID = "__unmanaged_nvim__"

local function empty_memory()
  return {
    nvim = 0,
    lsp = 0,
    codex = 0,
    other = 0,
    total = 0,
    process_count = 0,
  }
end

local function run_command(command, timeout)
  local ok, process = pcall(vim.system, command, { text = true })
  if not ok then
    return nil, tostring(process)
  end
  local result = process:wait(timeout)
  if not result then
    return nil, "command did not return a result"
  end
  local output = (result.stdout or "") .. (result.stderr or "")
  if result.code ~= 0 and output == "" then
    return nil, ("command exited with code %s"):format(tostring(result.code))
  end
  return output
end

local function parse_process_snapshot(output)
  local processes = {}
  for line in tostring(output or ""):gmatch("[^\r\n]+") do
    local pid, ppid, rss_kib, command = line:match("^%s*(%d+)%s+(%d+)%s+(%d+)%s+(.*)$")
    pid = tonumber(pid)
    if pid then
      processes[pid] = {
        pid = pid,
        ppid = tonumber(ppid) or 0,
        rss_bytes = (tonumber(rss_kib) or 0) * 1024,
        command = command or "",
      }
    end
  end
  return processes
end

local function command_basename(command)
  local executable = tostring(command or ""):match("^%s*(%S+)") or ""
  return executable:match("([^/]+)$") or executable
end

local function is_nvim_process(process)
  return command_basename(process.command):lower() == "nvim"
end

local function is_codex_process(process)
  local command = process.command:lower()
  local executable = command_basename(command)
  return executable == "codex"
    or executable:match("^codex%-") ~= nil
    or command:find("/@openai/codex/", 1, true) ~= nil
    or command:find("/bin/codex ", 1, true) ~= nil
end

local LSP_PATTERNS = {
  "language%-server",
  "langserver",
  "ruff%s+server",
  "marksman%s+server",
  "taplo%s+lsp",
  "pylsp",
  "jedi/inference/compiled/subprocess",
  "rust%-analyzer",
  "typescript%-language%-server",
  "lua%-language%-server",
  "bash%-language%-server",
  "sourcekit%-lsp",
  "terraform%-ls%s+serve",
  "docker%-langserver",
  "lemminx",
}

local function is_lsp_process(process)
  local command = process.command:lower()
  local executable = command_basename(command)
  if executable == "gopls" or executable == "clangd" then
    return true
  end
  for _, pattern in ipairs(LSP_PATTERNS) do
    if command:find(pattern) then
      return true
    end
  end
  return false
end

local function propagate_owners(processes, owners)
  local changed = true
  while changed do
    changed = false
    for pid, process in pairs(processes) do
      if not owners[pid] and owners[process.ppid] then
        owners[pid] = owners[process.ppid]
        changed = true
      end
    end
  end
end

local function assign_process_owners(sessions, processes)
  local owners = {}
  local session_roots = {}
  for _, session in ipairs(sessions) do
    local pid = tonumber(session.pid)
    if pid and processes[pid] and session.session_id then
      owners[pid] = session.session_id
      session_roots[pid] = session.session_id
    end
  end
  propagate_owners(processes, owners)

  -- AppImage helpers and remote UI clients are siblings rather than children of
  -- the server. Their command still contains the exact server address.
  for pid, process in pairs(processes) do
    if not owners[pid] and is_nvim_process(process) then
      for _, session in ipairs(sessions) do
        if
          session.session_id
          and session.address
          and session.address ~= ""
          and process.command:find(session.address, 1, true)
        then
          owners[pid] = session.session_id
          break
        end
      end
    end
  end
  propagate_owners(processes, owners)

  local unmanaged_nvim_count = 0
  for pid, process in pairs(processes) do
    if not owners[pid] and is_nvim_process(process) then
      owners[pid] = UNMANAGED_SESSION_ID
      unmanaged_nvim_count = unmanaged_nvim_count + 1
    end
  end
  propagate_owners(processes, owners)
  return owners, session_roots, unmanaged_nvim_count
end

local function assign_process_categories(processes, owners, session_roots)
  local categories = {}
  for pid, process in pairs(processes) do
    if owners[pid] then
      if session_roots[pid] or is_nvim_process(process) then
        categories[pid] = "nvim"
      elseif is_codex_process(process) then
        categories[pid] = "codex"
      elseif is_lsp_process(process) then
        categories[pid] = "lsp"
      end
    end
  end

  local changed = true
  while changed do
    changed = false
    for pid, process in pairs(processes) do
      if not categories[pid] and owners[pid] and owners[pid] == owners[process.ppid] then
        local parent_category = categories[process.ppid]
        if parent_category == "codex" or parent_category == "lsp" then
          categories[pid] = parent_category
          changed = true
        end
      end
    end
  end

  for pid in pairs(owners) do
    categories[pid] = categories[pid] or "other"
  end
  return categories
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

local function parse_linux_smaps(content)
  local pss_kib
  local swap_pss_kib = 0
  for key, value in tostring(content or ""):gmatch("([%a_]+):%s+(%d+)%s+kB") do
    if key == "Pss" then
      pss_kib = tonumber(value)
    elseif key == "SwapPss" then
      swap_pss_kib = tonumber(value) or 0
    end
  end
  return pss_kib and (pss_kib + swap_pss_kib) * 1024 or nil
end

local function parse_macos_footprint(output)
  local values = {}
  local current_pid
  for line in tostring(output or ""):gmatch("[^\r\n]+") do
    local pid = line:match("%[(%d+)%]:")
    if pid then
      current_pid = tonumber(pid)
      local footprint = line:match("Footprint:%s+(%d+)%s+B")
      if current_pid and footprint then
        values[current_pid] = tonumber(footprint)
      end
    elseif current_pid then
      local footprint = line:match("^%s*phys_footprint:%s+(%d+)%s+B")
      if footprint then
        values[current_pid] = tonumber(footprint)
      end
    end
  end
  return values
end

local function relevant_pids(owners)
  local pids = {}
  for pid in pairs(owners) do
    pids[#pids + 1] = pid
  end
  table.sort(pids)
  return pids
end

local function collect_process_bytes(processes, owners, opts)
  local bytes = {}
  for pid in pairs(owners) do
    bytes[pid] = processes[pid] and processes[pid].rss_bytes or 0
  end
  if opts.bytes_by_pid then
    for pid, value in pairs(opts.bytes_by_pid) do
      if owners[tonumber(pid)] then
        bytes[tonumber(pid)] = tonumber(value) or bytes[tonumber(pid)]
      end
    end
    return bytes, opts.metric or "fixture"
  end

  local platform = opts.platform or (vim.uv.os_uname() or {}).sysname
  local metric = "RSS"
  if platform == "Darwin" then
    local command = { "footprint", "-f", "bytes", "--noCategories" }
    for _, pid in ipairs(relevant_pids(owners)) do
      command[#command + 1] = tostring(pid)
    end
    if #command > 4 then
      local output = run_command(command, opts.footprint_timeout or 1500)
      local footprints = output and parse_macos_footprint(output) or {}
      local measured = 0
      for pid, value in pairs(footprints) do
        if owners[pid] then
          bytes[pid] = value
          measured = measured + 1
        end
      end
      if measured > 0 then
        metric = "footprint"
      end
    end
  elseif platform == "Linux" then
    local measured = 0
    for pid in pairs(owners) do
      local value = parse_linux_smaps(read_file(("/proc/%d/smaps_rollup"):format(pid)))
      if value then
        bytes[pid] = value
        measured = measured + 1
      end
    end
    if measured > 0 then
      metric = "PSS+swap"
    end
  end
  return bytes, metric
end

local function add_process(memory, category, bytes)
  memory[category] = memory[category] + bytes
  memory.total = memory.total + bytes
  memory.process_count = memory.process_count + 1
end

local function aggregate(sessions, processes, owners, categories, bytes_by_pid, metric, unmanaged_nvim_count)
  local result = {
    metric = metric,
    sessions = {},
    summary = empty_memory(),
    unmanaged = empty_memory(),
  }
  result.summary.session_count = #sessions
  result.unmanaged.nvim_process_count = unmanaged_nvim_count or 0
  for _, session in ipairs(sessions) do
    if session.session_id then
      result.sessions[session.session_id] = empty_memory()
    end
  end

  for pid, owner in pairs(owners) do
    local memory = owner == UNMANAGED_SESSION_ID and result.unmanaged or result.sessions[owner]
    if memory then
      local category = categories[pid] or "other"
      local bytes = tonumber(bytes_by_pid[pid]) or 0
      add_process(memory, category, bytes)
      add_process(result.summary, category, bytes)
    end
  end
  return result
end

function M.collect(sessions, opts)
  opts = opts or {}
  sessions = sessions or {}
  local snapshot = opts.ps_output
  local snapshot_error
  if snapshot == nil then
    snapshot, snapshot_error = run_command({ "ps", "-axo", "pid=,ppid=,rss=,command=" }, opts.ps_timeout or 500)
  end
  if not snapshot then
    return {
      metric = "unavailable",
      sessions = {},
      summary = empty_memory(),
      unmanaged = empty_memory(),
      error = snapshot_error or "process snapshot unavailable",
    }
  end

  local processes = parse_process_snapshot(snapshot)
  local owners, roots, unmanaged_nvim_count = assign_process_owners(sessions, processes)
  local categories = assign_process_categories(processes, owners, roots)
  local bytes_by_pid, metric = collect_process_bytes(processes, owners, opts)
  return aggregate(sessions, processes, owners, categories, bytes_by_pid, metric, unmanaged_nvim_count)
end

M._parse_macos_footprint = parse_macos_footprint
M._parse_linux_smaps = parse_linux_smaps

return M
