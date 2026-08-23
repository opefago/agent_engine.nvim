-- Agent transcript is markdown content with a dedicated filetype (neo-tree protection).
vim.bo[0].syntax = "markdown"
if vim.treesitter.language.get_lang("markdown") then
  vim.treesitter.start(0, "markdown")
end
