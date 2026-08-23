local describe = require("plenary.busted").describe
local it = require("plenary.busted").it
local before_each = require("plenary.busted").before_each

local function reload_ghost()
  package.loaded["agent_engine.config"] = nil
  package.loaded["agent_engine.storage"] = nil
  package.loaded["agent_engine.ghost"] = nil
  require("agent_engine.config").setup({ review_style = "ghost" })
  return require("agent_engine.ghost")
end

describe("agent_engine.ghost", function()
  before_each(function()
    reload_ghost()
  end)

  it("start detects hunks between old and new lines", function()
    local ghost = reload_ghost()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha", "beta" })
    local ok = ghost.start(buf, "/tmp/agent_engine_ghost_test.txt", { "alpha", "beta" }, { "alpha", "gamma" })
    assert.is_true(ok)
    assert.is_true(ghost.is_active(buf))
    ghost.accept_all(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.same({ "alpha", "gamma" }, lines)
    assert.is_false(ghost.is_active(buf))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("start returns false when there is no diff", function()
    local ghost = reload_ghost()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "same" })
    local ok = ghost.start(buf, "/tmp/agent_engine_ghost_test2.txt", { "same" }, { "same" })
    assert.is_false(ok)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
