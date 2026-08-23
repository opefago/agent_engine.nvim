# agent_engine.nvim

Cursor-style **agent chat** for Neovim — a side panel to talk to coding agents, stream replies, run parallel sessions, and review file edits with inline ghost diffs.

> **Status:** Public alpha (`v0.1.0-alpha`). The **Cursor Agent CLI** path is the most complete integration. Other CLIs (Claude, Copilot, Codex, …) are best-effort wrappers. See [Supported backends](#supported-backends) and [DISCLAIMER.md](DISCLAIMER.md).

## Features

- **Multi-CLI** — Cursor, Copilot, Claude Code, Codex, Gemini, Aider, Goose, and tgpt (auto-discovered from `PATH`)
- **Parallel chats** — multiple tabs, each with its own CLI, mode, model, and job
- **Modes** — `agent`, `plan`, and `ask` (passed through to the CLI)
- **Prompt queue** — send while busy; messages run when the current job finishes
- **Context in prompts** — code selections, file attachments, and `@file` fuzzy completion
- **Ghost review** — agent edits appear inline; accept or reject per hunk (or use `diffsplit` fallback)
- **Chat history** — closed chats archived and browsable (`:AgentHistory`, `/history`)
- **Slash commands** — `/mode`, `/cli`, `/model`, `/attach`, `/login`, `/mcp`, `/plugin`, and more
- **MCP & plugins** — Cursor agent MCP servers and `--plugin-dir` management
- **Lua extensions** — hooks for any CLI (`on_before_send`, custom slash commands, …)
- **Headroom** — optional [token compression](lua/agent_engine/docs/headroom.md) for any backend
- **Integration logging** — debug Headroom, MCP, and proxy wiring via `:AgentIntegrationsLog`

## Requirements

- **Neovim 0.10+** (`vim.uv` for async jobs and file watching)
- At least one **agent CLI** on `PATH` to send prompts (the UI loads without one)
- **Recommended:** [Cursor Agent CLI](https://cursor.com) (`agent`, `cursor-agent`, or `cursor`)

Optional integrations:

| Plugin | Purpose |
| --- | --- |
| [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) | Rich markdown in the transcript |
| [blink.cmp](https://github.com/saghen/blink.cmp) | `@file` completion in the prompt bar |
| [noice.nvim](https://github.com/folke/noice.nvim) | Extra spinner styles (`dots6`, `arc`, …) |

`fd` or `rg` on `PATH` speeds up `@file` completion when blink.cmp is not installed.

## Installation

### Lazy.nvim (recommended)

```lua
-- lua/plugins/agent_engine.lua
return {
  "opefago/agent_engine.nvim",
  lazy = false,
  opts = {
    default_cli = "cursor",
    review_style = "ghost",
    chat_width = 72,
  },
  config = function(_, opts)
    require("agent_engine").setup(opts)
  end,
}
```

Run `:Lazy sync`, then `:AgentChat`.

### Install script

```bash
# Default: ~/.local/share/nvim/lazy/agent_engine.nvim
curl -fsSL https://raw.githubusercontent.com/opefago/agent_engine.nvim/main/scripts/install.sh | bash

# Custom destination
AGENT_ENGINE_DEST=~/.config/nvim/lazy/agent_engine.nvim \
  curl -fsSL https://raw.githubusercontent.com/opefago/agent_engine.nvim/main/scripts/install.sh | bash
```

Or clone manually:

```bash
git clone https://github.com/opefago/agent_engine.nvim.git \
  ~/.local/share/nvim/lazy/agent_engine.nvim
```

### Manual (no plugin manager)

```lua
-- init.lua
vim.opt.rtp:append("~/.local/share/nvim/lazy/agent_engine.nvim")
require("agent_engine").setup({
  default_cli = "cursor",
  review_style = "ghost",
})
```

For the Cursor agent CLI, sign in with `/login` in the prompt bar, or send a prompt and complete browser auth when auto-login starts (`auto_login = true` by default).

## Quick start

1. `:AgentChat` — open the chat panel
2. Type a prompt in the input bar; send with `<C-s>` or `<CR>`
3. Select code in the editor → `<leader>Cr` (default leader is Space) to add a reference
4. When the agent edits files, review with ghost hunks (`<leader>va` accept, `<leader>vr` reject)

Built-in help appears in the transcript on first launch.

### Context in prompts

| Type | How to add | Cleared with |
| --- | --- | --- |
| **Code selections** | Visual/line selection + `<leader>Cr` or `:AgentRef` | `r` in prompt bar, `/selections clear`, `:AgentClearSelections` |
| **File attachments** | `<leader>Ca`, `a` in prompt bar, or `/attach path` | `/attach clear` |
| **`@file` in prompt** | Type `@` in the prompt bar (blink.cmp) | `/pending clear` or `<leader>CR` |

## Keymaps

Default leader is `<Space>`. All keymaps are configurable via `setup({ keymaps = { … } })`.

| Key | Action |
| --- | --- |
| `<leader>Cc` | Toggle chat panel |
| `<leader>Cf` | Focus chat panel |
| `<leader>Cs` | Send prompt / focus input |
| `<leader>Cn` | New chat tab |
| `<leader>C[` / `<leader>C]` | Previous / next chat tab |
| `<leader>Cm` / `<leader>CM` | Cycle / pick mode |
| `<leader>Co` | Pick model |
| `<leader>Ci` / `<leader>CI` | Pick / cycle CLI |
| `<leader>Ca` | Attach file |
| `<leader>Cr` | Add selection as code reference |
| `<leader>CR` | Clear all pending context |
| `<leader>Ch` | Browse chat history |
| `<leader>Cx` | Cancel job |
| `<leader>va` / `<leader>vr` | Accept / reject current ghost hunk |
| `<leader>vA` / `<leader>vR` | Accept / reject all hunks in file |
| `<leader>vn` | Next file with pending edits |
| `]h` / `[h` | Next / previous hunk |

Full keymap and slash-command reference: [lua/agent_engine/README.md](lua/agent_engine/README.md).

## Commands

| Command | Description |
| --- | --- |
| `:AgentChat` / `:AgentChatToggle` | Open / toggle chat panel |
| `:AgentNew` / `:AgentClose` | New / close chat tab |
| `:AgentSend [text]` | Send prompt (or focus input if no text) |
| `:AgentMode [agent\|plan\|ask]` | Set or pick mode |
| `:AgentModel [name]` | Set or pick model |
| `:AgentCli [id]` | Set or pick CLI backend |
| `:AgentRef` | Add visual/line selection as code reference |
| `:AgentAttach [path]` | Attach a file to the next prompt |
| `:AgentHistory` | Browse archived chats |
| `:AgentClearPending` | Clear selections, attachments, and `@` paths |
| `:AgentClearSelections` | Clear code selections only |
| `:AgentCancel` | Cancel job and clear queue |
| `:AgentClear` | Clear transcript and remote session |
| `:AgentAccept` / `:AgentReject` | Accept / reject current ghost hunk |
| `:AgentAcceptAll` / `:AgentRejectAll` | Accept / reject all hunks in file |
| `:AgentNextFile` | Jump to next file with pending edits |
| `:AgentMcp [list\|pick\|…]` | MCP server management (Cursor CLI) |
| `:AgentPlugin [list\|add path]` | Cursor plugin-dir management |
| `:AgentHeadroom [status\|on\|off\|…]` | Headroom compression control |
| `:AgentIntegrationsLog [tail\|path]` | View integration debug log |
| `:AgentReload` | Reload plugin without restarting Neovim |

Legacy `Cursor*` command aliases are also registered.

## Supported backends

| Tier | CLIs | Notes |
| --- | --- | --- |
| **Full** | Cursor (`agent`, `cursor-agent`, `cursor`) | Streaming JSON, modes, models, `--resume`, MCP, attachments, `/login` |
| **Basic** | Claude, Copilot, Codex, Gemini, Aider | Non-interactive prompt; plain-text streaming |
| **Experimental** | Goose, tgpt, custom `generic` providers | Prompt passed as a single argument only |

Modes (`plan` / `ask`), live model listing, chat resume, `/mcp`, and `/login` apply to the **Cursor** dialect only.

## Configuration

```lua
require("agent_engine").setup({
  default_cli = "cursor",
  default_mode = "agent",
  default_model = "auto",
  auto_login = true,
  review_style = "ghost",       -- or "diffsplit"
  history_enabled = true,
  persist_transcript = false,   -- set true to restore chats across restarts
  headroom = { enabled = false },
  mcp = { auto_approve = false },
  integrations_log = { enabled = false },
  extensions = {
    -- "agent_engine.examples.wordcount_extension",
  },
})
```

| Option | Default | Description |
| --- | --- | --- |
| `default_cli` | `nil` | Preferred provider id when several are installed |
| `review_style` | `"ghost"` | `"ghost"` (inline hunks) or `"diffsplit"` |
| `history_enabled` | `true` | Archive closed chats for `:AgentHistory` |
| `persist_transcript` | `false` | Restore transcript content across Neovim restarts |
| `auto_login` | `true` | Start Cursor login when sending while logged out |
| `headroom.enabled` | `false` | Opt-in token compression (any CLI) |
| `mcp.auto_approve` | `false` | Pass `--approve-mcps` to Cursor agent |

See [lua/agent_engine/README.md](lua/agent_engine/README.md) for all options, keymaps, and slash commands.

## Documentation

| Doc | Contents |
| --- | --- |
| [lua/agent_engine/README.md](lua/agent_engine/README.md) | Full command, keymap, and config reference |
| [lua/agent_engine/docs/plugins-and-mcp.md](lua/agent_engine/docs/plugins-and-mcp.md) | Lua extensions, MCP, and Cursor plugin dirs |
| [lua/agent_engine/docs/headroom.md](lua/agent_engine/docs/headroom.md) | Headroom compression setup |
| [DISCLAIMER.md](DISCLAIMER.md) | Security notice for third-party CLIs |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Development setup and PR guidelines |
| [CHANGELOG.md](CHANGELOG.md) | Release history |

## Development

```bash
git clone https://github.com/opefago/agent_engine.nvim.git
cd agent_engine.nvim

./scripts/test.sh   # Plenary busted specs (CI runs on push/PR)
stylua lua/         # format
```

Requires Neovim 0.10+ and [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) for tests.

## Project layout

```
agent_engine.nvim/
├── lua/agent_engine/       # Plugin source
│   ├── init.lua            # setup(), commands, keymaps, watchers
│   ├── chat.lua            # chat UI, streaming, slash commands
│   ├── agent.lua           # CLI discovery and job spawning
│   ├── ghost.lua           # inline hunk review
│   ├── session.lua         # multi-tab sessions and history
│   ├── mcp.lua             # MCP discovery (Cursor CLI)
│   ├── plugins.lua         # Lua extensions + --plugin-dir
│   ├── headroom.lua        # Headroom bridge
│   ├── docs/               # integration guides
│   └── examples/           # sample extensions
├── plugin/agent_engine.lua # Neovim 0.10+ entry (version gate)
├── ftplugin/agentchat.lua  # Transcript buffer filetype
├── tests/                  # Plenary busted specs
├── scripts/install.sh
├── .github/workflows/ci.yml
├── DISCLAIMER.md
└── CHANGELOG.md
```

## Troubleshooting

| Problem | What to try |
| --- | --- |
| No CLI on PATH | Install and log in to `agent` / `claude` / `copilot` |
| Send fails | `:AgentCli` to pick backend; check CLI auth (`/login` for Cursor) |
| Attachments ignored | Use Cursor or Claude; pick a vision-capable model |
| Ghost review missing | `review_style = "ghost"` and file open in the editor |
| Config changes not applied | `:AgentReload` after editing Lua |
| Headroom / MCP issues | `:AgentIntegrationsLog tail` or enable `integrations_log` |

## Disclaimer

This plugin spawns third-party agent CLIs that can read and modify your files. Read [DISCLAIMER.md](DISCLAIMER.md) before use.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
