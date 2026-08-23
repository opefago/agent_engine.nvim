-- File: lua/agent_engine/integration_log.lua
-- Debug logging for plugin integrations (Headroom, MCP, extensions).
-- View: :AgentIntegrationsLog · tail -f ~/.cache/nvim/agent_engine-integrations.log

local config = require("agent_engine.config")

local M = {}

---@type string|nil
local log_path = nil

---@return table
local function cfg()
  local c = config.get().integrations_log
  if type(c) == "table" then
    return c
  end
  return {}
end

---@return boolean
function M.enabled()
  local c = cfg()
  return c.enabled == true
end

local function log_file_path()
  if log_path then
    return log_path
  end
  local c = cfg()
  if type(c.file_path) == "string" and c.file_path ~= "" then
    log_path = c.file_path
    return log_path
  end
  log_path = vim.fs.joinpath(vim.fn.stdpath("cache"), "agent_engine-integrations.log")
  return log_path
end

---@param level string
---@param source string
---@param message string
local function emit(level, source, message)
  local c = cfg()
  local ts = os.date("%Y-%m-%d %H:%M:%S")
  local line = string.format("[%s] [%s] %s: %s", ts, level:upper(), source, message)

  if c.console ~= false then
    -- Visible in the terminal when Neovim was started from a shell.
    io.stderr:write(line .. "\n")
    io.stderr:flush()
  end

  if c.file ~= false then
    local path = log_file_path()
    local f = io.open(path, "a")
    if f then
      f:write(line .. "\n")
      f:close()
    end
  end

  if c.notify then
    local lvl = vim.log.levels.INFO
    if level == "warn" or level == "error" then
      lvl = vim.log.levels.WARN
    elseif level == "debug" then
      lvl = vim.log.levels.DEBUG
    end
    vim.notify(line, lvl, { title = "agent_engine" })
  end
end

---@param source string
---@param message string
function M.info(source, message)
  if not M.enabled() then
    return
  end
  emit("info", source, message)
end

---@param source string
---@param message string
function M.warn(source, message)
  if not M.enabled() then
    return
  end
  emit("warn", source, message)
end

---@param source string
---@param message string
function M.debug(source, message)
  if not M.enabled() then
    return
  end
  local c = cfg()
  if c.debug == false then
    return
  end
  emit("debug", source, message)
end

---@param source string
---@param data table|nil
function M.json(source, label, data)
  if not M.enabled() then
    return
  end
  local ok, encoded = pcall(vim.json.encode, data or {})
  M.debug(source, label .. ": " .. (ok and encoded or tostring(data)))
end

---@return string
function M.path()
  return log_file_path()
end

---@param max_lines integer|nil
---@return string[]
function M.tail(max_lines)
  max_lines = max_lines or 40
  local path = log_file_path()
  if vim.fn.filereadable(path) ~= 1 then
    return { "No log yet at " .. path }
  end
  local lines = vim.fn.readfile(path)
  if #lines <= max_lines then
    return lines
  end
  local out = {}
  for i = #lines - max_lines + 1, #lines do
    table.insert(out, lines[i])
  end
  return out
end

function M.show()
  local lines = M.tail(60)
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "agent_engine integrations log" })
end

return M
