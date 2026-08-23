-- File: lua/agent_engine/plugins.lua
-- Cursor agent --plugin-dir paths and agent_engine extension registry.

local config = require("agent_engine.config")

local M = {}

---@type string[]
local runtime_dirs = {}

---@class AgentEngineExtension
---@field id string
---@field name string|nil
---@field setup? fun(api: table)
---@field on_before_send? fun(ctx: { prompt: string, session: table, raw?: boolean }): string|nil
---@field on_after_reply? fun(ctx: { reply: string, session: table, code: integer|nil })
---@field on_stream_event? fun(event: table, acc: table)
---@field on_file_changed? fun(bufnr: integer, path: string)
---@field slash_commands? table<string, fun(arg: string): boolean>

---@type table<string, AgentEngineExtension>
local registry = {}

--- Public API passed to extension setup().
---@return table
local function make_api()
  return {
    register = M.register,
    notify = vim.notify,
    get_config = config.get,
    require_engine = function(name)
      return require("agent_engine." .. name)
    end,
  }
end

---@return string[]
function M.dirs()
  local cfg = config.get().plugins or {}
  local dirs = vim.deepcopy(cfg.dirs or {})
  local seen = {}
  for _, d in ipairs(dirs) do
    seen[d] = true
  end
  for _, d in ipairs(runtime_dirs) do
    if not seen[d] then
      table.insert(dirs, d)
      seen[d] = true
    end
  end
  local valid = {}
  for _, d in ipairs(dirs) do
    if type(d) == "string" and d ~= "" and vim.fn.isdirectory(d) == 1 then
      table.insert(valid, vim.fn.fnamemodify(d, ":p"))
    end
  end
  return valid
end

---@param path string
---@return boolean ok
---@return string|nil err
function M.add_dir(path)
  if type(path) ~= "string" or path == "" then
    return false, "path required"
  end
  path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.isdirectory(path) ~= 1 then
    return false, "not a directory: " .. path
  end
  for _, d in ipairs(M.dirs()) do
    if d == path then
      return true
    end
  end
  table.insert(runtime_dirs, path)
  return true
end

---@param path string
---@return boolean removed
function M.remove_dir(path)
  path = vim.fn.fnamemodify(path, ":p")
  for i, d in ipairs(runtime_dirs) do
    if d == path then
      table.remove(runtime_dirs, i)
      return true
    end
  end
  return false
end

---@param ext AgentEngineExtension
function M.register(ext)
  if type(ext) ~= "table" or type(ext.id) ~= "string" or ext.id == "" then
    error("agent_engine.plugins.register: extension requires a non-empty id")
  end
  registry[ext.id] = ext
  if type(ext.setup) == "function" then
    ext.setup(make_api())
  end
end

---@return AgentEngineExtension[]
function M.list_extensions()
  local out = {}
  for _, ext in pairs(registry) do
    table.insert(out, ext)
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

---@param modules string[]|nil
function M.load(modules)
  modules = modules or (config.get().extensions or {})
  if type(modules) ~= "table" then
    return
  end
  for _, mod in ipairs(modules) do
    if type(mod) == "string" and mod ~= "" then
      local ok, loaded = pcall(require, mod)
      if not ok then
        vim.notify("agent_engine: failed to load extension " .. mod .. ": " .. tostring(loaded), vim.log.levels.WARN)
      elseif type(loaded) == "table" and loaded.id and not registry[loaded.id] then
        M.register(loaded)
      end
    end
  end
end

---@param hook "on_before_send"|"on_after_reply"|"on_stream_event"|"on_file_changed"
---@param ... any
function M.emit(hook, ...)
  for _, ext in pairs(registry) do
    local fn = ext[hook]
    if type(fn) == "function" then
      pcall(fn, ...)
    end
  end
end

---@param prompt string
---@param ctx { prompt: string, session: table, raw?: boolean }
---@return string
function M.apply_before_send(prompt, ctx)
  ctx.prompt = prompt
  for _, ext in pairs(registry) do
    if type(ext.on_before_send) == "function" then
      local ok, result = pcall(ext.on_before_send, ctx)
      if ok and type(result) == "string" and result ~= "" then
        prompt = result
        ctx.prompt = prompt
      end
    end
  end
  return prompt
end

---@param cmd string
---@param arg string
---@return boolean handled
function M.try_slash_command(cmd, arg)
  cmd = cmd:lower()
  for _, ext in pairs(registry) do
    local cmds = ext.slash_commands
    if type(cmds) == "table" and type(cmds[cmd]) == "function" then
      local ok, handled = pcall(cmds[cmd], arg)
      if ok and handled then
        return true
      end
    end
  end
  return false
end

---@return string
function M.status_summary()
  local dirs = M.dirs()
  local exts = M.list_extensions()
  local parts = {}
  if #dirs > 0 then
    table.insert(parts, #dirs .. " plugin dir(s)")
  end
  if #exts > 0 then
    table.insert(parts, #exts .. " extension(s)")
  end
  if #parts == 0 then
    return "No plugin dirs or extensions loaded"
  end
  return table.concat(parts, ", ")
end

function M.reset()
  registry = {}
  runtime_dirs = {}
end

return M
