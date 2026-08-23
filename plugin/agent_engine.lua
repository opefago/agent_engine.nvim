-- agent_engine.nvim — Neovim entrypoint (version gate only).
-- Call require("agent_engine").setup({ ... }) from your plugin manager config.

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("agent_engine.nvim requires Neovim 0.10 or newer", vim.log.levels.ERROR)
  return
end
