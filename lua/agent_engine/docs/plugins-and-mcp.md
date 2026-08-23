# Plugins, MCP, and agent_engine integration

`agent_engine` is the Neovim chat UI and orchestration layer. It can drive **any supported agent CLI** on your `PATH` — Cursor Agent, Claude Code, Copilot, Codex, Gemini, Aider, Goose, tgpt, or a custom binary you register as a provider.

This guide walks through a simple end-to-end example and explains how three different “plugin” concepts fit together.

## Three layers (do not confuse them)

| Layer | What it is | Who consumes it | Works with any CLI? |
| --- | --- | --- | --- |
| **agent_engine extensions** | Lua modules with hooks (`on_before_send`, slash commands, …) | Neovim / `agent_engine` | **Yes** — independent of which agent CLI is active |
| **MCP servers** | External tool processes (stdio, HTTP, …) defined in `mcp.json` | The **agent CLI** at runtime | Depends on the CLI — Cursor reads `.cursor/mcp.json`; Claude/Copilot have their own MCP config |
| **Cursor plugin dirs** | Directories passed as `--plugin-dir` when spawning Cursor agent | **Cursor agent only** | **No** — only when `dialect == "cursor"` |

```
┌─────────────────────────────────────────────────────────────┐
│  Neovim  :AgentChat                                         │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  agent_engine (chat UI, ghost review, sessions)       │  │
│  │    • Lua extensions  ← hooks run here, any CLI        │  │
│  │    • spawns subprocess with dialect-specific argv     │  │
│  └───────────────────────────┬───────────────────────────┘  │
│                                │                              │
│         ┌──────────────────────┼──────────────────────┐       │
│         ▼                      ▼                      ▼       │
│    cursor agent           claude CLI            copilot CLI     │
│    + mcp.json             + its MCP           + its tools     │
│    + --plugin-dir           config                              │
└─────────────────────────────────────────────────────────────┘
```

When you switch CLI with `/cli claude` or `:AgentCli`, **Lua extensions keep working**. MCP management commands in chat (`/mcp`) and `--plugin-dir` only apply when the active backend is the Cursor agent dialect.

---

## Quick start: Lua extension (any agent)

### 1. Copy or use the bundled example

See `lua/agent_engine/examples/wordcount_extension.lua`. It:

- Registers slash command `/wc`
- Appends a word-count footer to every prompt via `on_before_send`

### 2. Enable it in setup

In `lua/plugins/agentvim-bundle.lua` (or your own plugin spec):

```lua
require("agent_engine").setup({
  extensions = {
    "agent_engine.examples.wordcount_extension",
  },
})
```

Run `:AgentReload` after editing extension files.

### 3. Try it in chat

1. `:AgentChat`
2. Pick any installed CLI: `/cli cursor` or `/cli claude` (or `:AgentCli`)
3. Type a prompt, then `/wc` — or send a message and notice the `[wordcount: N words]` footer added before the CLI sees the prompt

Extensions never replace the agent; they wrap the chat layer around whichever CLI you selected.

### Extension API

Load a module that returns a table with `id` and optional hooks:

```lua
local M = {
  id = "my_ext",
  name = "Human label",
}

function M.setup(api)
  -- api.register, api.notify, api.get_config(), api.require_engine("chat")
end

-- Return a new prompt string to transform before send (nil = no change)
function M.on_before_send(ctx) end  -- ctx: { prompt, session, raw? }

function M.on_after_reply(ctx) end    -- ctx: { reply, session, code? }
function M.on_stream_event(event, acc) end
function M.on_file_changed(bufnr, path) end

M.slash_commands = {
  mycmd = function(arg) return true end,  -- true = handled
}

return M
```

| Hook | When it runs |
| --- | --- |
| `setup(api)` | On `plugins.load()` / `:AgentReload` |
| `on_before_send` | After slash-command handling, before `agent.build_args()` |
| `on_after_reply` | When a job finishes (success or failure) |
| `on_stream_event` | Each parsed stream-json event (Cursor dialect) |
| `on_file_changed` | When ghost review detects disk changes |
| `slash_commands` | User types `/name args` in the prompt bar |

---

## Quick start: MCP (Cursor agent)

MCP (Model Context Protocol) servers expose **tools** the agent can call (search docs, query APIs, run commands). `agent_engine` does not implement MCP itself — it configures and spawns the **Cursor agent CLI**, which loads servers from `mcp.json`.

Other CLIs (Claude Code, Copilot, …) use MCP through their own config files and CLIs. Use `/cli` to switch backends; use each tool’s native MCP docs for non-Cursor agents.

### 1. Add a server to `mcp.json`

Project-local (preferred for repos):

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/allowed/dir"]
    }
  }
}
```

Path: `<project>/.cursor/mcp.json` or `~/.cursor/mcp.json`.

`agent_engine` merges both (project first, then home) when listing servers.

### 2. Configure auto-approve (optional)

In setup:

```lua
mcp = {
  auto_approve = true,  -- passes --approve-mcps to Cursor agent on each run
},
```

Or in chat: `/mcp auto on`

Without auto-approve, the Cursor agent may prompt for MCP approval on first use.

### 3. Inspect and manage from chat

| Action | Prompt bar | Command |
| --- | --- | --- |
| List servers + status | `/mcp` or `/mcp list` | `:AgentMcp list` |
| Interactive picker | — | `:AgentMcp pick` |
| Enable / disable / login | `/mcp enable ID` | `:AgentMcp enable ID` |
| List tools for a server | `/mcp tools ID` | `:AgentMcp tools ID` |
| Toggle auto-approve | `/mcp auto on\|off` | — |

Management commands call `agent mcp …` under the hood and require the **Cursor agent dialect** (`agent`, `cursor-agent`, or `cursor` on `PATH`). If you are on Claude or Copilot, `/mcp` will report that MCP management needs the Cursor CLI — switch with `/cli cursor` for MCP setup, then switch back if you want.

### 4. Send a prompt that uses MCP tools

1. `:AgentChat`
2. `/cli cursor` (if not already on Cursor)
3. `/mcp list` — confirm your server appears with a healthy status
4. Ask something that needs the tool, e.g. “List files in the allowed directory using your filesystem tool”

On each send, `agent_engine` builds argv like:

```text
agent --print --output-format stream-json … [--approve-mcps] [--plugin-dir …] "your prompt"
```

MCP servers are loaded by the Cursor agent process, not by Neovim.

---

## Quick start: Cursor plugin directories

**Cursor plugin dirs** are local folders the Cursor agent loads via `--plugin-dir`. They are **not** the same as Lua `extensions`.

### 1. Static dirs in config

```lua
plugins = {
  dirs = {
    vim.fs.joinpath(vim.fn.expand("~"), ".cursor", "plugins", "my-plugin"),
  },
},
```

### 2. Runtime add/remove in chat

```
/plugin list
/plugin add /path/to/my-cursor-plugin
/plugin remove /path/to/my-cursor-plugin
```

Or `:AgentPlugin` / `:AgentPlugin add /path`.

Dirs are passed on every Cursor-dialect spawn:

```399:402:lua/agent_engine/agent.lua
    for _, dir in ipairs(require("agent_engine.plugins").dirs()) do
      table.insert(args, "--plugin-dir")
      table.insert(args, dir)
    end
```

Non-Cursor CLIs ignore `--plugin-dir`.

---

## End-to-end walkthrough

**Goal:** Use a Lua extension with Claude, and MCP tools with Cursor, in the same Neovim session.

### A. Extension with Claude (any CLI)

```text
:AgentChat
/cli claude
Explain this function @src/main.lua
/wc
```

The wordcount extension runs in Neovim; Claude receives the transformed prompt.

### B. MCP with Cursor

```text
/cli cursor
/mcp list
/mcp auto on
Search our internal docs for "retry policy" and summarize
```

Cursor agent connects to MCP servers from `mcp.json` and may call tools during the run. Stream output appears in the transcript as usual.

### C. Both configured at once

```lua
require("agent_engine").setup({
  default_cli = "claude",
  extensions = { "agent_engine.examples.wordcount_extension" },
  mcp = { auto_approve = false },
  plugins = { dirs = {} },
})
```

- **Claude tab:** extension hooks active; no Cursor MCP UI
- **Cursor tab** (`/cli cursor`): extension hooks **still** active; MCP and plugin dirs apply to the spawned process

---

## Commands reference

| Command | Description |
| --- | --- |
| `:AgentCli` | Pick agent backend (any installed CLI) |
| `:AgentMcp [subcommand]` | MCP list/manage (Cursor dialect) |
| `:AgentPlugin [add path]` | List plugin dirs / extensions |
| `:AgentReload` | Reload `agent_engine` and extensions |

### Slash commands (prompt bar)

| Slash | Description |
| --- | --- |
| `/cli ID` | Switch agent CLI |
| `/mcp …` | MCP management (Cursor) |
| `/plugin …` | Plugin dirs + extensions list |
| `/help` | Summary |

---

## Configuration reference

```lua
require("agent_engine").setup({
  -- Any agent CLI (nil = first discovered on PATH)
  default_cli = "cursor",

  -- Lua extensions — work with every CLI
  extensions = {
    "agent_engine.examples.wordcount_extension",
    "my_plugin.agent_extension",
  },

  -- MCP — Cursor agent reads mcp.json; auto_approve adds --approve-mcps
  mcp = {
    auto_approve = false,
    config_paths = nil,  -- default: .cursor/mcp.json + ~/.cursor/mcp.json
  },

  -- Cursor-only --plugin-dir paths
  plugins = {
    dirs = {},
  },

  -- Register a custom agent binary
  providers = {
    {
      id = "myagent",
      label = "My Agent",
      binaries = { "my-agent-cli" },
      dialect = "generic",  -- or "cursor", "claude", "copilot", …
    },
  },
})
```

---

## Troubleshooting

| Problem | What to check |
| --- | --- |
| `/mcp` says “requires Cursor agent CLI” | Run `/cli cursor` or install `agent` on `PATH` |
| MCP server listed but tools fail | `/mcp tools SERVER_ID`; run `/mcp login SERVER_ID` if OAuth |
| Extension not loading | Module path in `extensions`; errors on `:AgentReload` |
| `--plugin-dir` ignored | Active CLI must be Cursor dialect |
| Hooks run but agent unchanged | `on_before_send` must **return** the new prompt string |
| Using MCP with Claude/Copilot | Configure MCP in that CLI’s own config — not via `/mcp` |

---

## Module map

| File | Role |
| --- | --- |
| `plugins.lua` | Extension registry, `--plugin-dir` list, hook dispatch |
| `mcp.lua` | Read `mcp.json`, wrap `agent mcp` CLI |
| `agent.lua` | Dialect-aware argv (`build_args`), job spawning |
| `chat.lua` | `/mcp`, `/plugin` slash commands, send pipeline |
| `examples/wordcount_extension.lua` | Minimal extension sample |

See also [README.md](../README.md) for chat UI, keymaps, and ghost review. Optional **[Headroom](https://github.com/headroomlabs-ai/headroom)** compression: [headroom.md](headroom.md).
