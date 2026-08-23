-- File: lua/agent_engine/storage.lua
-- Transactional persistence for pending agent diffs and session metadata.

local M = {}

local cache_root = vim.fn.stdpath("data") .. "/agent_engine_state/"
local sessions_path = cache_root .. "sessions.json"
local history_path = cache_root .. "history.json"

do
  local legacy_root = vim.fn.stdpath("data") .. "/cursor_engine_state/"
  if vim.fn.isdirectory(cache_root) == 0 and vim.fn.isdirectory(legacy_root) == 1 then
    vim.fn.rename(legacy_root, cache_root)
  end
  local ok = vim.fn.mkdir(cache_root, "p")
  if ok ~= 1 and vim.fn.isdirectory(cache_root) == 0 then
    vim.notify("agent_engine: failed to create state dir: " .. cache_root, vim.log.levels.ERROR)
  end
end

--- Creates an isolated, collision-free filename map based on the real system path.
---@param filepath string|nil
---@return string|nil
local function get_state_id(filepath)
  if type(filepath) ~= "string" or filepath == "" then
    return nil
  end
  local normalized = vim.fs.normalize(filepath)
  if not normalized or normalized == "" then
    return nil
  end
  return vim.fn.sha256(normalized):sub(1, 16)
end

---@param path string
---@param contents string
---@return boolean
local function atomic_write(path, contents)
  if type(path) ~= "string" or path == "" then
    return false
  end
  local tmp = path .. ".tmp." .. tostring(vim.uv.hrtime())
  local f, err = io.open(tmp, "w")
  if not f then
    vim.notify("agent_engine: write failed (" .. tostring(err) .. "): " .. path, vim.log.levels.ERROR)
    return false
  end
  local ok_write, write_err = pcall(function()
    f:write(contents)
    f:close()
  end)
  if not ok_write then
    pcall(os.remove, tmp)
    vim.notify("agent_engine: write error: " .. tostring(write_err), vim.log.levels.ERROR)
    return false
  end
  local ok_rename, rename_err = os.rename(tmp, path)
  if not ok_rename then
    pcall(os.remove, tmp)
    vim.notify("agent_engine: rename failed: " .. tostring(rename_err), vim.log.levels.ERROR)
    return false
  end
  return true
end

---@param path string
---@return string|nil
local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

--- Persist unaccepted agent changes using transactional temp file swaps.
---@param filepath string
---@param source_lines string[]
---@param shadow_lines string[]
---@return boolean
function M.save_transaction(filepath, source_lines, shadow_lines)
  if type(source_lines) ~= "table" or type(shadow_lines) ~= "table" then
    return false
  end

  local id = get_state_id(filepath)
  if not id then
    return false
  end

  local manifest_path = cache_root .. id .. ".json"
  local shadow_path = cache_root .. id .. ".shadow"
  local base_path = cache_root .. id .. ".base"

  local manifest_data = {
    original_path = filepath,
    timestamp = vim.uv.now(),
    base_hash = vim.fn.sha256(table.concat(source_lines, "\n")),
  }

  local shadow_body = table.concat(shadow_lines, "\n")
  if #shadow_lines > 0 then
    shadow_body = shadow_body .. "\n"
  end

  local base_body = table.concat(source_lines, "\n")
  if #source_lines > 0 then
    base_body = base_body .. "\n"
  end

  if not atomic_write(shadow_path, shadow_body) then
    return false
  end
  if not atomic_write(base_path, base_body) then
    return false
  end

  local encoded = vim.json.encode(manifest_data)
  if not encoded then
    return false
  end
  if not atomic_write(manifest_path, encoded) then
    return false
  end

  return true
end

--- Load persistent pending-change state for a filepath.
---@param filepath string
---@return { shadow_path: string, base_path?: string, drifted: boolean, original_path?: string }|nil
function M.load_transaction(filepath)
  local id = get_state_id(filepath)
  if not id then
    return nil
  end

  local manifest_path = cache_root .. id .. ".json"
  local shadow_path = cache_root .. id .. ".shadow"
  local base_path = cache_root .. id .. ".base"

  if vim.fn.filereadable(manifest_path) == 0 or vim.fn.filereadable(shadow_path) == 0 then
    return nil
  end

  local raw = read_file(manifest_path)
  if not raw or raw == "" then
    return nil
  end

  local ok, manifest = pcall(vim.json.decode, raw)
  if not ok or type(manifest) ~= "table" or type(manifest.base_hash) ~= "string" then
    return nil
  end

  local has_base = vim.fn.filereadable(base_path) == 1

  if vim.fn.filereadable(filepath) == 0 then
    return {
      shadow_path = shadow_path,
      base_path = has_base and base_path or nil,
      drifted = true,
      original_path = manifest.original_path,
    }
  end

  local current_lines = vim.fn.readfile(filepath)
  if type(current_lines) ~= "table" then
    return {
      shadow_path = shadow_path,
      base_path = has_base and base_path or nil,
      drifted = true,
      original_path = manifest.original_path,
    }
  end

  local current_hash = vim.fn.sha256(table.concat(current_lines, "\n"))
  local drifted = current_hash ~= manifest.base_hash

  return {
    shadow_path = shadow_path,
    base_path = has_base and base_path or nil,
    drifted = drifted,
    original_path = manifest.original_path,
  }
end

---@param filepath string
function M.clear_transaction(filepath)
  local id = get_state_id(filepath)
  if not id then
    return
  end
  pcall(os.remove, cache_root .. id .. ".json")
  pcall(os.remove, cache_root .. id .. ".shadow")
  pcall(os.remove, cache_root .. id .. ".base")
end

--- List filepaths that still have a pending agent transaction on disk.
--- Sorted path-order so navigation roughly follows a file-tree walk.
---@return string[]
function M.list_pending()
  local paths = {}
  local seen = {}
  local globbed = vim.fn.glob(cache_root .. "*.json", false, true)
  if type(globbed) ~= "table" then
    return paths
  end

  for _, manifest_path in ipairs(globbed) do
    if not manifest_path:match("%.tmp%.") then
      local raw = read_file(manifest_path)
      if raw and raw ~= "" then
        local ok, manifest = pcall(vim.json.decode, raw)
        if ok and type(manifest) == "table" and type(manifest.original_path) == "string" then
          local p = vim.fs.normalize(manifest.original_path)
          local shadow = manifest_path:gsub("%.json$", ".shadow")
          if p and p ~= "" and not seen[p] and vim.fn.filereadable(shadow) == 1 then
            seen[p] = true
            table.insert(paths, p)
          end
        end
      end
    end
  end

  table.sort(paths)
  return paths
end

--- Persist multi-agent session list (mode/model/chat ids).
---@param sessions table
---@return boolean
function M.save_sessions(sessions)
  if type(sessions) ~= "table" then
    return false
  end
  local encoded = vim.json.encode(sessions)
  if not encoded then
    return false
  end
  return atomic_write(sessions_path, encoded)
end

---@return table|nil
function M.load_sessions()
  if vim.fn.filereadable(sessions_path) == 0 then
    return nil
  end
  local raw = read_file(sessions_path)
  if not raw or raw == "" then
    return nil
  end
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then
    return nil
  end
  return data
end

---@return table[]
function M.load_history()
  if vim.fn.filereadable(history_path) == 0 then
    return {}
  end
  local raw = read_file(history_path)
  if not raw or raw == "" then
    return {}
  end
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then
    return {}
  end
  if type(data.entries) == "table" then
    return data.entries
  end
  return data
end

---@param entries table[]
---@return boolean
function M.save_history(entries)
  if type(entries) ~= "table" then
    return false
  end
  local encoded = vim.json.encode({ version = 1, entries = entries })
  if not encoded then
    return false
  end
  return atomic_write(history_path, encoded)
end

--- Archive a closed chat session into history (newest first).
---@param entry table
---@param max_entries integer|nil
---@return boolean
function M.append_history(entry, max_entries)
  if type(entry) ~= "table" or type(entry.id) ~= "string" then
    return false
  end
  local entries = M.load_history()
  local filtered = {}
  for _, e in ipairs(entries) do
    if type(e) == "table" and e.id ~= entry.id then
      table.insert(filtered, e)
    end
  end
  table.insert(filtered, 1, entry)
  if type(max_entries) == "number" and max_entries > 0 and #filtered > max_entries then
    filtered = vim.list_slice(filtered, 1, max_entries)
  end
  return M.save_history(filtered)
end

---@param history_id string
---@return boolean
function M.remove_history(history_id)
  if type(history_id) ~= "string" or history_id == "" then
    return false
  end
  local entries = M.load_history()
  local filtered = vim.tbl_filter(function(e)
    return type(e) == "table" and e.id ~= history_id
  end, entries)
  if #filtered == #entries then
    return false
  end
  return M.save_history(filtered)
end

---@return string
function M.cache_root()
  return cache_root
end

return M
