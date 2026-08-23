-- File: lua/agent_engine/session.lua
-- Multi-agent session state: cli, mode, model, chat id, references, transcript.
-- Each session is an independent chat that can run an agent in parallel.

local agent = require("agent_engine.agent")
local config = require("agent_engine.config")
local storage = require("agent_engine.storage")

local M = {}

---@class AgentEngineReference
---@field file string
---@field start_line integer
---@field end_line integer
---@field text string

---@class AgentEngineAttachment
---@field path string absolute filesystem path
---@field kind "image"|"file"

---@class AgentEngineSession
---@field id string
---@field title string
---@field cli string|nil provider id
---@field mode "agent"|"plan"|"ask"
---@field model string
---@field chat_id string|nil Cursor remote chat id (--resume); nil = fresh chat
---@field references AgentEngineReference[]
---@field attachments AgentEngineAttachment[]
---@field prompt_queue string[] pending prompts while agent runs (not persisted)
---@field draft string in-progress prompt text (not persisted across restarts)
---@field draft_cursor integer[]|nil last cursor {row, col} in the prompt bar
---@field messages { role: string, text: string }[]
---@field created_at number
---@field updated_at number

---@class AgentEngineHistoryEntry
---@field id string
---@field title string
---@field cli string|nil
---@field mode "agent"|"plan"|"ask"
---@field model string
---@field chat_id string|nil
---@field messages { role: string, text: string }[]
---@field created_at number
---@field updated_at number
---@field archived_at number

---@type AgentEngineSession[]
M.sessions = {}

---@type integer
M.active_index = 1

local MODES = { "agent", "plan", "ask" }

local DAY_MS = 24 * 60 * 60 * 1000

local HISTORY_GROUP_ORDER = {
  "Today",
  "Yesterday",
  "Previous 7 days",
  "Previous 30 days",
  "Older",
}

local function now()
  return vim.uv.now()
end

---@param ts number milliseconds since epoch
---@return number start of local calendar day in ms
local function start_of_day(ts)
  local t = os.date("*t", math.floor(ts / 1000))
  t.hour = 0
  t.min = 0
  t.sec = 0
  return os.time(t) * 1000
end

---@return boolean
local function history_enabled()
  return config.get().history_enabled ~= false
end

---@return integer
local function max_history_sessions()
  local n = config.get().max_history_sessions
  if type(n) == "number" and n > 0 then
    return math.floor(n)
  end
  return 200
end

---@param ts number|nil
---@return string
function M.format_relative_time(ts)
  if type(ts) ~= "number" or ts <= 0 then
    return ""
  end
  local diff = math.max(0, now() - ts)
  if diff < 60 * 1000 then
    return "just now"
  end
  if diff < 60 * 60 * 1000 then
    return string.format("%dm ago", math.floor(diff / (60 * 1000)))
  end
  if diff < DAY_MS then
    return string.format("%dh ago", math.floor(diff / (60 * 60 * 1000)))
  end
  if diff < 7 * DAY_MS then
    return string.format("%dd ago", math.floor(diff / DAY_MS))
  end
  return os.date("%Y-%m-%d", math.floor(ts / 1000))
end

---@param entry AgentEngineHistoryEntry|AgentEngineSession
---@return string
local function history_group_label(entry)
  local ts = entry.updated_at or entry.archived_at or entry.created_at or now()
  local today = start_of_day(now())
  local day = start_of_day(ts)
  if day >= today then
    return "Today"
  end
  if day >= today - DAY_MS then
    return "Yesterday"
  end
  if day >= today - 7 * DAY_MS then
    return "Previous 7 days"
  end
  if day >= today - 30 * DAY_MS then
    return "Previous 30 days"
  end
  return "Older"
end

---@param s AgentEngineSession
---@return AgentEngineHistoryEntry
local function session_to_history(s)
  return {
    id = s.id,
    title = s.title,
    cli = s.cli,
    mode = s.mode,
    model = s.model,
    chat_id = s.chat_id,
    messages = vim.deepcopy(s.messages),
    created_at = s.created_at,
    updated_at = s.updated_at or s.created_at,
    archived_at = now(),
  }
end

---@return integer
local function max_persisted_messages()
  local cfg = config.get()
  if cfg.persist_transcript == false then
    return 0
  end
  local n = cfg.max_persisted_messages
  if type(n) == "number" and n >= 0 then
    return math.floor(n)
  end
  return 20
end

local function persist()
  local keep = max_persisted_messages()
  local payload = {
    active_index = M.active_index,
    sessions = {},
  }
  for _, s in ipairs(M.sessions) do
    local messages = {}
    if keep > 0 and type(s.messages) == "table" and #s.messages > 0 then
      messages = vim.list_slice(s.messages, math.max(1, #s.messages - keep))
    end
    table.insert(payload.sessions, {
      id = s.id,
      title = s.title,
      cli = s.cli,
      mode = s.mode,
      model = s.model,
      -- Intentionally do NOT persist chat_id by default across restarts when
      -- persist_transcript is false — avoids silently resuming huge remote chats.
      chat_id = (keep > 0) and s.chat_id or nil,
      created_at = s.created_at,
      updated_at = s.updated_at or s.created_at,
      messages = messages,
    })
  end
  storage.save_sessions(payload)
end

local function default_cli_id()
  local cli = agent.resolve_cli(config.get().default_cli)
  return cli and cli.id or nil
end

-- Create chat id lazily on first send — never block Neovim startup on the network.
---@param s AgentEngineSession
local function ensure_chat_id(s)
  if s.chat_id and s.chat_id ~= "" then
    return s.chat_id
  end
  local cli = agent.resolve_cli(s.cli)
  if not cli or cli.dialect ~= "cursor" then
    return nil
  end
  agent.set_cli(cli.id)
  local cid, err = agent.create_chat()
  if cid then
    s.chat_id = cid
    persist()
    return cid
  end
  if err then
    vim.notify("agent_engine: " .. err, vim.log.levels.WARN)
  end
  return nil
end

---@param title string|nil
---@param inherit_from AgentEngineSession|nil
---@return AgentEngineSession
local function make_session(title, inherit_from)
  local cfg = config.get()
  local id = string.format("%s-%s", tostring(now()), tostring(math.random(1000, 9999)))
  local n = #M.sessions + 1
  local base = inherit_from or {}

  return {
    id = id,
    title = title or ("Chat " .. tostring(n)),
    cli = base.cli or default_cli_id(),
    mode = base.mode or cfg.default_mode or "agent",
    model = base.model or cfg.default_model or "auto",
    chat_id = nil, -- fresh remote chat; never inherit another session's id
    references = {},
    attachments = {},
    prompt_queue = {},
    draft = "",
    draft_cursor = nil,
    messages = {}, -- fresh local transcript
    created_at = now(),
    updated_at = now(),
  }
end

function M.load()
  local data = storage.load_sessions()
  M.sessions = {}
  local keep = max_persisted_messages()

  if data and type(data.sessions) == "table" and #data.sessions > 0 then
    for i, raw in ipairs(data.sessions) do
      if type(raw) == "table" and type(raw.id) == "string" then
        local messages = {}
        if keep > 0 and type(raw.messages) == "table" then
          messages = raw.messages
        end
        table.insert(M.sessions, {
          id = raw.id,
          title = raw.title or ("Chat " .. tostring(i)),
          cli = raw.cli or default_cli_id(),
          mode = raw.mode or config.get().default_mode or "agent",
          model = raw.model or config.get().default_model or "auto",
          chat_id = (keep > 0) and raw.chat_id or nil,
          references = {},
          attachments = {},
          prompt_queue = {},
          draft = "",
          draft_cursor = nil,
          messages = messages,
          created_at = raw.created_at or now(),
          updated_at = raw.updated_at or raw.created_at or now(),
        })
      end
    end
    M.active_index = math.min(math.max(data.active_index or 1, 1), #M.sessions)
  end

  if #M.sessions == 0 then
    table.insert(M.sessions, make_session("Chat 1"))
    M.active_index = 1
    persist()
  end

  local s = M.sessions[M.active_index]
  if s and s.cli then
    agent.set_cli(s.cli)
  end
end

---@param session_id string|nil
---@return AgentEngineSession|nil
function M.get_by_id(session_id)
  if type(session_id) ~= "string" or session_id == "" then
    return nil
  end
  for _, s in ipairs(M.sessions) do
    if s.id == session_id then
      return s
    end
  end
  return nil
end

---@return AgentEngineSession
function M.current()
  if #M.sessions == 0 then
    M.load()
  end
  local s = M.sessions[M.active_index]
  if not s then
    M.active_index = 1
    s = M.sessions[1]
  end
  return s
end

--- Open a brand-new chat (empty transcript, new Cursor chat id on first send).
---@param title string|nil
---@return AgentEngineSession
function M.new(title)
  local inherit = (#M.sessions > 0) and M.current() or nil
  local s = make_session(title, inherit)
  table.insert(M.sessions, s)
  M.active_index = #M.sessions
  if s.cli then
    agent.set_cli(s.cli)
  end
  persist()
  return s
end

--- Archive a session transcript into chat history (when closing a tab, etc.).
---@param s AgentEngineSession|nil
---@return boolean
function M.archive_session(s)
  if not history_enabled() then
    return false
  end
  s = s or M.current()
  if not s or type(s.messages) ~= "table" or #s.messages == 0 then
    return false
  end
  return storage.append_history(session_to_history(s), max_history_sessions())
end

---@return AgentEngineHistoryEntry[]
function M.list_history()
  return storage.load_history()
end

---@return { label: string, entries: AgentEngineHistoryEntry[] }[]
function M.history_groups()
  local grouped = {}
  for _, label in ipairs(HISTORY_GROUP_ORDER) do
    grouped[label] = {}
  end
  for _, entry in ipairs(storage.load_history()) do
    if type(entry) == "table" then
      local label = history_group_label(entry)
      if not grouped[label] then
        grouped[label] = {}
      end
      table.insert(grouped[label], entry)
    end
  end
  for _, entries in pairs(grouped) do
    table.sort(entries, function(a, b)
      local ta = a.updated_at or a.archived_at or a.created_at or 0
      local tb = b.updated_at or b.archived_at or b.created_at or 0
      return ta > tb
    end)
  end
  local out = {}
  for _, label in ipairs(HISTORY_GROUP_ORDER) do
    if #grouped[label] > 0 then
      table.insert(out, { label = label, entries = grouped[label] })
    end
  end
  return out
end

--- Restore an archived chat as a new active session tab.
---@param history_id string
---@return AgentEngineSession|nil
function M.restore_history(history_id)
  if type(history_id) ~= "string" or history_id == "" then
    return nil
  end
  local entry = nil
  for _, e in ipairs(storage.load_history()) do
    if e.id == history_id then
      entry = e
      break
    end
  end
  if not entry then
    return nil
  end

  local s = make_session(entry.title)
  s.messages = vim.deepcopy(entry.messages or {})
  s.cli = entry.cli or s.cli
  s.mode = entry.mode or s.mode
  s.model = entry.model or s.model
  s.chat_id = entry.chat_id
  s.created_at = entry.created_at or s.created_at
  s.updated_at = entry.updated_at or entry.archived_at or s.updated_at

  table.insert(M.sessions, s)
  M.active_index = #M.sessions
  if s.cli then
    agent.set_cli(s.cli)
  end
  persist()
  return s
end

---@param history_id string
---@return boolean
function M.delete_history(history_id)
  return storage.remove_history(history_id)
end

--- Close a session by index (defaults to active). Does not cancel other agents.
---@param index integer|nil
---@return AgentEngineSession active
function M.close(index)
  index = index or M.active_index
  if #M.sessions <= 1 then
    -- Keep one empty chat instead of wiping everything.
    local s = M.sessions[1]
    if s then
      M.archive_session(s)
      agent.cancel(s.id)
      s.messages = {}
      s.chat_id = nil
      s.references = {}
      s.attachments = {}
      s.prompt_queue = {}
      s.title = "Chat 1"
      persist()
    end
    return M.current()
  end

  if index < 1 or index > #M.sessions then
    return M.current()
  end

  local closing = M.sessions[index]
  if closing then
    M.archive_session(closing)
    agent.cancel(closing.id)
  end
  table.remove(M.sessions, index)
  if M.active_index > #M.sessions then
    M.active_index = #M.sessions
  elseif M.active_index > index then
    M.active_index = M.active_index - 1
  end
  local s = M.current()
  if s.cli then
    agent.set_cli(s.cli)
  end
  persist()
  return s
end

---@param delta integer
---@return AgentEngineSession
function M.cycle(delta)
  if #M.sessions == 0 then
    return M.new()
  end
  local idx = M.active_index + (delta or 1)
  if idx < 1 then
    idx = #M.sessions
  elseif idx > #M.sessions then
    idx = 1
  end
  M.active_index = idx
  local s = M.current()
  if s.cli then
    agent.set_cli(s.cli)
  end
  persist()
  return s
end

---@param index integer
---@return AgentEngineSession|nil
function M.focus(index)
  if type(index) ~= "number" or index < 1 or index > #M.sessions then
    return nil
  end
  M.active_index = index
  local s = M.current()
  if s.cli then
    agent.set_cli(s.cli)
  end
  persist()
  return s
end

---@param mode string
function M.set_mode(mode)
  if mode ~= "agent" and mode ~= "plan" and mode ~= "ask" then
    vim.notify("Invalid mode: " .. tostring(mode), vim.log.levels.WARN)
    return
  end
  local s = M.current()
  s.mode = mode
  persist()
end

function M.cycle_mode()
  local s = M.current()
  local idx = 1
  for i, m in ipairs(MODES) do
    if m == s.mode then
      idx = i
      break
    end
  end
  local next_mode = MODES[(idx % #MODES) + 1]
  s.mode = next_mode
  persist()
  return next_mode
end

---@param model string
function M.set_model(model)
  if type(model) ~= "string" or model == "" then
    return
  end
  local s = M.current()
  s.model = model
  persist()
end

---@param cli_id string
---@return boolean ok
function M.set_cli(cli_id)
  local entry, err = agent.set_cli(cli_id)
  if not entry then
    vim.notify(err or ("Unknown CLI: " .. tostring(cli_id)), vim.log.levels.WARN)
    return false
  end
  local s = M.current()
  local prev = s.cli
  s.cli = entry.id
  if prev and prev ~= entry.id then
    s.chat_id = nil
  end
  persist()
  return true
end

---@return AgentEngineDiscoveredCli|nil
function M.cycle_cli()
  local next_cli = agent.cycle_cli()
  if not next_cli then
    vim.notify("No agent CLIs found on PATH", vim.log.levels.WARN)
    return nil
  end
  local s = M.current()
  if s.cli ~= next_cli.id then
    s.chat_id = nil
  end
  s.cli = next_cli.id
  persist()
  return next_cli
end

---@param ref AgentEngineReference
function M.add_reference(ref)
  if type(ref) ~= "table" or type(ref.file) ~= "string" then
    return
  end
  local s = M.current()
  table.insert(s.references, ref)
end

function M.clear_references()
  M.current().references = {}
end

--- Remove one pending code selection by 1-based index.
---@param index integer
---@return boolean
function M.remove_reference(index)
  if type(index) ~= "number" then
    return false
  end
  local s = M.current()
  if index < 1 or index > #s.references then
    return false
  end
  table.remove(s.references, index)
  return true
end

function M.clear_attachments()
  M.current().attachments = {}
end

--- Clear pending code references and file attachments (not sent with next prompt).
function M.clear_pending()
  local s = M.current()
  s.references = {}
  s.attachments = {}
end

local IMAGE_EXTENSIONS = {
  png = true,
  jpg = true,
  jpeg = true,
  gif = true,
  webp = true,
  bmp = true,
  svg = true,
  heic = true,
  heif = true,
}

---@param path string
---@return "image"|"file"
local function attachment_kind(path)
  local ext = vim.fn.fnamemodify(path, ":e"):lower()
  if IMAGE_EXTENSIONS[ext] then
    return "image"
  end
  return "file"
end

---@param path string
---@return boolean ok
function M.add_attachment(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("File not readable: " .. path, vim.log.levels.WARN)
    return false
  end
  local s = M.current()
  for _, att in ipairs(s.attachments) do
    if att.path == path then
      return true
    end
  end
  table.insert(s.attachments, { path = path, kind = attachment_kind(path) })
  return true
end

function M.remove_attachment(path)
  if type(path) ~= "string" or path == "" then
    return
  end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local s = M.current()
  for i, att in ipairs(s.attachments) do
    if att.path == path then
      table.remove(s.attachments, i)
      return
    end
  end
end

--- Format pending file attachments for the CLI prompt, then clear them.
---@param session_id string|nil
---@return string
function M.consume_attachments_block(session_id)
  local s = session_id and M.get_by_id(session_id) or M.current()
  if not s or #s.attachments == 0 then
    return ""
  end

  local parts = { "Attached files:" }
  for _, att in ipairs(s.attachments) do
    table.insert(parts, "@" .. att.path)
  end
  table.insert(parts, "")
  s.attachments = {}
  return table.concat(parts, "\n")
end

--- Queue a prompt for this session when the agent is already running.
---@param text string
---@param session_id string|nil
---@return integer queue_len
function M.queue_prompt(text, session_id)
  if type(text) ~= "string" or vim.trim(text) == "" then
    return 0
  end
  local s = session_id and M.get_by_id(session_id) or M.current()
  if not s then
    return 0
  end
  table.insert(s.prompt_queue, vim.trim(text))
  return #s.prompt_queue
end

---@param session_id string|nil
---@return string|nil
function M.pop_queued_prompt(session_id)
  local s = session_id and M.get_by_id(session_id) or M.current()
  if not s or #s.prompt_queue == 0 then
    return nil
  end
  return table.remove(s.prompt_queue, 1)
end

---@param session_id string|nil
---@return integer
function M.queue_length(session_id)
  local s = session_id and M.get_by_id(session_id) or M.current()
  return s and #s.prompt_queue or 0
end

function M.clear_queue(session_id)
  local s = session_id and M.get_by_id(session_id) or M.current()
  if s then
    s.prompt_queue = {}
  end
end

--- Append a message to a specific session (defaults to active).
---@param role string
---@param text string
---@param session_id string|nil
function M.append_message(role, text, session_id)
  local s = session_id and M.get_by_id(session_id) or M.current()
  if not s then
    return
  end
  table.insert(s.messages, { role = role, text = text })
  s.updated_at = now()

  -- Auto-title from the first user prompt.
  if role == "user" and (s.title:match("^Chat %d+$") or s.title:match("^Agent")) then
    local title = vim.trim((text or ""):gsub("\n", " ")):sub(1, 32)
    if title ~= "" then
      s.title = title
    end
  end
  persist()
end

--- Clear local transcript AND start a fresh remote Cursor chat on next send.
function M.clear_messages()
  local s = M.current()
  s.messages = {}
  s.chat_id = nil
  s.references = {}
  s.attachments = {}
  s.prompt_queue = {}
  persist()
end

--- Format pending references into a prompt preamble, then clear them.
---@param session_id string|nil
---@return string
function M.consume_references_block(session_id)
  local s = session_id and M.get_by_id(session_id) or M.current()
  if not s or #s.references == 0 then
    return ""
  end

  local parts = { "Referenced context:" }
  for _, ref in ipairs(s.references) do
    local loc = string.format("@%s:%d-%d", ref.file, ref.start_line, ref.end_line)
    table.insert(parts, loc)
    table.insert(parts, "```")
    table.insert(parts, ref.text)
    table.insert(parts, "```")
  end
  table.insert(parts, "")
  s.references = {}
  return table.concat(parts, "\n")
end

--- Compact tab strip: [1:title●] [2:title] …
---@return string
function M.tabs_line()
  local parts = {}
  for i, s in ipairs(M.sessions) do
    local running = agent.is_running(s.id) and "●" or ""
    local mark = (i == M.active_index) and "*" or ""
    local title = (s.title or ("Chat " .. i)):gsub("%s+", " "):sub(1, 18)
    table.insert(parts, string.format("%s%d:%s%s", mark, i, title, running))
  end
  return table.concat(parts, " │ ")
end

---@return string
function M.status_line()
  local s = M.current()
  local cli = agent.resolve_cli(s.cli)
  local cli_label = cli and cli.id or (s.cli or "?")
  local running_n = agent.running_count and agent.running_count() or 0
  return string.format(
    "[%d/%d] %s | cli:%s | mode:%s | model:%s | sel:%d | att:%d%s%s%s",
    M.active_index,
    #M.sessions,
    s.title,
    cli_label,
    s.mode,
    s.model,
    #s.references,
    #s.attachments,
    #s.prompt_queue > 0 and (" | queued:" .. tostring(#s.prompt_queue)) or "",
    agent.is_running(s.id) and " | RUNNING" or "",
    running_n > 1 and (" | parallel:" .. tostring(running_n)) or ""
  )
end

M.MODES = MODES

---@param text string
---@param session_id string|nil
function M.set_draft(text, session_id)
  local s = session_id and M.get_by_id(session_id) or M.current()
  if not s then
    return
  end
  s.draft = type(text) == "string" and text or ""
end

---@param session_id string|nil
---@return string
function M.get_draft(session_id)
  local s = session_id and M.get_by_id(session_id) or M.current()
  if not s or type(s.draft) ~= "string" then
    return ""
  end
  return s.draft
end

---@param cursor integer[]|nil
---@param session_id string|nil
function M.set_draft_cursor(cursor, session_id)
  local s = session_id and M.get_by_id(session_id) or M.current()
  if not s then
    return
  end
  s.draft_cursor = cursor
end

---@param session_id string|nil
function M.clear_draft(session_id)
  local s = session_id and M.get_by_id(session_id) or M.current()
  if not s then
    return
  end
  s.draft = ""
  s.draft_cursor = nil
end

--- Ensure a session has a Cursor chat id (lazy). Defaults to active.
---@param session_id string|nil
---@return string|nil
function M.ensure_chat_id(session_id)
  local s = session_id and M.get_by_id(session_id) or M.current()
  if not s then
    return nil
  end
  return ensure_chat_id(s)
end

--- Drop a stale remote chat id (e.g. after auth failure).
---@param session_id string|nil
function M.clear_chat_id(session_id)
  local s = session_id and M.get_by_id(session_id) or M.current()
  if not s then
    return
  end
  s.chat_id = nil
  persist()
end

return M
