# Agent Chat (agent_engine)

**Agent Chat** is the Neovim UI in this plugin for talking to coding agents — a Cursor-style side panel with streaming replies, parallel tabs, and inline ghost diff review.

> **Standalone plugin:** see the [repository README](../../README.md) for installation, disclaimers, and supported backends.

## Features

- **Multi-CLI support** — Cursor Agent, GitHub Copilot, Claude Code, Codex, Gemini, Aider, and more (auto-discovered from your `PATH`)
- **Parallel chats** — open several agent sessions at once; each tab runs independently
- **Modes** — `agent`, `plan`, and `ask` (Cursor CLI; other backends ignore mode flags)
- **Model & CLI pickers** — switch backend and model from the prompt bar or via commands
- **Prompt queue** — send while the agent is busy; messages run automatically when the current job finishes
- **Code references** — attach selections (`@file:line`) or whole files to prompts
- **Ghost review** — proposed edits appear inline in your buffer; accept or reject per hunk
- **Slash commands** — `/mode`, `/cli`, `/model`, `/attach`, `/mcp`, `/plugin`, and more
- **Extensions & MCP** — Lua hooks for any agent CLI; MCP and Cursor plugin dirs for the Cursor agent backend

## Requirements

- **Neovim 0.10+** (uses `vim.uv` for async jobs)
- At least one **agent CLI** on your `PATH` (see [root README](../../README.md#supported-backends))

The chat UI loads even when no CLI is installed, but sending prompts requires a working backend.

## Installation

Install the parent repository — see [README.md](../../README.md#installation).

Minimal Lazy.nvim spec:

```lua
return {
  "YOURUSER/agent_engine.nvim",
  lazy = false,
  opts = {
    default_cli = "cursor",
    review_style = "ghost",
  },
  config = function(_, opts)
    require("agent_engine").setup(opts)
  end,
}
```

## Quick start

1. Install an agent CLI and sign in (e.g. `agent login`).
2. `:AgentChat`
3. Type your prompt in the **input bar**; send with `<C-s>`, `<CR>`, or your configured `<leader>Cs`.
4. Built-in help in the transcript lists keybindings and slash commands.

## Commands

| Command | Description |
| --- | --- |
| `:AgentChat` | Open the chat panel |
| `:AgentChatToggle` | Toggle the chat panel |
| `:AgentNew` | New parallel chat tab |
| `:AgentClose` | Close the active chat tab |
| `:AgentSend [text]` | Send a prompt (or focus input if no text) |
| `:AgentMode [agent\|plan\|ask]` | Set or pick mode |
| `:AgentModel [name]` | Set or pick model |
| `:AgentCli [id]` | Set or pick CLI backend |
| `:AgentCancel` | Cancel the running job and clear the queue |
| `:AgentClear` | Clear transcript and remote session |
| `:AgentRef` | Add visual/line selection as `@reference` |
| `:AgentAttach [path]` | Attach a file to the next prompt |
| `:AgentAccept` / `:AgentReject` | Accept or reject the current ghost hunk |
| `:AgentAcceptAll` / `:AgentRejectAll` | Accept or reject all hunks in the file |
| `:AgentNextFile` | Jump to the next file with pending edits |
| `:AgentReload` | Reload agent_engine without restarting Neovim |

Legacy aliases `:CursorChat`, `:CursorSend`, etc. are also available.

## Default keymaps

Leader is `<Space>` when using LazyVim defaults. Override via `setup({ keymaps = { ... } })`.

### Global (`<leader>C…`)

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
| `<leader>Cr` | Add selection as reference |
| `<leader>Cx` | Cancel job |

### Prompt bar

| Key | Action |
| --- | --- |
| `<C-s>` / `<CR>` | Send prompt |
| `m` / `M` | Pick / cycle mode |
| `c` / `C` | Pick / cycle CLI |
| `o` | Pick model |
| `a` | Attach current file |
| `@` | File reference completion (blink.cmp) |
| `/` | Slash command menu |

### Ghost review (`<leader>v…`)

| Key | Action |
| --- | --- |
| `<leader>va` / `<leader>vr` | Accept / reject current hunk |
| `<leader>vA` / `<leader>vR` | Accept / reject all hunks in file |
| `<leader>vn` | Next file with pending edits |
| `]h` / `[h` | Next / previous hunk |

## Slash commands (prompt bar)

| Command | Description |
| --- | --- |
| `/mode plan` | Switch to plan mode (Cursor) |
| `/cli cursor` | Switch CLI backend |
| `/model auto` | Switch model |
| `/attach path/to/file` | Attach a file for the next send |
| `/mcp` | List MCP servers (Cursor agent CLI) |
| `/plugin` | List plugin dirs and loaded extensions |
| `/help` | Show slash command summary |

**Plugins, MCP, and extensions** — [docs/plugins-and-mcp.md](docs/plugins-and-mcp.md). **Headroom (optional)** — [docs/headroom.md](docs/headroom.md).

## Configuration

```lua
require("agent_engine").setup({
  default_cli = "cursor",
  default_mode = "agent",
  default_model = "auto",
  review_style = "ghost",
  chat_width = 72,
  history_enabled = true,
  headroom = { enabled = false },
  extensions = {},
  keymaps = { /* see config.lua */ },
})
```

See `config.lua` for the full option list and defaults.

## How it works

1. **Chat panel** — locked right split: markdown transcript + sticky prompt bar.
2. **Sessions** — each tab has its own CLI, mode, model, and optional Cursor chat id.
3. **Streaming** — stdout parsed live (JSON for Cursor; plain text for other CLIs).
4. **File edits** — file watcher + ghost review for inline accept/reject.
5. **Queue** — prompts sent while busy are queued per tab.

## Module layout

```
lua/agent_engine/
├── init.lua      # setup(), commands, keymaps, file watchers
├── chat.lua      # chat UI, streaming, slash commands
├── agent.lua     # CLI discovery and job spawning
├── plugins.lua   # Lua extensions + Cursor --plugin-dir
├── mcp.lua       # MCP discovery + Cursor agent mcp CLI
├── session.lua   # multi-tab session state
├── ghost.lua     # inline hunk review
├── config.lua    # defaults and user options
├── storage.lua   # pending diff persistence
├── watcher.lua   # OS file watchers
├── docs/         # integration guides
└── examples/     # sample extensions
```

## Troubleshooting

| Problem | What to try |
| --- | --- |
| `No agent CLI found on PATH` | Install and log in to a supported CLI |
| Chat opens but send fails | `:AgentCli` to pick backend; check CLI auth |
| Attachments ignored | Use Cursor or Claude CLI; vision-capable model |
| Changes not reviewed | `review_style = "ghost"` and file open in editor |
| Config changes not applied | `:AgentReload` after editing Lua files |

## License

Apache License 2.0 — see [LICENSE](../../LICENSE).
