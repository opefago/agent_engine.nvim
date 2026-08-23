-- Headroom extension — proxy / wrap / MCP / library modes.
-- https://github.com/headroomlabs-ai/headroom

local headroom = require("agent_engine.headroom")

local M = {
  id = "headroom",
  name = "Headroom compression",
}

function M.setup(api)
  if not headroom.enabled() then
    return
  end
  if not headroom.available() then
    api.notify("headroom: install CLI — uv tool install --python 3.13 headroom-ai[all]", vim.log.levels.WARN)
    return
  end
  local c = require("agent_engine.config").get().headroom or {}
  if c.mcp_auto_install and headroom.mode() == "mcp" then
    local ok, out = headroom.mcp_install()
    if ok then
      api.notify("headroom mcp install ok", vim.log.levels.INFO)
    else
      api.notify("headroom mcp install: " .. out, vim.log.levels.WARN)
    end
  end
end

--- Library mode only — proxy/wrap compress API traffic automatically.
---@param ctx { prompt: string, session: table, raw?: boolean }
---@return string|nil
function M.on_before_send(ctx)
  if ctx.raw or headroom.mode() ~= "library" then
    return nil
  end
  local out, _, err = headroom.compress_library(ctx.prompt)
  if err then
    vim.notify("headroom library: " .. err .. " (using original prompt)", vim.log.levels.WARN)
    return nil
  end
  return out
end

M.slash_commands = {
  headroom = function(arg)
    local sub, rest = (arg or ""):match("^(%S*)%s*(.*)$")
    sub = (sub or ""):lower()
    rest = vim.trim(rest or "")

    if sub == "" or sub == "status" then
      vim.notify(headroom.status_summary(), vim.log.levels.INFO)
    elseif sub == "on" or sub == "enable" then
      headroom.set_enabled(true)
      vim.notify("Headroom enabled", vim.log.levels.INFO)
    elseif sub == "off" or sub == "disable" then
      headroom.set_enabled(false)
      vim.notify("Headroom disabled", vim.log.levels.INFO)
    elseif sub == "doctor" then
      local ok, out = headroom.run_cli("doctor")
      vim.notify(ok and out or out, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    elseif sub == "perf" then
      local ok, out = headroom.run_cli("perf")
      vim.notify(ok and out or out, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    elseif sub == "proxy" then
      local ok, err = headroom.start_proxy()
      vim.notify(
        ok and ("Proxy at " .. headroom.proxy_base_url()) or err,
        ok and vim.log.levels.INFO or vim.log.levels.ERROR
      )
    elseif sub == "mcp" then
      if rest == "install" then
        local ok, out = headroom.mcp_install()
        vim.notify(ok and out or out, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
      else
        local cfg = headroom.mcp_server_config()
        vim.notify(
          "MCP: add to .cursor/mcp.json — command: "
            .. cfg.command
            .. " args: "
            .. table.concat(cfg.args, " ")
            .. " · or /headroom mcp install",
          vim.log.levels.INFO
        )
      end
    elseif sub == "test" and headroom.mode() == "library" then
      local sample = rest ~= "" and rest or "Sample prompt for library compress test."
      local out, stats, err = headroom.compress_library(sample)
      if err then
        vim.notify("Headroom test failed: " .. err, vim.log.levels.ERROR)
      elseif stats then
        vim.notify(
          string.format(
            "Library: %d → %d est. tokens (~%d%% saved)",
            stats.before_tokens,
            stats.after_tokens,
            stats.saved_pct
          ),
          vim.log.levels.INFO
        )
      else
        vim.notify("Headroom test: no change", vim.log.levels.INFO)
      end
    elseif sub == "test" then
      vim.notify(
        "Proxy/wrap mode: compression runs on API traffic — run /headroom doctor after /headroom proxy",
        vim.log.levels.INFO
      )
    elseif sub == "log" then
      require("agent_engine.integration_log").show()
    else
      vim.notify(
        "Headroom: status | on | off | doctor | perf | proxy | mcp [install] | log | test",
        vim.log.levels.INFO
      )
    end
    return true
  end,
}

return M
