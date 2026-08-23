local describe = require("plenary.busted").describe
local it = require("plenary.busted").it
local before_each = require("plenary.busted").before_each

local function reload_config()
  package.loaded["agent_engine.config"] = nil
  return require("agent_engine.config")
end

describe("agent_engine.config", function()
  before_each(function()
    reload_config()
  end)

  it("merges user opts over defaults", function()
    local config = reload_config()
    config.setup({
      chat_width = 80,
      default_cli = "cursor",
    })
    local values = config.get()
    assert.are.equal(80, values.chat_width)
    assert.are.equal("cursor", values.default_cli)
    assert.are.equal("ghost", values.review_style)
  end)

  it("adds deprecated binaries as a generic provider", function()
    local config = reload_config()
    config.setup({
      binaries = { "/custom/agent" },
    })
    local values = config.get()
    local found = false
    for _, p in ipairs(values.providers) do
      if p.id == "custom" then
        found = true
        assert.are.same({ "/custom/agent" }, p.binaries)
        assert.are.equal("generic", p.dialect)
      end
    end
    assert.is_true(found)
  end)

  it("keeps headroom disabled by default", function()
    local config = reload_config()
    config.setup({})
    assert.is_false(config.get().headroom.enabled)
  end)
end)
