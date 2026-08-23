# Headroom integration (optional)

[Headroom](https://github.com/headroomlabs-ai/headroom) compresses **everything the agent reads** — tool outputs, logs, RAG chunks, files, and conversation history — before it reaches the LLM. Same answers, a fraction of the tokens.

`agent_engine` integrates Headroom as an **optional** package. The Lua bridge ships with the plugin; you install the Headroom CLI via pip or uv.

```bash
uv tool install --python 3.13 "headroom-ai[all]"
# or: pip install "headroom-ai[all]"
headroom doctor
```

Works with **any agent CLI** in `agent_engine` (Cursor, Claude, Copilot, Aider, …).

## How Headroom works (relevant to agent_engine)

Headroom is **not** a `headroom compress` stdin CLI. It compresses via:

| Mode | What it does | Best for agent_engine |
| --- | --- | --- |
| **proxy** (default) | `headroom proxy --port 8787` intercepts API traffic | Spawn agent with proxy env vars |
| **wrap** | `headroom wrap cursor -- agent …` | One-shot non-interactive runs |
| **mcp** | `headroom mcp serve` — tools `headroom_compress`, `headroom_retrieve`, `headroom_stats` | Cursor agent + `/mcp auto on` |
| **library** | `from headroom import compress` in Python | Rare; subprocess per send |

**Recommended:** `mode = "proxy"` with `auto_start_proxy = true`.

## Integration debug logging

When `integrations_log.enabled = true`, Headroom and agent spawn events are written to:

1. **Terminal stderr** — if you launched Neovim from a shell (`console = true`)
2. **Log file** — `~/.cache/nvim/agent_engine-integrations.log`

```lua
integrations_log = {
  enabled = true,
  console = true,   -- stderr in the nvim terminal
  file = true,
  notify = false,    -- set true to also pop vim.notify per line (noisy)
  debug = true,
},
```

| Command | Action |
| --- | --- |
| `:AgentIntegrationsLog` | Show last 60 lines in a notification |
| `:AgentIntegrationsLog path` | Print log file path |
| `/headroom log` | Same as tail in chat |

Watch live in another terminal:

```bash
tail -f ~/.cache/nvim/agent_engine-integrations.log
```

Logged events include: `headroom doctor`, proxy start, proxy env injection, `headroom wrap` argv, and full `agent spawn …` command line.

## Enable in agent_engine

```lua
require("agent_engine").setup({
  headroom = {
    enabled = true,
    mode = "proxy",
    proxy_port = 8787,
    auto_start_proxy = true,   -- starts proxy if headroom doctor fails
    output_shaper = false,     -- HEADROOM_OUTPUT_SHAPER=1 for output token savings
  },
})
```

`:AgentReload` after editing.

When `enabled = true`, the Headroom extension loads automatically.

## What happens on each `:AgentSend`

### Proxy mode (default)

1. If `auto_start_proxy` and `headroom doctor` fails → spawn `headroom proxy --port 8787` in the background
2. Agent subprocess gets env overrides (OpenAI / Anthropic base URLs → local proxy)
3. **All API traffic** from the agent CLI passes through Headroom — prompts, tool outputs, history on the wire

This matches Headroom’s design: compression on the **proxy path**, not by rewriting the prompt string in Neovim.

### Wrap mode

Spawn becomes:

```text
headroom wrap cursor -- agent --print --output-format stream-json … "your prompt"
```

Tool is auto-mapped from CLI dialect (`cursor`, `claude`, `copilot`, `aider`, `codex`, …) or set `wrap_tool` explicitly.

### MCP mode

Register Headroom as an MCP server (Cursor agent):

```json
{
  "mcpServers": {
    "headroom": {
      "command": "/absolute/path/from/command-v/headroom",
      "args": ["mcp", "serve"]
    }
  }
}
```

Or run `/headroom mcp install` or set `mcp_auto_install = true` on setup.

Then `/cli cursor` and `/mcp auto on`.

### Library mode

`mode = "library"` runs Python `compress()` on the assembled prompt in `on_before_send`. Slower; use only if you cannot use proxy/wrap.

## Chat commands

| Slash | `:AgentHeadroom` | Action |
| --- | --- | --- |
| `/headroom` | `:AgentHeadroom` | Status |
| `/headroom on` / `off` | `on` / `off` | Runtime toggle |
| `/headroom doctor` | — | Health check |
| `/headroom perf` | — | Savings summary |
| `/headroom proxy` | — | Start proxy manually |
| `/headroom mcp install` | — | Run `headroom mcp install` |
| `/headroom test` | — | Library mode test only |

## Cursor-specific note

Headroom’s README lists Cursor as **manual setup** for full interactive `headroom wrap cursor` sessions (proxy URLs in Cursor settings).

For **agent_engine** spawning the `agent` CLI:

- **Proxy mode** — injects `ANTHROPIC_BASE_URL` / `OPENAI_*` to the local proxy (good default)
- **Wrap mode** — `headroom wrap cursor -- agent …`

For the Cursor **IDE** (not the CLI), use `headroom wrap cursor` in a terminal and follow printed base URLs.

## Output token reduction

Headroom can also trim what the model writes back (verbosity steering, effort routing). Enable on the proxy:

```bash
export HEADROOM_OUTPUT_SHAPER=1
```

Or in agent_engine:

```lua
headroom = { enabled = true, output_shaper = true },
```

See Headroom README: `headroom learn --verbosity` for automatic terseness tuning.

## Lazy.nvim

Enable Headroom in your agent_engine Lazy spec (e.g. `plugins/agentvim-bundle.lua`):

```lua
headroom = { enabled = true, mode = "proxy" },
```

`agent_engine.setup()` warns on startup if Headroom is enabled but the CLI is missing from `PATH`.

## Configuration reference

| Option | Default | Description |
| --- | --- | --- |
| `enabled` | `false` | Opt-in |
| `mode` | `"proxy"` | `proxy` · `wrap` · `mcp` · `library` |
| `command` | `"headroom"` | CLI binary (use absolute path for MCP clients) |
| `proxy_port` | `8787` | Local proxy port |
| `auto_start_proxy` | `true` | Background `headroom proxy` when doctor fails |
| `wrap_tool` | `nil` | Force wrap target (`cursor`, `claude`, …) |
| `mcp_auto_install` | `false` | Run `headroom mcp install` on setup |
| `output_shaper` | `false` | `HEADROOM_OUTPUT_SHAPER=1` on agent spawn |
| `fallback_on_error` | `true` | Continue if proxy start fails |

## What gets compressed

| Source | Proxy/wrap | Library |
| --- | --- | --- |
| Tool outputs in agent run | **Yes** | No |
| API conversation on the wire | **Yes** | No |
| Local `<leader>Cr` preamble only | Only if agent sends it | Yes (prompt text) |
| Cursor `--resume` server history | **Yes** (on API path) | Partial |

## Troubleshooting

| Problem | Fix |
| --- | --- |
| `headroom missing` | `uv tool install --python 3.13 headroom-ai[all]` |
| `doctor fail` | `/headroom proxy` then `/headroom doctor` |
| No savings | Run `headroom perf`; ensure proxy mode not library |
| Codex/MCP PATH issues | Use absolute path from `command -v headroom` in mcp.json |
| Cursor agent ignores proxy | Try `mode = "wrap"` or Headroom’s manual Cursor setup |

## Modules

| File | Role |
| --- | --- |
| `headroom.lua` | Proxy start, env injection, wrap argv, MCP helpers |
| `extensions/headroom.lua` | Slash commands; library `on_before_send` |

See also [plugins-and-mcp.md](plugins-and-mcp.md) for MCP and extensions.
