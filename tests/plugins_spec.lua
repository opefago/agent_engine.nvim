local busted = require("plenary.busted")
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local assert = busted.assert

local function reload_plugins()
  package.loaded["agent_engine.config"] = nil
  package.loaded["agent_engine.plugins"] = nil
  require("agent_engine.config").setup({})
  return require("agent_engine.plugins")
end

describe("agent_engine.plugins", function()
  before_each(function()
    reload_plugins().reset()
  end)

  it("apply_before_send runs extension hooks in order", function()
    local plugins = reload_plugins()
    plugins.register({
      id = "a",
      on_before_send = function(ctx)
        return ctx.prompt .. "!"
      end,
    })
    plugins.register({
      id = "b",
      on_before_send = function(ctx)
        return ctx.prompt .. "?"
      end,
    })
    local out = plugins.apply_before_send("hi", { prompt = "hi", session = {} })
    assert.are.equal("hi!?", out)
  end)

  it("slash_commands returns true when handled", function()
    local plugins = reload_plugins()
    plugins.register({
      id = "slash",
      slash_commands = {
        ping = function()
          return true
        end,
      },
    })
    assert.is_true(plugins.try_slash_command("ping", ""))
    assert.is_false(plugins.try_slash_command("missing", ""))
  end)
end)
