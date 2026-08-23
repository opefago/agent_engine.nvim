-- File: lua/agent_engine/watcher.lua
-- OS-native file watchers for agent / terminal disk mutations.

local M = {}

---@type table<integer, uv.uv_fs_event_t>
M.active_watchers = {}

--- Debounce timers keyed by buffer so bursty FS events collapse.
---@type table<integer, uv.uv_timer_t>
local debounce_timers = {}

local DEBOUNCE_MS = 200

---@param handle uv.uv_fs_event_t|uv.uv_timer_t|nil
local function safe_close(handle)
  if not handle then
    return
  end
  local ok_closing, closing = pcall(function()
    return handle:is_closing()
  end)
  if ok_closing and closing then
    return
  end
  pcall(function()
    if handle.stop then
      handle:stop()
    end
  end)
  pcall(function()
    handle:close()
  end)
end

--- Starts monitoring a file on disk using native FS events.
---@param bufnr number
---@param filepath string
---@param callback fun(bufnr: number, filepath: string)
---@return boolean
function M.watch_file(bufnr, filepath, callback)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if type(filepath) ~= "string" or filepath == "" then
    return false
  end
  if type(callback) ~= "function" then
    return false
  end

  M.unwatch_file(bufnr)

  local handle, err = vim.uv.new_fs_event()
  if not handle then
    vim.notify("Cursor Watcher Error: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  local normalized_path = vim.fs.normalize(filepath)
  if not normalized_path or normalized_path == "" then
    safe_close(handle)
    return false
  end

  local flags = { watch_entry = false, stat = false, recursive = false }

  local success, start_err = handle:start(normalized_path, flags, function(watch_err, _filename, events)
    if watch_err then
      vim.schedule(function()
        vim.notify("File watch runtime error: " .. tostring(watch_err), vim.log.levels.ERROR)
      end)
      return
    end

    if not events or not (events.change or events.rename) then
      return
    end

    -- Debounce: FS events often fire multiple times per write.
    local existing = debounce_timers[bufnr]
    if existing then
      safe_close(existing)
      debounce_timers[bufnr] = nil
    end

    local timer = vim.uv.new_timer()
    if not timer then
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          callback(bufnr, normalized_path)
        end
      end)
      return
    end

    debounce_timers[bufnr] = timer
    timer:start(DEBOUNCE_MS, 0, function()
      safe_close(timer)
      debounce_timers[bufnr] = nil
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          callback(bufnr, normalized_path)
        end
      end)
    end)
  end)

  if not success then
    vim.notify("Failed to initiate file system watch: " .. tostring(start_err), vim.log.levels.ERROR)
    safe_close(handle)
    return false
  end

  M.active_watchers[bufnr] = handle
  return true
end

--- Closes and frees watcher resources for a buffer.
---@param bufnr number
function M.unwatch_file(bufnr)
  if type(bufnr) ~= "number" then
    return
  end

  local timer = debounce_timers[bufnr]
  if timer then
    safe_close(timer)
    debounce_timers[bufnr] = nil
  end

  local handle = M.active_watchers[bufnr]
  if handle then
    safe_close(handle)
    M.active_watchers[bufnr] = nil
  end
end

return M
