-- File: lua/agent_engine/headroom.lua
-- Optional Headroom integration (https://github.com/headroomlabs-ai/headroom).
-- Modes: proxy (recommended), wrap, mcp, library — see docs/headroom.md.

local config = require("agent_engine.config")
local log = require("agent_engine.integration_log")

local M = {}

---@type boolean|nil
local runtime_enabled = nil

---@type uv.uv_process_t|nil
local proxy_handle = nil

--- Dialect → headroom wrap target (README agent matrix).
local WRAP_TOOLS = {
  cursor = "cursor",
  claude = "claude",
  copilot = "copilot",
  aider = "aider",
  codex = "codex",
  gemini = "gemini",
  goose = "goose",
}

---@return table
local function cfg()
  return config.get().headroom or {}
end

---@return boolean
function M.enabled()
  if runtime_enabled ~= nil then
    return runtime_enabled
  end
  local c = cfg()
  return c.enabled == true
end

---@param value boolean|nil nil resets to config default
function M.set_enabled(value)
  runtime_enabled = value
end

---@return string
function M.mode()
  local c = cfg()
  return c.mode or "proxy"
end

---@return string
function M.command()
  local c = cfg()
  if type(c.command) == "string" and c.command ~= "" then
    return c.command
  end
  return "headroom"
end

---@return boolean
function M.available()
  return vim.fn.executable(M.command()) == 1
end

---@return string base URL without trailing slash
function M.proxy_base_url()
  local c = cfg()
  if type(c.proxy_url) == "string" and c.proxy_url ~= "" then
    return c.proxy_url:gsub("/+$", "")
  end
  local port = c.proxy_port or 8787
  return "http://127.0.0.1:" .. tostring(port)
end

---@param cli table|nil AgentEngineDiscoveredCli
---@return string|nil wrap tool id
function M.wrap_tool_for_cli(cli)
  local c = cfg()
  if type(c.wrap_tool) == "string" and c.wrap_tool ~= "" then
    return c.wrap_tool
  end
  if cli and cli.dialect then
    return WRAP_TOOLS[cli.dialect]
  end
  return nil
end

---@return boolean ok
---@return string output
local function doctor_check()
  if not M.available() then
    return false, ""
  end
  local job = vim.system({ M.command(), "doctor" }, { text = true, timeout = 15000 })
  local out = vim.trim((job and job.stdout or "") .. "\n" .. (job and job.stderr or ""))
  return job and job.code == 0, out
end

---@return boolean
function M.doctor_ok()
  local ok, out = doctor_check()
  if log.enabled() then
    if ok then
      log.info("headroom", "doctor ok" .. (out ~= "" and (" — " .. out:sub(1, 200)) or ""))
    else
      log.warn("headroom", "doctor failed: " .. (out ~= "" and out:sub(1, 400) or "no output"))
    end
  end
  return ok
end

--- Start headroom proxy in the background (detached).
---@return boolean ok
---@return string|nil err
function M.start_proxy()
  if not M.available() then
    log.warn("headroom", "start_proxy: binary not on PATH")
    return false, "headroom not on PATH"
  end
  if doctor_check() then
    log.info("headroom", "proxy already healthy at " .. M.proxy_base_url())
    return true, nil
  end

  if proxy_handle then
    local ok_closing, closing = pcall(function()
      return proxy_handle:is_closing()
    end)
    if ok_closing and not closing then
      return true, nil
    end
  end

  local c = cfg()
  local port = c.proxy_port or 8787
  local args = { "proxy", "--port", tostring(port) }
  if type(c.proxy_args) == "table" then
    vim.list_extend(args, c.proxy_args)
  end

  local handle, err = vim.uv.spawn(M.command(), {
    args = args,
    stdio = { nil, nil, nil },
    detached = true,
    hide = true,
  })

  if not handle then
    log.warn("headroom", "proxy spawn failed: " .. tostring(err))
    return false, "failed to spawn proxy: " .. tostring(err)
  end

  proxy_handle = handle
  log.info("headroom", "spawned proxy: " .. M.command() .. " " .. table.concat(args, " "))

  -- Wait briefly for proxy to accept traffic.
  for _ = 1, 20 do
    vim.wait(250, function()
      return doctor_check()
    end)
    if doctor_check() then
      log.info("headroom", "proxy ready at " .. M.proxy_base_url())
      return true, nil
    end
  end

  log.warn("headroom", "proxy started but doctor still failing")
  return false, "proxy started but doctor check failed — run: headroom doctor"
end

---@param cli table|nil
---@return table env overrides for agent subprocess
function M.spawn_env(cli)
  if not M.enabled() then
    return {}
  end

  local mode = M.mode()
  local c = cfg()
  local env = {}

  if type(c.env) == "table" then
    for k, v in pairs(c.env) do
      if type(k) == "string" and type(v) == "string" then
        env[k] = v
      end
    end
  end

  if c.output_shaper then
    env.HEADROOM_OUTPUT_SHAPER = "1"
  end

  -- Cursor agent uses api2.cursor.sh — OpenAI/Anthropic proxy URLs do not apply.
  local use_proxy_env = mode == "proxy"
  if cli and cli.dialect == "cursor" then
    use_proxy_env = false
    if log.enabled() and mode == "proxy" then
      log.debug(
        "headroom",
        "cursor CLI: proxy env skipped (Cursor uses api2.cursor.sh — configure Headroom in Cursor settings or use Claude/Codex CLI)"
      )
    end
  end

  if use_proxy_env then
    if c.auto_start_proxy then
      local ok, err = M.start_proxy()
      if not ok and c.fallback_on_error == false then
        vim.notify("headroom proxy: " .. (err or "failed"), vim.log.levels.ERROR)
      elseif not ok then
        vim.notify("headroom proxy: " .. (err or "failed") .. " (agent may bypass compression)", vim.log.levels.WARN)
      end
    end

    local base = M.proxy_base_url()
    local inject = c.proxy_env or {}
    env.ANTHROPIC_BASE_URL = env.ANTHROPIC_BASE_URL or inject.ANTHROPIC_BASE_URL or base
    env.OPENAI_BASE_URL = env.OPENAI_BASE_URL or inject.OPENAI_BASE_URL or (base .. "/v1")
    env.OPENAI_API_BASE = env.OPENAI_API_BASE or inject.OPENAI_API_BASE or (base .. "/v1")
    log.json("headroom", "proxy env for agent spawn", env)
  end

  return env
end

--- Wrap agent binary with `headroom wrap <tool> -- …` when mode is wrap.
---@param binary string
---@param args string[]
---@param cli table|nil
---@return string binary
---@return string[] args
function M.adjust_spawn(binary, args, cli)
  if not M.enabled() or M.mode() ~= "wrap" then
    return binary, args
  end

  -- Cursor IDE uses manual base-URL setup; `headroom wrap cursor` does not accept a child CLI.
  if cli and cli.dialect == "cursor" then
    return binary, args
  end

  local tool = M.wrap_tool_for_cli(cli)
  if not tool then
    vim.notify(
      "headroom wrap: no tool mapping for this CLI — set headroom.wrap_tool or use mode = proxy",
      vim.log.levels.WARN
    )
    return binary, args
  end

  local wrap_argv = { "wrap", tool }
  local c = cfg()
  if type(c.wrap_args) == "table" then
    vim.list_extend(wrap_argv, c.wrap_args)
  end
  table.insert(wrap_argv, "--")
  table.insert(wrap_argv, binary)
  vim.list_extend(wrap_argv, args)
  log.info("headroom", "wrap spawn: " .. M.command() .. " " .. table.concat(wrap_argv, " "))
  return M.command(), wrap_argv
end

--- MCP server entry for .cursor/mcp.json
---@return table
function M.mcp_server_config()
  local c = cfg()
  return {
    command = M.command(),
    args = c.mcp_args or { "mcp", "serve" },
  }
end

--- Run `headroom mcp install` (registers MCP for supported clients).
---@return boolean ok
---@return string output
function M.mcp_install()
  if not M.available() then
    return false, "headroom not on PATH"
  end
  local job = vim.system({ M.command(), "mcp", "install" }, { text = true, timeout = 120000 })
  local out = vim.trim((job.stdout or "") .. "\n" .. (job.stderr or ""))
  return job.code == 0, out ~= "" and out or ("exit " .. tostring(job.code))
end

--- Rough token estimate (chars / 4).
---@param text string
---@return integer
local function estimate_tokens(text)
  if type(text) ~= "string" or text == "" then
    return 0
  end
  return math.max(1, math.floor(#text / 4))
end

--- Library mode: `from headroom import compress` via Python subprocess.
---@param prompt string
---@return string compressed
---@return table|nil stats
---@return string|nil err
function M.compress_library(prompt)
  local c = cfg()
  local min_chars = c.min_chars or 0
  if min_chars > 0 and #prompt < min_chars then
    return prompt, nil, nil
  end

  local py = c.library_python or "python3"
  if vim.fn.executable(py) ~= 1 then
    return prompt, nil, py .. " not found"
  end

  local script = [[
import sys
from headroom import compress
text = sys.stdin.read()
try:
    out = compress([{"role": "user", "content": text}])
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
if isinstance(out, list) and out:
    last = out[-1]
    if isinstance(last, dict) and last.get("content"):
        print(last["content"])
    else:
        print(text)
elif isinstance(out, str):
    print(out)
else:
    print(text)
]]

  local timeout = c.timeout_ms
  if type(timeout) ~= "number" or timeout <= 0 then
    timeout = 120000
  end

  local job = vim.system({ py, "-c", script }, {
    stdin = prompt,
    text = true,
    timeout = timeout,
  })

  if not job or job.code ~= 0 then
    local err = vim.trim(job.stderr or "") or ("exit " .. tostring(job and job.code))
    return prompt, nil, err
  end

  local stdout = vim.trim(job.stdout or "")
  if stdout == "" or stdout == prompt then
    return prompt, nil, nil
  end

  local before = estimate_tokens(prompt)
  local after = estimate_tokens(stdout)
  local saved = before > 0 and math.floor((before - after) * 100 / before) or 0
  return stdout, {
    before_tokens = before,
    after_tokens = after,
    saved_pct = saved,
  }, nil
end

---@return string
function M.status_summary()
  if not M.enabled() then
    return "Headroom: off (/headroom on · pip install headroom-ai[all])"
  end
  if not M.available() then
    return "Headroom: enabled but `" .. M.command() .. "` missing — uv tool install headroom-ai[all]"
  end

  local parts = { "Headroom: on", "mode=" .. M.mode() }
  if M.mode() == "proxy" then
    table.insert(parts, M.proxy_base_url())
    table.insert(parts, M.doctor_ok() and "doctor ok" or "doctor fail")
  elseif M.mode() == "wrap" then
    table.insert(parts, "tool=" .. (cfg().wrap_tool or "auto"))
  elseif M.mode() == "mcp" then
    table.insert(parts, "use headroom mcp serve + /mcp auto on")
  end
  if cfg().output_shaper then
    table.insert(parts, "output-shaper")
  end
  return table.concat(parts, ", ")
end

---@return boolean ok
---@return string output
function M.run_cli(subcmd, extra)
  if not M.available() then
    return false, "headroom not on PATH"
  end
  local argv = { M.command(), subcmd }
  if extra then
    vim.list_extend(argv, extra)
  end
  log.info("headroom", "run: " .. table.concat(argv, " "))
  local job = vim.system(argv, { text = true, timeout = 120000 })
  local out = vim.trim((job.stdout or "") .. "\n" .. (job.stderr or ""))
  if log.enabled() and out ~= "" then
    log.debug("headroom", subcmd .. " output: " .. out:sub(1, 800))
  end
  return job.code == 0, out ~= "" and out or ("exit " .. tostring(job.code))
end

function M.ensure_extension_loaded()
  if not cfg().enabled then
    return
  end
  local mod = "agent_engine.extensions.headroom"
  local exts = config.get().extensions or {}
  for _, name in ipairs(exts) do
    if name == mod then
      return
    end
  end
  table.insert(config.get().extensions, mod)
end

return M
