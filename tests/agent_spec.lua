local busted = require("plenary.busted")
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local assert = busted.assert

local function reload_modules()
  package.loaded["agent_engine.config"] = nil
  package.loaded["agent_engine.agent"] = nil
  local config = require("agent_engine.config")
  local agent = require("agent_engine.agent")
  return config, agent
end

describe("agent_engine.agent", function()
  before_each(function()
    local config, agent = reload_modules()
    config.setup({
      providers = {
        {
          id = "testcli",
          label = "Test CLI",
          binaries = { "true" },
          dialect = "generic",
        },
        {
          id = "fakeclaude",
          label = "Fake Claude",
          binaries = { "true" },
          dialect = "claude",
        },
      },
      default_cli = "testcli",
    })
    agent.selected_cli = "testcli"
  end)

  it("build_args for generic dialect passes prompt only", function()
    local agent = require("agent_engine.agent")
    local args, err, cli = agent.build_args({ prompt = "hello world" })
    assert.is_nil(err)
    assert.is_not_nil(cli)
    assert.are.equal("testcli", cli.id)
    assert.are.same({ "hello world" }, args)
  end)

  it("build_args rejects empty prompt", function()
    local agent = require("agent_engine.agent")
    local args, err = agent.build_args({ prompt = "   " })
    assert.is_nil(args)
    assert.is_not_nil(err)
  end)

  it("build_args for claude dialect uses -p", function()
    local config, agent = reload_modules()
    config.setup({
      providers = {
        { id = "fakeclaude", label = "Fake Claude", binaries = { "true" }, dialect = "claude" },
      },
      default_cli = "fakeclaude",
      default_model = "auto",
    })
    agent.selected_cli = "fakeclaude"
    local args, err = agent.build_args({ prompt = "explain this" })
    assert.is_nil(err)
    assert.are.same({ "-p", "explain this" }, args)
  end)

  it("model_supports_attachments treats auto as capable", function()
    local agent = require("agent_engine.agent")
    assert.is_true(agent.model_supports_attachments("auto"))
  end)
end)
