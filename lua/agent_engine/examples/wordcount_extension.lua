-- Minimal agent_engine extension — works with ANY agent CLI (Cursor, Claude, Copilot, …).
-- Load via: require("agent_engine").setup({ extensions = { "agent_engine.examples.wordcount_extension" } })
--
-- Adds:
--   • /wc slash command — count words in the current prompt
--   • on_before_send hook — appends a short footer with prompt stats

local M = {
  id = "wordcount",
  name = "Word count helper",
}

---@param api table from agent_engine.plugins (register, notify, get_config, require_engine)
function M.setup(api)
  api.notify("wordcount extension loaded", vim.log.levels.INFO)
end

--- Slash commands: return true when handled.
M.slash_commands = {
  wc = function(arg)
    local n = #vim.split(vim.trim(arg), "%s+", { plain = true })
    if arg == "" then
      vim.notify("Type a prompt first, then /wc", vim.log.levels.WARN)
    else
      vim.notify(string.format("Words in argument: %d", n), vim.log.levels.INFO)
    end
    return true
  end,
}

--- Transform prompt before it is sent to the active agent CLI.
---@param ctx { prompt: string, session: table, raw?: boolean }
---@return string|nil
function M.on_before_send(ctx)
  if ctx.raw then
    return nil
  end
  local words = #vim.split(vim.trim(ctx.prompt), "%s+", { plain = true })
  return ctx.prompt .. string.format("\n\n[wordcount: %d words]", words)
end

return M
