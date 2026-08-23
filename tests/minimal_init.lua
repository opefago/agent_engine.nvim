-- Bootstrap rtp for headless Plenary tests.
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
vim.opt.rtp:prepend(root)

local plenary_dir = vim.env.PLENARY_DIR
if not plenary_dir or plenary_dir == "" then
  plenary_dir = "/tmp/plenary.nvim"
end
vim.opt.rtp:prepend(plenary_dir)

-- Isolate state dir from the user's real Neovim data.
vim.fn.setenv("XDG_DATA_HOME", root .. "/.test-data")
