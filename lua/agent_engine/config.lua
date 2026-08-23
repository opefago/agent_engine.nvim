-- File: lua/agent_engine/config.lua
-- Defaults and user overrides for agent_engine.

local M = {}

---@class AgentEngineKeymaps
---@field toggle_chat string
---@field new_agent string
---@field next_agent string
---@field prev_agent string
---@field send string
---@field add_selection string
---@field cycle_mode string
---@field pick_mode string
---@field pick_model string
---@field pick_cli string
---@field cycle_cli string
---@field accept_change string
---@field reject_change string
---@field accept_all string
---@field reject_all string
---@field next_hunk string
---@field prev_hunk string
---@field next_pending_file string
---@field cancel_job string
---@field focus_chat string
---@field attach_file string
---@field clear_pending string
---@field pick_history string

---@class AgentEngineProvider
---@field id string
---@field label string
---@field binaries string[]
---@field dialect "cursor"|"copilot"|"claude"|"aider"|"codex"|"gemini"|"generic"

---@class AgentEngineMcpConfig
---@field auto_approve boolean pass --approve-mcps to Cursor agent
---@field config_paths string[]|nil mcp.json paths (default: project + ~/.cursor/mcp.json)

---@class AgentEnginePluginsConfig
---@field dirs string[] local Cursor plugin directories (--plugin-dir)

---@class AgentEngineHeadroomConfig
---@field enabled boolean opt-in Headroom compression
---@field mode "proxy"|"wrap"|"mcp"|"library" integration mode (default proxy)
---@field command string headroom CLI binary
---@field proxy_port integer local proxy port (default 8787)
---@field proxy_url string|nil override base URL
---@field proxy_args string[]|nil extra args for headroom proxy
---@field proxy_env table<string,string>|nil extra env keys for proxy mode
---@field auto_start_proxy boolean spawn proxy before agent if doctor fails
---@field wrap_tool string|nil explicit wrap target (cursor, claude, …)
---@field wrap_args string[]|nil args before `--` in headroom wrap
---@field mcp_args string[]|nil default { "mcp", "serve" }
---@field mcp_auto_install boolean run headroom mcp install on setup (mcp mode)
---@field library_python string python for library mode
---@field min_chars integer library mode: skip below this length
---@field timeout_ms integer subprocess timeout
---@field fallback_on_error boolean proxy: warn and continue if proxy fails
---@field output_shaper boolean set HEADROOM_OUTPUT_SHAPER=1 on agent spawn
---@field env table<string,string>|nil extra env on every agent spawn

---@class AgentEngineIntegrationsLogConfig
---@field enabled boolean write integration debug lines to console + log file
---@field console boolean print to stderr (terminal where nvim was started)
---@field file boolean append to cache log file
---@field notify boolean also vim.notify each line (noisy)
---@field debug boolean include debug-level lines
---@field file_path string|nil override log path

---@class AgentEngineConfig
---@field providers AgentEngineProvider[]
---@field binaries string[] deprecated: merged into a generic provider when set
---@field default_cli string|nil provider id preferred when available
---@field default_mode "agent"|"plan"|"ask"
---@field default_model string
---@field models string[]
---@field force boolean
---@field trust boolean
---@field chat_width number
---@field chat_title string
---@field spinner_style string cli-spinners name (via noice.util.spinners when installed)
---@field stream_ui_interval_ms number cap stream preview redraws (~30fps default)
---@field stream_chunk_interval_ms number batch agent stdout before UI callback
---@field history_enabled boolean archive closed chats to browsable history
---@field max_history_sessions number cap for archived chats on disk
---@field review_style "ghost"|"diffsplit"
---@field suppress_reload_prompt boolean
---@field persist_transcript boolean
---@field max_persisted_messages number
---@field attachment_models string[]|nil explicit model ids that accept file/image attachments
---@field mcp AgentEngineMcpConfig MCP server integration (Cursor agent CLI)
---@field plugins AgentEnginePluginsConfig Cursor agent plugin directories
---@field headroom AgentEngineHeadroomConfig optional Headroom compression (any CLI)
---@field integrations_log AgentEngineIntegrationsLogConfig integration debug logging
---@field extensions string[] Lua modules to load as agent_engine extensions
---@field keymaps AgentEngineKeymaps

local defaults = {
  -- Known agent CLIs. Discovery checks PATH; only installed ones are offered.
  providers = {
    {
      id = "cursor",
      label = "Cursor Agent",
      binaries = { "agent", "cursor-agent", "cursor" },
      dialect = "cursor",
    },
    {
      id = "copilot",
      label = "GitHub Copilot",
      binaries = { "copilot" },
      dialect = "copilot",
    },
    {
      id = "claude",
      label = "Claude Code",
      binaries = { "claude" },
      dialect = "claude",
    },
    {
      id = "codex",
      label = "OpenAI Codex",
      binaries = { "codex" },
      dialect = "codex",
    },
    {
      id = "gemini",
      label = "Gemini CLI",
      binaries = { "gemini" },
      dialect = "gemini",
    },
    {
      id = "aider",
      label = "Aider",
      binaries = { "aider" },
      dialect = "aider",
    },
    {
      id = "goose",
      label = "Goose",
      binaries = { "goose" },
      dialect = "generic",
    },
    {
      id = "tgpt",
      label = "tgpt",
      binaries = { "tgpt" },
      dialect = "generic",
    },
  },
  -- Preferred provider id when several are installed (nil = first discovered).
  default_cli = nil,
  default_mode = "agent",
  default_model = "auto",
  models = {
    "auto",
    "composer-2.5",
    "composer-2.5-fast",
    "claude-sonnet-5-thinking-high",
    "claude-opus-5-thinking-high",
    "gpt-5.3-codex",
    "gpt-5.2",
    "gemini-3.7-flash-high",
    "cursor-grok-4.6-high-fast",
  },
  force = false,
  trust = true,
  chat_width = 72,
  chat_title = "Agent Chat",
  -- Spinner while the agent streams. Uses noice.nvim's cli-spinners when available
  -- (dots6, dots3, star, arc, …). Falls back to built-in braille animation.
  spinner_style = "dots6",
  -- Throttle live stream preview redraws (ms). Lower = smoother but heavier.
  stream_ui_interval_ms = 33,
  -- Coalesce agent CLI stdout chunks before parsing (ms).
  stream_chunk_interval_ms = 16,
  -- Archive closed chats to disk and browse via :AgentHistory / /history.
  history_enabled = true,
  max_history_sessions = 200,
  -- "ghost" = inline old/new overlays with per-hunk accept (Cursor-like).
  -- "diffsplit" = classic vertical diffsplit for the whole file.
  review_style = "ghost",
  -- Suppress Neovim's "file changed on disk, load?" prompts. External agent
  -- edits are owned by ghost review instead of autoread/W12 dialogs.
  suppress_reload_prompt = true,
  -- Do not persist/restore transcripts or Cursor chat ids across Neovim restarts.
  -- Each "new chat" is a fresh local transcript + fresh remote chat on first send.
  -- Set true (and optionally max_persisted_messages) to restore recent history.
  persist_transcript = false,
  max_persisted_messages = 0,
  -- MCP: uses ~/.cursor/mcp.json (and project .cursor/mcp.json). Manage with /mcp or :AgentMcp.
  mcp = {
    auto_approve = false,
    config_paths = nil,
  },
  -- Cursor agent plugins: directories passed as --plugin-dir on each run.
  plugins = {
    dirs = {},
  },
  -- Lua extension modules (return a table with .id and hook callbacks).
  extensions = {},
  -- Headroom (https://github.com/headroomlabs-ai/headroom): pip / uv tool install headroom-ai[all]
  headroom = {
    enabled = false,
    mode = "proxy",
    command = "headroom",
    proxy_port = 8787,
    proxy_url = nil,
    proxy_args = nil,
    proxy_env = nil,
    auto_start_proxy = true,
    wrap_tool = nil,
    wrap_args = nil,
    mcp_args = { "mcp", "serve" },
    mcp_auto_install = false,
    library_python = "python3",
    min_chars = 800,
    timeout_ms = 120000,
    fallback_on_error = true,
    output_shaper = false,
    env = nil,
  },
  -- Integration debug log: stderr (terminal) + ~/.cache/nvim/agent_engine-integrations.log
  -- View in Neovim: :AgentIntegrationsLog · shell: tail -f ~/.cache/nvim/agent_engine-integrations.log
  integrations_log = {
    enabled = false,
    console = true,
    file = true,
    notify = false,
    debug = true,
    file_path = nil,
  },
  keymaps = {
    toggle_chat = "<leader>Cc", -- Space C c  (avoid bare `a` = append, and LazyVim <leader>a AI)
    new_agent = "<leader>Cn",
    next_agent = "<leader>C]",
    prev_agent = "<leader>C[",
    send = "<leader>Cs",
    add_selection = "<leader>Cr",
    cycle_mode = "<leader>Cm",
    pick_mode = "<leader>CM",
    pick_model = "<leader>Co",
    pick_cli = "<leader>Ci",
    cycle_cli = "<leader>CI",
    accept_change = "<leader>va", -- accept current hunk → jump next
    reject_change = "<leader>vr", -- reject current hunk → jump next
    accept_all = "<leader>vA", -- accept every remaining hunk in file → next file
    reject_all = "<leader>vR", -- reject every remaining hunk in file → next file
    next_hunk = "]h",
    prev_hunk = "[h",
    next_pending_file = "<leader>vn", -- jump to next file with pending agent edits
    cancel_job = "<leader>Cx",
    focus_chat = "<leader>Cf",
    attach_file = "<leader>Ca",
    clear_pending = "<leader>CR",
    pick_history = "<leader>Ch",
  },
}

---@type AgentEngineConfig
M.values = vim.deepcopy(defaults)

--- Merge user options into the active config.
---@param opts AgentEngineConfig|nil
function M.setup(opts)
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  -- Back-compat: plain `binaries = {...}` becomes an extra generic provider.
  if opts and type(opts.binaries) == "table" and #opts.binaries > 0 then
    table.insert(M.values.providers, {
      id = "custom",
      label = "Custom",
      binaries = opts.binaries,
      dialect = "generic",
    })
  end
end

---@return AgentEngineConfig
function M.get()
  return M.values
end

return M
