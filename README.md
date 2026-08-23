# agent_engine.nvim

Cursor-style **agent chat** for Neovim — a side panel to talk to coding agents, stream replies, run parallel sessions, and review file edits with inline ghost diffs.

> **Status:** Public alpha. The **Cursor Agent CLI** path is the most complete integration. Other CLIs (Claude, Copilot, Codex, …) are best-effort wrappers. See [Supported backends](#supported-backends) and [DISCLAIMER.md](DISCLAIMER.md).

## Features

- Multi-tab agent chat with prompt queue
- **Ghost review** — accept/reject agent edits per hunk inline
- Code selections, file attachments, and `@file` completion
- MCP and Cursor plugin-dir management (Cursor CLI)
- Lua extension hooks (`on_before_send`, slash commands, …)
- Optional [Headroom](https://github.com/headroomlabs-ai/headroom) token compression

## Requirements

- **Neovim 0.10+** (`vim.uv` for async jobs and file watching)
- At least one **agent CLI** on `PATH` to send prompts (UI loads without one)
- **Recommended:** [Cursor Agent CLI](https://cursor.com) (`agent`, `cursor-agent`, or `cursor`)

Optional integrations:

| Plugin | Purpose |
| --- | --- |
| [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) | Rich markdown in the transcript |
| [blink.cmp](https://github.com/saghen/blink.cmp) | `@file` completion in the prompt bar |
| [noice.nvim](https://github.com/folke/noice.nvim) | Extra spinner styles |

## Installation

### CLI (clone for Lazy.nvim)

```bash
# Default: ~/.local/share/nvim/lazy/agent_engine.nvim
curl -fsSL https://raw.githubusercontent.com/YOURUSER/agent_engine.nvim/main/scripts/install.sh | bash

# Custom destination
AGENT_ENGINE_DEST=~/.config/nvim/lazy/agent_engine.nvim \
  bash scripts/install.sh https://github.com/YOURUSER/agent_engine.nvim.git
```

Or manually:

```bash
git clone https://github.com/YOURUSER/agent_engine.nvim.git \
  ~/.local/share/nvim/lazy/agent_engine.nvim
```

### Lazy.nvim

```lua
-- lua/plugins/agent_engine.lua
return {
  "YOURUSER/agent_engine.nvim",
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

### Manual (no plugin manager)

```lua
-- init.lua
vim.opt.rtp:append("~/.local/share/nvim/lazy/agent_engine.nvim")
require("agent_engine").setup({
  default_cli = "cursor",
  review_style = "ghost",
})
```

Sign in to your agent CLI before sending prompts (e.g. `agent login`).

## Quick start

1. `:AgentChat` — open the chat panel
2. Type a prompt in the input bar; send with `<C-s>` or `<CR>`
3. Select code in the editor → `<leader>Cr` (default leader is Space) to add a reference
4. When the agent edits files, review with ghost hunks (`<leader>va` accept, `<leader>vr` reject)

Built-in help appears in the transcript on first launch. Full reference: [lua/agent_engine/README.md](lua/agent_engine/README.md).

## Supported backends

| Tier | CLIs | Notes |
| --- | --- | --- |
| **Full** | Cursor (`agent`, `cursor-agent`, `cursor`) | Streaming JSON, modes, models, `--resume`, MCP, attachments |
| **Basic** | Claude, Copilot, Codex, Gemini, Aider | Non-interactive prompt; plain-text streaming |
| **Experimental** | Goose, tgpt, custom `generic` providers | Prompt passed as a single argument only |

Modes (`plan` / `ask`), live model listing, chat resume, and `/mcp` apply to the **Cursor** dialect only.

## Configuration

```lua
require("agent_engine").setup({
  default_cli = "cursor",
  default_mode = "agent",
  default_model = "auto",
  review_style = "ghost",       -- or "diffsplit"
  history_enabled = true,
  headroom = { enabled = false },
  extensions = {
    -- "agent_engine.examples.wordcount_extension",
  },
})
```

See [lua/agent_engine/README.md](lua/agent_engine/README.md) for all options, keymaps, and slash commands. Extensions and MCP: [lua/agent_engine/docs/plugins-and-mcp.md](lua/agent_engine/docs/plugins-and-mcp.md).

## Commands

| Command | Description |
| --- | --- |
| `:AgentChat` | Open chat panel |
| `:AgentSend [text]` | Send prompt or focus input |
| `:AgentCli` | Pick agent backend |
| `:AgentReload` | Reload plugin without restarting Neovim |

Legacy `Cursor*` command aliases are also registered.

## Development

```bash
# From the repo root
./scripts/test.sh

# Format
stylua lua/
```

## Project layout

```
agent_engine.nvim/
├── lua/agent_engine/     # Plugin source
├── plugin/               # Neovim 0.10+ entry (version check)
├── ftplugin/agentchat.lua
├── tests/                # Plenary busted specs
├── scripts/install.sh
├── DISCLAIMER.md
└── CHANGELOG.md
```

## Troubleshooting

| Problem | What to try |
| --- | --- |
| No CLI on PATH | Install and log in to `agent` / `claude` / `copilot` |
| Send fails | `:AgentCli` to pick backend; check CLI auth |
| Attachments ignored | Use Cursor or Claude; pick a vision-capable model |
| Ghost review missing | `review_style = "ghost"` and file open in editor |

## Disclaimer

This plugin spawns third-party agent CLIs that can read and modify your files. Read [DISCLAIMER.md](DISCLAIMER.md) before use.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
