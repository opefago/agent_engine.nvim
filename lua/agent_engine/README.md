# Agent Chat

**Agent Chat** is the chat UI built into [agent_engine](init.lua) for Neovim. It gives you a Cursor-style side panel to talk to coding agents, stream replies in real time, run multiple chats in parallel, and review file edits with inline ghost diffs.

## Features

- **Multi-CLI support** — Cursor Agent, GitHub Copilot, Claude Code, Codex, Gemini, Aider, and more (auto-discovered from your `PATH`)
- **Parallel chats** — open several agent sessions at once; each tab runs independently
- **Modes** — `agent`, `plan`, and `ask`
- **Model & CLI pickers** — switch backend and model from the prompt bar or via commands
- **Prompt queue** — send while the agent is busy; messages run automatically when the current job finishes
- **Code references** — attach selections (`@file:line`) or whole files to prompts
- **Ghost review** — proposed edits appear inline in your buffer; accept or reject per hunk
- **Slash commands** — `/mode`, `/cli`, `/model`, `/attach`, `/mcp`, `/plugin`, and more
- **Extensions & MCP** — Lua hooks for any agent CLI; MCP and Cursor plugin dirs for the Cursor agent backend

## Requirements

- **Neovim 0.10+** (uses `vim.uv` for async jobs)
- At least one **agent CLI** on your `PATH`, for example:
  - [Cursor Agent CLI](https://cursor.com) — `agent`, `cursor-agent`, or `cursor`
  - [GitHub Copilot CLI](https://github.com/github/copilot-cli) — `copilot`
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — `claude`
  - [Aider](https://aider.chat) — `aider`
  - OpenAI Codex — `codex`
  - Gemini CLI — `gemini`

The chat UI loads even when no CLI is installed, but sending prompts requires a working backend.

## Installation

Install with Lazy.nvim (see [README.md](../../../README.md) at the repo root) or add to your config:

```lua
-- lua/plugins/agent_engine.lua
return {
  "opefago/agent_engine.nvim",
  lazy = false,
  opts = {
    default_cli = "cursor",
    default_mode = "agent",
    default_model = "auto",
    review_style = "ghost",
  },
  config = function(_, opts)
    require("agent_engine").setup(opts)
  end,
}
```

Or clone manually:

```bash
git clone https://github.com/opefago/agent_engine.nvim.git \
  ~/.local/share/nvim/lazy/agent_engine.nvim
```

## Quick start

1. Install an agent CLI. For Cursor, sign in with `/login` in the prompt bar or let auto-login run when you send your first prompt.
2. Open Neovim and run:

   ```
   :AgentChat
   ```

3. Type your prompt in the **input bar** at the bottom of the panel.
4. Send with `<C-s>`, `<CR>`, or `<leader>Cs` (default leader is Space).

On first launch you will see a built-in help transcript with keybindings and slash commands.

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

Legacy aliases `:CursorChat`, `:CursorSend`, `:CursorMode`, etc. are also available.

## Default keymaps

Leader is `<Space>` in LazyVim.

### Global (`<leader>C…` = agent chat)

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

### Prompt bar (when focused in the input window)

| Key | Action |
| --- | --- |
| `<C-s>` / `<CR>` / `<C-CR>` | Send prompt |
| `m` / `M` | Pick / cycle mode |
| `c` / `C` | Pick / cycle CLI |
| `o` | Pick model |
| `a` | Attach current file |
| `n` | New chat tab |
| `d` | Close current tab |
| `x` | Cancel job |
| `]` / `[` | Next / previous tab |
| `1`–`9` | Jump to tab by number |
| `q` | Close entire chat panel |

### Ghost review (`<leader>v…`)

| Key | Action |
| --- | --- |
| `<leader>va` / `<leader>vr` | Accept / reject current hunk |
| `<leader>vA` / `<leader>vR` | Accept / reject all hunks in file |
| `<leader>vn` | Next file with pending edits |
| `]h` / `[h` | Next / previous hunk |

## Slash commands (prompt bar)

Type these in the prompt input and press Enter:

| Command | Description |
| --- | --- |
| `/mode plan` | Switch to plan mode |
| `/cli cursor` | Switch CLI backend |
| `/model auto` | Switch model |
| `/attach path/to/file` | Attach a file for the next send |
| `/new` | New chat tab |
| `/close` | Close current tab |
| `/clear` | Clear transcript |
| `/cancel` | Cancel job and clear queue |
| `/login` | Authenticate with Cursor agent CLI |
| `/queue` | Show queued prompt count |
| `/queue clear` | Clear queued prompts |
| `/help` | Show slash command summary |
| `/mcp` | List MCP servers (Cursor agent CLI) |
| `/mcp auto on` | Auto-approve MCP on each Cursor agent run |
| `/plugin` | List plugin dirs and loaded extensions |

**Plugins, MCP, and extensions** — see [docs/plugins-and-mcp.md](docs/plugins-and-mcp.md). **Headroom (optional token compression)** — [docs/headroom.md](docs/headroom.md).

## Configuration

Call `require("agent_engine").setup({ ... })` before or during plugin load. All options are optional.

```lua
require("agent_engine").setup({
  -- Preferred CLI when several are installed (nil = first discovered)
  default_cli = "cursor",

  -- agent | plan | ask
  default_mode = "agent",

  -- Model id passed to the CLI (use "auto" for CLI default)
  default_model = "auto",

  -- Offered in the model picker
  models = {
    "auto",
    "composer-2.5",
    "claude-sonnet-5-thinking-high",
    "gpt-5.2",
  },

  -- Panel title and width (characters) for the right-side split
  chat_title = "Agent Chat",
  chat_width = 72,

  -- How to review agent file edits: "ghost" (inline) or "diffsplit"
  review_style = "ghost",

  -- Suppress Neovim "file changed on disk" prompts (ghost handles review)
  suppress_reload_prompt = true,

  -- Persist chat history across Neovim restarts (default: false)
  persist_transcript = false,
  max_persisted_messages = 0,

  -- CLI flags
  force = false,  -- pass --force to agent invocations
  auto_login = true, -- start Cursor agent login when a prompt is sent while logged out
  trust = true,   -- pass --trust where supported

  -- Custom agent binary (legacy; adds a "custom" provider)
  -- binaries = { "/path/to/my-agent" },

  -- Extra providers
  -- providers = {
  --   { id = "mytool", label = "My Tool", binaries = { "mytool" }, dialect = "generic" },
  -- },

  -- Lua extensions (any CLI) — see docs/plugins-and-mcp.md
  -- extensions = { "agent_engine.examples.wordcount_extension" },

  -- MCP (Cursor agent reads .cursor/mcp.json)
  -- mcp = { auto_approve = false },

  -- Cursor agent plugin dirs (--plugin-dir)
  -- plugins = { dirs = {} },

  keymaps = {
    toggle_chat = "<leader>Cc",
    new_agent = "<leader>Cn",
    next_agent = "<leader>C]",
    prev_agent = "<leader>C[",
    send = "<leader>Cs",
    cycle_mode = "<leader>Cm",
    pick_model = "<leader>Co",
    pick_cli = "<leader>Ci",
    cancel_job = "<leader>Cx",
    attach_file = "<leader>Ca",
    add_selection = "<leader>Cr",
    accept_change = "<leader>va",
    reject_change = "<leader>vr",
    accept_all = "<leader>vA",
    reject_all = "<leader>vR",
    next_pending_file = "<leader>vn",
  },
})
```

### Configuration reference

| Option | Default | Description |
| --- | --- | --- |
| `providers` | cursor, copilot, claude, … | CLI providers to discover on `PATH` |
| `default_cli` | `nil` | Preferred provider id |
| `default_mode` | `"agent"` | Starting mode |
| `default_model` | `"auto"` | Starting model |
| `models` | see `config.lua` | Models shown in the picker |
| `chat_width` | `72` | Width of the chat split |
| `chat_title` | `"Agent Chat"` | Panel title |
| `review_style` | `"ghost"` | `"ghost"` or `"diffsplit"` |
| `suppress_reload_prompt` | `true` | Block W12 disk-reload dialogs |
| `persist_transcript` | `false` | Save chats between sessions |
| `max_persisted_messages` | `0` | Cap restored messages per chat |
| `force` | `false` | Allow forced agent runs |
| `auto_login` | `true` | Run Cursor agent login when a prompt is sent while logged out |
| `trust` | `true` | Trust workspace for CLIs that support it |
| `keymaps` | see `config.lua` | Override any keymap string |

## How it works

1. **Chat panel** — A locked right split shows the markdown transcript above and a sticky prompt bar below. File-tree and picker opens cannot replace these windows.
2. **Sessions** — Each tab is an independent session with its own CLI, mode, model, and optional remote chat id (Cursor).
3. **Streaming** — Agent stdout is parsed and rendered live in the transcript with a spinner while thinking.
4. **File edits** — When an agent writes to disk, a file watcher compares buffer vs disk and starts **ghost review**: deleted lines fade, additions appear inline, and you accept or reject per hunk.
5. **Queue** — If you send while a job runs, prompts are queued and dispatched automatically when the agent finishes.

## Troubleshooting

| Problem | What to try |
| --- | --- |
| `No agent CLI found on PATH` | Install and log in to `cursor`, `copilot`, `claude`, or another supported CLI |
| Chat opens but send fails | Run `:AgentCli` to pick an installed backend; check CLI auth |
| Attachments ignored | Use Cursor or Claude CLI; pick a vision-capable model |
| Changes not reviewed | Ensure `review_style = "ghost"` and the file is open in the editor |
| Config changes not applied | Run `:AgentReload` after editing Lua files |

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

## License

Apache License 2.0 — see [agent_engine.nvim](https://github.com/opefago/agent_engine.nvim).
