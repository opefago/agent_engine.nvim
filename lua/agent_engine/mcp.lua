-- File: lua/agent_engine/mcp.lua
-- MCP server discovery and management via the Cursor agent CLI.

local agent = require("agent_engine.agent")
local config = require("agent_engine.config")

local M = {}

---@type boolean|nil
local auto_approve_override = nil

---@class AgentEngineMcpServer
---@field id string
---@field status string|nil live status from `agent mcp list`
---@field source string config file path
---@field config table|nil raw entry from mcp.json

---@return string[]
local function config_paths()
  local cfg = config.get().mcp or {}
  if type(cfg.config_paths) == "table" and #cfg.config_paths > 0 then
    return cfg.config_paths
  end
  local paths = {}
  local project = vim.fs.joinpath(vim.fn.getcwd(), ".cursor", "mcp.json")
  if vim.fn.filereadable(project) == 1 then
    table.insert(paths, project)
  end
  local home = vim.fs.joinpath(vim.fn.expand("~"), ".cursor", "mcp.json")
  if vim.fn.filereadable(home) == 1 then
    table.insert(paths, home)
  end
  return paths
end

---@param path string
---@return table<string, table>|nil servers
---@return string|nil err
local function read_config_file(path)
  local ok, raw = pcall(vim.fn.readfile, path)
  if not ok or type(raw) ~= "table" then
    return nil, "failed to read " .. path
  end
  local text = table.concat(raw, "\n")
  local ok_decode, decoded = pcall(vim.json.decode, text)
  if not ok_decode or type(decoded) ~= "table" then
    return nil, "invalid JSON in " .. path
  end
  local servers = decoded.mcpServers or decoded.servers
  if type(servers) ~= "table" then
    return {}
  end
  return servers
end

---@return table<string, string> id -> status line
local function fetch_live_status()
  local cli = agent.resolve_cli()
  if not cli or cli.dialect ~= "cursor" then
    return {}
  end
  local argv = { cli.binary }
  if vim.fs.basename(cli.binary) == "cursor" then
    table.insert(argv, "agent")
  end
  vim.list_extend(argv, { "mcp", "list" })
  local out = vim.fn.system(argv)
  if vim.v.shell_error ~= 0 then
    return {}
  end
  local status = {}
  for line in vim.gsplit(vim.trim(out or ""), "\n", { plain = true }) do
    local id, rest = line:match("^(%S+)%s*:%s*(.*)$")
    if id and rest then
      status[id] = vim.trim(rest)
    end
  end
  return status
end

--- Whether to pass --approve-mcps when spawning the agent.
---@return boolean
function M.auto_approve()
  if auto_approve_override ~= nil then
    return auto_approve_override
  end
  local cfg = config.get().mcp or {}
  return cfg.auto_approve == true
end

---@param value boolean|nil nil resets to config default
function M.set_auto_approve(value)
  auto_approve_override = value
end

---@return AgentEngineMcpServer[]
function M.list_servers()
  local live = fetch_live_status()
  local seen = {}
  local out = {}

  for _, path in ipairs(config_paths()) do
    local servers = read_config_file(path)
    if type(servers) == "table" then
      for id, entry in pairs(servers) do
        if not seen[id] then
          seen[id] = true
          table.insert(out, {
            id = id,
            status = live[id],
            source = path,
            config = entry,
          })
        end
      end
    end
  end

  -- Servers reported live but missing from config (edge case).
  for id, status in pairs(live) do
    if not seen[id] then
      table.insert(out, {
        id = id,
        status = status,
        source = "(runtime)",
        config = nil,
      })
    end
  end

  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

---@param id string
---@return AgentEngineMcpServer|nil
function M.get_server(id)
  for _, s in ipairs(M.list_servers()) do
    if s.id == id then
      return s
    end
  end
end

---@param subcmd string
---@param extra string[]|nil
---@return boolean ok
---@return string output
local function run_mcp_cli(subcmd, extra)
  local cli = agent.resolve_cli()
  if not cli or cli.dialect ~= "cursor" then
    return false, "MCP management requires the Cursor agent CLI"
  end
  local argv = { cli.binary }
  if vim.fs.basename(cli.binary) == "cursor" then
    table.insert(argv, "agent")
  end
  vim.list_extend(argv, { "mcp", subcmd })
  if extra then
    vim.list_extend(argv, extra)
  end
  local out = vim.fn.system(argv)
  if vim.v.shell_error ~= 0 then
    return false, vim.trim(out or "") ~= "" and vim.trim(out) or ("mcp " .. subcmd .. " failed")
  end
  return true, vim.trim(out or "")
end

---@param id string
---@return boolean ok
---@return string|nil err
function M.enable(id)
  return run_mcp_cli("enable", { id })
end

---@param id string
---@return boolean ok
---@return string|nil err
function M.disable(id)
  return run_mcp_cli("disable", { id })
end

---@param id string
---@return boolean ok
---@return string|nil err
function M.login(id)
  return run_mcp_cli("login", { id })
end

---@param id string
---@return boolean ok
---@return string output
function M.list_tools(id)
  return run_mcp_cli("list-tools", { id })
end

---@return string summary for notifications
function M.status_summary()
  local servers = M.list_servers()
  if #servers == 0 then
    return "No MCP servers configured (.cursor/mcp.json)"
  end
  local parts = {}
  for _, s in ipairs(servers) do
    table.insert(parts, string.format("%s (%s)", s.id, s.status or "unknown"))
  end
  local approve = M.auto_approve() and ", auto-approve on" or ""
  return #servers .. " MCP server(s): " .. table.concat(parts, ", ") .. approve
end

return M
