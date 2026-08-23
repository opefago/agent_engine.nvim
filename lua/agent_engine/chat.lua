-- File: lua/agent_engine/chat.lua
-- Locked chat panel: transcript above, sticky input bar below.
-- File-tree / buffer opens cannot steal the chat windows.

local agent = require("agent_engine.agent")
local config = require("agent_engine.config")
local mcp = require("agent_engine.mcp")
local plugins = require("agent_engine.plugins")
local session = require("agent_engine.session")
local spinner = require("agent_engine.spinner")

local M = {}

---@type integer|nil
M.bufnr = nil

---@type integer|nil
M.input_bufnr = nil

---@type integer|nil
M.winid = nil

---@type integer|nil
M.input_winid = nil

--- Last non-chat editor window (for neo-tree / picker file targets).
---@type integer|nil
M.last_editor_win = nil

local STREAM_NS = vim.api.nvim_create_namespace("AgentChatStream")
local CHROME_NS = vim.api.nvim_create_namespace("AgentChatChrome")
local protect_group = vim.api.nvim_create_augroup("AgentChatProtect", { clear = true })
local focus_group = vim.api.nvim_create_augroup("AgentChatFocus", { clear = true })
local scroll_group = vim.api.nvim_create_augroup("AgentChatScroll", { clear = true })
local draft_group = vim.api.nvim_create_augroup("AgentChatDraft", { clear = true })
local INPUT_HEIGHT = 9
local THINKING_MAX_LINES = 4
local QUEUE_PREVIEW_LEN = 52

---@type table<string, { timer: uv.uv_timer_t, frame: integer, acc: table }>
local stream_anim = {}

--- Pending stream preview payloads (coalesced before redraw).
---@type table<string, table>
local stream_ui_pending = {}

---@type table<string, uv.uv_timer_t>
local stream_ui_timers = {}

--- Skip full transcript rebuild when only the header (tabs/status) changed.
local render_cache = { session_id = "", body_fp = "" }

local markdown_streaming_disabled = false

--- Auto-scroll transcript while streaming unless the user scrolled up.
local scroll_follow = true
--- Ignore WinScrolled events caused by our own cursor moves.
local scroll_programmatic = false
local scroll_programmatic_until = 0
local scroll_bound_buf = nil

---@type integer|nil
local draft_bound_buf = nil
---@type uv.uv_timer_t|nil
local draft_timer = nil

---@return boolean
local function buf_ok(bufnr)
  return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
end

---@return boolean
local function win_ok(winid)
  return winid ~= nil and vim.api.nvim_win_is_valid(winid)
end

---@param session_id string|nil
local function persist_input_draft(session_id)
  if not buf_ok(M.input_bufnr) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(M.input_bufnr, 0, -1, false)
  session.set_draft(table.concat(lines, "\n"), session_id)
  if win_ok(M.input_winid) and vim.api.nvim_get_current_win() == M.input_winid then
    session.set_draft_cursor({ unpack(vim.api.nvim_win_get_cursor(M.input_winid)) }, session_id)
  end
end

---@param session_id string|nil
local function apply_input_draft(session_id)
  if not buf_ok(M.input_bufnr) then
    return
  end
  local draft = session.get_draft(session_id)
  local lines = draft == "" and { "" } or vim.split(draft, "\n", { plain = true })
  local current = vim.api.nvim_buf_get_lines(M.input_bufnr, 0, -1, false)
  if table.concat(current, "\n") == draft then
    return
  end
  vim.bo[M.input_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M.input_bufnr, 0, -1, false, lines)
  local s = session_id and session.get_by_id(session_id) or session.current()
  if s and s.draft_cursor and win_ok(M.input_winid) then
    pcall(vim.api.nvim_win_set_cursor, M.input_winid, s.draft_cursor)
  end
end

---@param bufnr integer
local function bind_input_draft_autocmd(bufnr)
  if not buf_ok(bufnr) or draft_bound_buf == bufnr then
    return
  end
  draft_bound_buf = bufnr
  pcall(vim.api.nvim_clear_autocmds, { group = draft_group, buffer = bufnr })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = draft_group,
    buffer = bufnr,
    callback = function()
      if draft_timer then
        pcall(function()
          draft_timer:stop()
          draft_timer:close()
        end)
        draft_timer = nil
      end
      local timer = vim.uv.new_timer()
      if not timer then
        persist_input_draft()
        return
      end
      draft_timer = timer
      timer:start(50, 0, function()
        pcall(function()
          timer:close()
        end)
        draft_timer = nil
        vim.schedule(function()
          if buf_ok(bufnr) then
            persist_input_draft()
          end
        end)
      end)
    end,
  })
end

---@param winid integer
local function transcript_near_bottom(winid)
  if not win_ok(winid) or not buf_ok(M.bufnr) then
    return true
  end
  local last = vim.api.nvim_buf_line_count(M.bufnr)
  if last <= 1 then
    return true
  end
  local top = vim.fn.line("w0", winid)
  local bottom = vim.fn.line("w$", winid)
  return bottom >= last - 2 or (bottom >= last - 1 and top >= last - 10)
end

--- Stick transcript view to the latest content.
---@param force boolean|nil
local function scroll_transcript_bottom(force)
  if not win_ok(M.winid) or not buf_ok(M.bufnr) then
    return
  end
  if not force and not scroll_follow then
    return
  end
  local last = vim.api.nvim_buf_line_count(M.bufnr)
  scroll_programmatic = true
  scroll_programmatic_until = vim.uv.now() + 200
  pcall(vim.api.nvim_win_set_cursor, M.winid, { math.max(1, last), 0 })
  vim.defer_fn(function()
    scroll_programmatic = false
  end, 200)
end

---@param enabled boolean
local function set_transcript_markdown(enabled)
  if not buf_ok(M.bufnr) then
    return
  end
  local ok, api = pcall(require, "render-markdown.api")
  if not ok then
    return
  end
  if enabled then
    if markdown_streaming_disabled then
      pcall(api.buf_enable, M.bufnr)
      markdown_streaming_disabled = false
    end
  elseif not markdown_streaming_disabled then
    pcall(api.buf_disable, M.bufnr)
    markdown_streaming_disabled = true
  end
end

local function append_streaming_header()
  if not buf_ok(M.bufnr) then
    return
  end
  vim.bo[M.bufnr].modifiable = true
  local lines = vim.api.nvim_buf_get_lines(M.bufnr, 0, -1, false)
  local tail = lines[#lines] or ""
  if tail ~= "" then
    table.insert(lines, "")
  end
  if lines[#lines] ~= "### Agent" then
    table.insert(lines, "### Agent")
    table.insert(lines, "")
  end
  vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, lines)
  vim.bo[M.bufnr].modifiable = false
  scroll_follow = true
  scroll_transcript_bottom(true)
  set_transcript_markdown(false)
end

local function bind_transcript_scroll_follow()
  if not buf_ok(M.bufnr) then
    return
  end
  if scroll_bound_buf == M.bufnr then
    return
  end
  scroll_bound_buf = M.bufnr
  pcall(vim.api.nvim_clear_autocmds, { group = scroll_group, buffer = M.bufnr })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = scroll_group,
    buffer = M.bufnr,
    callback = function()
      if scroll_programmatic or vim.uv.now() < scroll_programmatic_until then
        return
      end
      if win_ok(M.winid) and vim.api.nvim_win_get_buf(M.winid) == M.bufnr then
        scroll_follow = transcript_near_bottom(M.winid)
      end
    end,
  })
end

-- Forward decls (used by render before the stream helpers are assigned).
local sanitize_user_facing
local handle_stream_event
local apply_stream_chunk
local finalize_reply
local refresh_input_chrome
local try_slash_command
local render_stream_preview
local restore_stream_preview_if_running

---@param text string
---@param max_len integer
---@return string
local function preview_one_line(text, max_len)
  if type(text) ~= "string" then
    return ""
  end
  local one = vim.trim(text:gsub("\n", " "))
  if #one > max_len then
    return one:sub(1, max_len) .. "…"
  end
  return one
end

---@param s AgentEngineSession
---@return string[][]
local function queue_virt_lines(s)
  if #s.prompt_queue == 0 then
    return {}
  end
  local out = {
    {
      { "⏳ Queued (" .. tostring(#s.prompt_queue) .. ") — runs after current reply", "WarningMsg" },
    },
  }
  for i, q in ipairs(s.prompt_queue) do
    table.insert(out, {
      { "  " .. tostring(i) .. ". ", "Comment" },
      { preview_one_line(q, QUEUE_PREVIEW_LEN), "Special" },
    })
  end
  return out
end

---@param km AgentEngineKeymaps
---@return string[]
local function build_transcript_help(km)
  local lines = {
    "## Getting started",
    "",
    "Type in the **prompt bar below**, then send with `<C-s>`, `<CR>`, or `<C-CR>`.",
    "While the agent is working, you can send again — your message is **queued** and runs automatically.",
    "",
    "## Prompt bar keys",
    "",
    "| Key | What it does |",
    "| --- | --- |",
    "| `<C-s>` / `<CR>` | Send prompt (or run next queued message after the agent finishes) |",
    "| `m` / `M` | Pick or cycle agent mode (agent · plan · ask) |",
    "| `c` / `C` | Pick or cycle CLI backend |",
    "| `o` | Pick model |",
    "| `a` | Attach current file (images need a vision-capable model) |",
    "| `r` / `R` | Clear code selections / clear all pending |",
    "| Type `@` | File reference menu (filter as you type; Tab to accept) |",
    "| Type `/` | Slash command menu (see below) |",
    "| `n` | New parallel chat tab |",
    "| `d` | Close this chat tab |",
    "| `x` | Cancel running job and clear queue |",
    "| `]` / `[` | Next / previous chat tab |",
    "| `1`–`9` | Jump to chat tab by number |",
    "| `q` | Close the whole chat panel |",
    "",
    "## Global shortcuts (leader = Space)",
    "",
    string.format("| Key | What it does |"),
    "| --- | --- |",
    string.format("| `%s` | Toggle chat panel |", km.toggle_chat or "<leader>Cc"),
    string.format("| `%s` | Send / focus prompt |", km.send or "<leader>Cs"),
    string.format("| `%s` | New chat |", km.new_agent or "<leader>Cn"),
    string.format(
      "| `%s` / `%s` | Previous / next chat |",
      km.prev_agent or "<leader>C[",
      km.next_agent or "<leader>C]"
    ),
    string.format("| `%s` | Cycle mode |", km.cycle_mode or "<leader>Cm"),
    string.format("| `%s` | Pick model |", km.pick_model or "<leader>Co"),
    string.format("| `%s` | Pick CLI |", km.pick_cli or "<leader>Ci"),
    string.format("| `%s` | Attach file |", km.attach_file or "<leader>Ca"),
    string.format("| `%s` | Cancel job |", km.cancel_job or "<leader>Cx"),
    string.format("| `%s` | Add selection as @reference |", km.add_selection or "<leader>Cr"),
    string.format("| `%s` | Clear pending selections & attachments |", km.clear_pending or "<leader>CR"),
    string.format("| `%s` | Browse chat history |", km.pick_history or "<leader>Ch"),
    "",
    "## Slash commands (typed in the prompt)",
    "",
    "| Command | What it does |",
    "| --- | --- |",
    "| `/mode plan` | Switch mode (agent, plan, ask) |",
    "| `/cli cursor` | Switch CLI backend |",
    "| `/model auto` | Switch model |",
    "| `/attach path` | Attach a file for the next send |",
    "| `/selections clear` | Clear pending code selections (`<leader>Cr`) |",
    "| `/selections 2` | Remove code selection #2 |",
    "| `/attach clear` | Clear pending file attachments |",
    "| `/pending clear` | Clear selections, attachments, and `@` paths in prompt |",
    "| `/history` | Browse archived chats (Today, Yesterday, …) |",
    "| `/new` | New chat tab |",
    "| `/close` | Close this chat tab |",
    "| `/clear` | Clear transcript and remote session |",
    "| `/cancel` | Cancel job and clear queue |",
    "| `/queue` | Show queued prompt count |",
    "| `/queue clear` | Clear queued prompts |",
    "| `/mcp` | List MCP servers (Cursor CLI) |",
    "| `/mcp auto on` | Auto-approve MCP servers on each run |",
    "| `/plugin` | List Cursor plugin dirs and extensions |",
    "| `/headroom` | Headroom compression status (optional) |",
    "| `/help` | Show slash command summary |",
    "",
    "## Status indicators",
    "",
    "- `● RUNNING` — agent is working on this chat",
    "- `⏳ Queued (N)` — prompts waiting; shown under the prompt bar like Cursor",
    "- `●` on a tab — that chat still has a running job (parallel chats OK)",
    "",
    string.rep("-", 56),
    "",
  }
  return lines
end

---@return boolean
function M.is_chat_win(winid)
  return win_ok(winid) and (winid == M.winid or winid == M.input_winid)
end

---@return boolean
function M.is_chat_buf(bufnr)
  if not buf_ok(bufnr) then
    return false
  end
  if bufnr == M.bufnr or bufnr == M.input_bufnr then
    return true
  end
  local ft = vim.bo[bufnr].filetype
  if ft == "agentchat" or ft == "agentprompt" then
    return true
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if
    name:find("agent://", 1, true)
    or name:find("agent_engine://", 1, true)
    or name:find("cursor_engine://", 1, true)
  then
    return true
  end
  if name:match("AgentChat$") or name:match("AgentPrompt$") then
    return true
  end
  return false
end

---@param ft string
---@return boolean
local function is_special_nav_ft(ft)
  return ft == "neo-tree" or ft == "NvimTree" or ft == "oil" or ft == "agentchat" or ft == "agentprompt"
end

---@param winid integer
---@return boolean
local function is_editor_win(winid)
  if not win_ok(winid) or M.is_chat_win(winid) then
    return false
  end
  local b = vim.api.nvim_win_get_buf(winid)
  if M.is_chat_buf(b) then
    return false
  end
  local bt = vim.bo[b].buftype
  local ft = vim.bo[b].filetype
  return (bt == "" or bt == "acwrite") and not is_special_nav_ft(ft)
end

--- Prefer a non-chat, non-special editor window for opening files.
---@return integer|nil
function M.find_editor_win()
  if is_editor_win(M.last_editor_win) then
    return M.last_editor_win
  end

  local cur = vim.api.nvim_get_current_win()
  if is_editor_win(cur) then
    return cur
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_editor_win(win) then
      return win
    end
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not M.is_chat_win(win) then
      return win
    end
  end
  return nil
end

--- Open a file in an editor window, never inside the chat panel.
---@param filepath string
---@return integer|nil bufnr
function M.open_file_in_editor(filepath)
  if type(filepath) ~= "string" or filepath == "" then
    return nil
  end

  local target = M.find_editor_win()
  if not target then
    -- Create an editor split to the left of the chat column.
    if win_ok(M.winid) then
      vim.api.nvim_set_current_win(M.winid)
      vim.cmd("wincmd h")
      if M.is_chat_win(vim.api.nvim_get_current_win()) then
        vim.cmd("leftabove vsplit")
      end
      target = vim.api.nvim_get_current_win()
      if M.is_chat_win(target) then
        vim.cmd("topleft vsplit")
        target = vim.api.nvim_get_current_win()
      end
    else
      vim.cmd("topleft vsplit")
      target = vim.api.nvim_get_current_win()
    end
  end

  if not win_ok(target) or M.is_chat_win(target) then
    return nil
  end

  vim.api.nvim_set_current_win(target)
  local ok = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(filepath))
  if not ok then
    return nil
  end
  return vim.api.nvim_get_current_buf()
end

-- URI names avoid cwd-relative collisions ("AgentChat" → $PWD/AgentChat) that
-- cause E95 on :AgentReload when the prior scratch buffer is still alive.
local TRANSCRIPT_BUF_NAME = "agent://transcript"
local INPUT_BUF_NAME = "agent://prompt"
local LEGACY_TRANSCRIPT_NAMES = {
  "AgentChat",
  "cursor_engine://transcript",
  "agent_engine://transcript",
}
local LEGACY_INPUT_NAMES = {
  "AgentPrompt",
  "cursor_engine://prompt",
  "agent_engine://prompt",
}

---@param full string
---@param want string
---@return boolean
local function buf_name_matches(full, want)
  if full == want then
    return true
  end
  -- Legacy short names were expanded to $PWD/<name>.
  local tail = vim.fn.fnamemodify(full, ":t")
  return tail == want or full:sub(-#want) == want
end

---@param names string[]
---@return integer|nil
local function find_buf_by_names(names)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then
      local full = vim.api.nvim_buf_get_name(b)
      if full ~= "" then
        for _, name in ipairs(names) do
          if buf_name_matches(full, name) then
            return b
          end
        end
      end
    end
  end
  return nil
end

--- Reuse an existing named scratch buffer, or create one. Never raises E95.
---@param preferred string
---@param legacy string[]
---@return integer
local function acquire_named_scratch(preferred, legacy)
  local names = { preferred }
  for _, n in ipairs(legacy) do
    names[#names + 1] = n
  end

  local existing = find_buf_by_names(names)
  if existing then
    -- Migrate legacy short / old-scheme names to agent:// when possible.
    local cur = vim.api.nvim_buf_get_name(existing)
    if cur ~= preferred then
      pcall(vim.api.nvim_buf_set_name, existing, preferred)
    end
    return existing
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local ok = pcall(vim.api.nvim_buf_set_name, buf, preferred)
  if ok then
    return buf
  end

  -- Name taken between find and set_name: drop the orphan and adopt the other.
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  existing = find_buf_by_names(names)
  if existing then
    return existing
  end

  -- Last resort: unique URI so the panel still opens.
  buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, preferred .. "/" .. tostring(buf))
  return buf
end

---@param bufnr integer
---@return integer|nil
local function find_win_for_buf(bufnr)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

local function ensure_transcript_buf()
  if buf_ok(M.bufnr) then
    vim.bo[M.bufnr].filetype = "agentchat"
    return M.bufnr
  end

  M.bufnr = acquire_named_scratch(TRANSCRIPT_BUF_NAME, LEGACY_TRANSCRIPT_NAMES)

  vim.bo[M.bufnr].buftype = "nofile"
  vim.bo[M.bufnr].bufhidden = "hide"
  vim.bo[M.bufnr].swapfile = false
  vim.bo[M.bufnr].modifiable = false
  vim.bo[M.bufnr].filetype = "agentchat"
  vim.bo[M.bufnr].buflisted = false
  return M.bufnr
end

local function ensure_input_buf()
  if buf_ok(M.input_bufnr) then
    vim.bo[M.input_bufnr].filetype = "agentprompt"
    return M.input_bufnr
  end

  local preexisting = find_buf_by_names({
    INPUT_BUF_NAME,
    "AgentPrompt",
    "cursor_engine://prompt",
    "agent_engine://prompt",
  })
  M.input_bufnr = acquire_named_scratch(INPUT_BUF_NAME, LEGACY_INPUT_NAMES)
  if not preexisting then
    vim.api.nvim_buf_set_lines(M.input_bufnr, 0, -1, false, { "" })
  end

  vim.bo[M.input_bufnr].buftype = "nofile"
  vim.bo[M.input_bufnr].bufhidden = "hide"
  vim.bo[M.input_bufnr].swapfile = false
  vim.bo[M.input_bufnr].modifiable = true
  vim.bo[M.input_bufnr].filetype = "agentprompt"
  vim.bo[M.input_bufnr].buflisted = false
  pcall(require("agent_engine.prompt_complete").setup_input, M.input_bufnr)
  bind_input_draft_autocmd(M.input_bufnr)
  apply_input_draft()
  return M.input_bufnr
end

local function define_stream_highlights()
  vim.api.nvim_set_hl(0, "AgentEngineThinking", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "AgentEngineThinkingLabel", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "AgentEngineStream", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "AgentEngineSpinner", { default = true, link = "Special" })
end

---@param session_id string|nil
local function stop_stream_anim(session_id)
  if not session_id then
    return
  end
  if stream_ui_timers[session_id] then
    pcall(function()
      stream_ui_timers[session_id]:stop()
      stream_ui_timers[session_id]:close()
    end)
    stream_ui_timers[session_id] = nil
  end
  stream_ui_pending[session_id] = nil

  local st = stream_anim[session_id]
  if not st then
    return
  end
  if st.timer then
    pcall(function()
      st.timer:stop()
      st.timer:close()
    end)
  end
  stream_anim[session_id] = nil
end

---@return integer
local function stream_ui_interval_ms()
  local ms = config.get().stream_ui_interval_ms
  if type(ms) ~= "number" or ms < 0 then
    return 33
  end
  return ms
end

---@param sid string
local function flush_stream_preview(sid)
  local acc = stream_ui_pending[sid]
  stream_ui_pending[sid] = nil
  if not acc or not buf_ok(M.bufnr) then
    return
  end
  if acc.session_id and session.current().id ~= acc.session_id then
    return
  end
  local st = stream_anim[sid]
  render_stream_preview(acc, st and st.frame or 1, { streaming = true })
end

---@param acc table
local function schedule_stream_preview(acc)
  local sid = acc.session_id
  if not sid then
    return
  end
  stream_ui_pending[sid] = acc
  if stream_ui_timers[sid] then
    return
  end
  local interval = stream_ui_interval_ms()
  if interval == 0 then
    flush_stream_preview(sid)
    return
  end
  local timer = vim.uv.new_timer()
  if not timer then
    flush_stream_preview(sid)
    return
  end
  stream_ui_timers[sid] = timer
  timer:start(interval, 0, function()
    vim.schedule(function()
      if stream_ui_timers[sid] == timer then
        stream_ui_timers[sid] = nil
      end
      pcall(function()
        timer:close()
      end)
      flush_stream_preview(sid)
    end)
  end)
end

---@param s AgentEngineSession
---@return string
local function body_fingerprint(s)
  local parts = {
    s.id,
    tostring(#s.messages),
    tostring(#s.references),
    tostring(#s.attachments),
    tostring(#s.prompt_queue),
  }
  for _, msg in ipairs(s.messages) do
    parts[#parts + 1] = (msg.role or "") .. ":" .. tostring(#(msg.text or ""))
  end
  return table.concat(parts, "\0")
end

---@param bufnr integer
---@param title string
local function patch_transcript_header(bufnr, title)
  local header = {
    "# " .. title,
    session.tabs_line(),
    session.status_line(),
  }
  vim.bo[bufnr].modifiable = true
  for i, line in ipairs(header) do
    vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { line })
  end
  vim.bo[bufnr].modifiable = false
end

---@return integer
local function stream_wrap_width()
  if win_ok(M.winid) then
    return math.max(24, vim.api.nvim_win_get_width(M.winid) - 6)
  end
  return math.max(24, (config.get().chat_width or 72) - 6)
end

---@param text string
---@param width integer
---@return string[]
local function wrap_text(text, width)
  if type(text) ~= "string" or text == "" then
    return {}
  end
  width = math.max(8, width)
  local wrapped = {}
  for paragraph in vim.gsplit(text, "\n", { plain = true, trimempty = false }) do
    local line = vim.trim(paragraph)
    if line == "" then
      if #wrapped > 0 and wrapped[#wrapped] ~= "" then
        table.insert(wrapped, "")
      end
    else
      while #line > width do
        local chunk = line:sub(1, width)
        local break_at = chunk:match(".*() ")
        if not break_at or break_at <= 1 then
          break_at = width
        end
        table.insert(wrapped, vim.trim(line:sub(1, break_at)))
        line = vim.trim(line:sub(break_at + 1))
      end
      if line ~= "" then
        table.insert(wrapped, line)
      end
    end
  end
  return wrapped
end

---@param lines string[]
---@param max_lines integer
---@return string[]
local function tail_lines(lines, max_lines)
  if #lines <= max_lines then
    return lines
  end
  local out = {}
  for i = #lines - max_lines + 1, #lines do
    table.insert(out, lines[i])
  end
  return out
end

---@param acc table
local function ensure_stream_anim(acc)
  local sid = acc.session_id
  if not sid or not agent.is_running(sid) then
    if sid then
      stop_stream_anim(sid)
    end
    return
  end

  local st = stream_anim[sid]
  if st then
    st.acc = acc
    return
  end

  local spec = spinner.get()
  local timer = vim.uv.new_timer()
  stream_anim[sid] = { timer = timer, frame = 1, acc = acc }
  timer:start(spec.interval, spec.interval, function()
    vim.schedule(function()
      local active = stream_anim[sid]
      if not active then
        return
      end
      local frames = spinner.get().frames
      active.frame = (active.frame % #frames) + 1
      render_stream_preview(active.acc, active.frame, { streaming = true, spinner_only = true })
    end)
  end)
end

restore_stream_preview_if_running = function(session_id)
  session_id = session_id or session.current().id
  if not agent.is_running(session_id) then
    return
  end
  local st = stream_anim[session_id]
  if not st or not st.acc then
    return
  end
  ensure_stream_anim(st.acc)
  if stream_ui_pending[session_id] then
    return
  end
  render_stream_preview(st.acc, st.frame or 1, { streaming = true, spinner_only = true })
end

local function configure_chat_win(winid, height)
  vim.wo[winid].wrap = true
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].winfixbuf = true
  vim.wo[winid].statusline = " "
  if height then
    pcall(vim.api.nvim_win_set_height, winid, height)
  end
end

---@return string, string, string
local function session_labels()
  local s = session.current()
  local cli = agent.resolve_cli(s.cli)
  local cli_label = cli and cli.id or (s.cli or "?")
  return cli_label, s.mode or "?", s.model or "?"
end

refresh_input_chrome = function()
  if not buf_ok(M.input_bufnr) then
    return
  end

  local cli_label, mode, model = session_labels()
  local km = config.get().keymaps
  local running = agent.is_running(session.current().id)
  local s = session.current()
  local att_line = ""
  if #s.references > 0 then
    att_line = att_line .. "  sel:" .. tostring(#s.references)
  end
  if #s.attachments > 0 then
    local names = {}
    for _, att in ipairs(s.attachments) do
      table.insert(names, vim.fn.fnamemodify(att.path, ":."))
    end
    att_line = att_line .. "  att:" .. table.concat(names, ", ")
  end

  local chrome_virt = {
    {
      { " ", "Comment" },
      { "cli:" .. cli_label, "Identifier" },
      { "  ", "Comment" },
      { "mode:" .. mode, "Type" },
      { "  ", "Comment" },
      { "model:" .. model, "String" },
      { running and "  ● RUNNING" or "", "WarningMsg" },
      { att_line, "Special" },
    },
    {
      {
        " Keys: <C-s> send · m mode · c cli · o model · a attach · r clear selections · n new · d close",
        "Comment",
      },
    },
    {
      {
        string.format(
          " Review: %s accept · %s reject · %s/%s all · %s next-file",
          km.accept_change or "<Space>va",
          km.reject_change or "<Space>vr",
          km.accept_all or "<Space>vA",
          km.reject_all or "<Space>vR",
          km.next_pending_file or "<Space>vn"
        ),
        "Comment",
      },
    },
  }

  for _, row in ipairs(queue_virt_lines(s)) do
    table.insert(chrome_virt, row)
  end

  vim.api.nvim_buf_clear_namespace(M.input_bufnr, CHROME_NS, 0, -1)
  vim.api.nvim_buf_set_extmark(M.input_bufnr, CHROME_NS, 0, 0, {
    virt_lines_above = true,
    virt_lines = chrome_virt,
  })

  local queue_badge = #s.prompt_queue > 0 and string.format(" %%#WarningMsg#⏳%d%%*", #s.prompt_queue) or ""
  if win_ok(M.input_winid) then
    vim.wo[M.input_winid].winbar = string.format(
      "%%#StatusLine# Agent Prompt %%* %%#Comment#│%%* %%#Identifier#%s%%* %%#Comment#│%%* %%#Type#%s%%* %%#Comment#│%%* %%#String#%s%%*%s",
      cli_label,
      mode,
      model,
      queue_badge
    )
  end
  if win_ok(M.winid) then
    local run_badge = running and " %%#WarningMsg#●%%*" or ""
    vim.wo[M.winid].winbar = string.format(
      "%%#StatusLine# Agent Chat %%* %%#Comment#│%%* %s %%#Comment#│%%* %s %%#Comment#│%%* %s%s%s",
      cli_label,
      mode,
      model,
      run_badge,
      queue_badge
    )
  end
end

--- Handle /mode /cli /model /new /clear slash commands typed in the prompt.
---@param text string
---@return boolean handled
try_slash_command = function(text)
  local cmd, arg = text:match("^/(%S+)%s*(.*)$")
  if not cmd then
    return false
  end
  cmd = cmd:lower()
  arg = vim.trim(arg or "")

  if plugins.try_slash_command(cmd, arg) then
    return true
  end

  if cmd == "mode" or cmd == "m" then
    if arg ~= "" then
      session.set_mode(arg)
      vim.notify("Mode: " .. arg, vim.log.levels.INFO)
      M.refresh()
    else
      M.pick_mode()
    end
    return true
  elseif cmd == "cli" or cmd == "i" then
    if arg ~= "" then
      if session.set_cli(arg) then
        vim.notify("CLI: " .. arg, vim.log.levels.INFO)
        M.refresh()
      end
    else
      M.pick_cli()
    end
    return true
  elseif cmd == "model" or cmd == "o" then
    if arg ~= "" then
      session.set_model(arg)
      vim.notify("Model: " .. arg, vim.log.levels.INFO)
      M.refresh()
    else
      M.pick_model()
    end
    return true
  elseif cmd == "new" or cmd == "n" then
    M.new_agent()
    return true
  elseif cmd == "close" or cmd == "d" then
    M.close_agent()
    return true
  elseif cmd == "clear" then
    M.clear_transcript()
    return true
  elseif cmd == "cancel" or cmd == "x" then
    M.cancel()
    return true
  elseif cmd == "attach" or cmd == "a" then
    if arg == "clear" then
      M.clear_pending_attachments()
    elseif arg ~= "" then
      M.add_file_attachment(arg)
    else
      M.pick_file_attachment()
    end
    return true
  elseif cmd == "refs" or cmd == "ref" or cmd == "selections" or cmd == "selection" or cmd == "sel" then
    if arg == "clear" then
      M.clear_pending_selections()
    elseif arg ~= "" and arg:match("^%d+$") then
      local idx = tonumber(arg)
      if idx and session.remove_reference(idx) then
        M.refresh()
        vim.notify(string.format("Removed code selection #%d", idx), vim.log.levels.INFO)
      else
        vim.notify("No code selection at index " .. tostring(arg), vim.log.levels.WARN)
      end
    else
      local s = session.current()
      if #s.references == 0 then
        vim.notify("No pending code selections — add with <leader>Cr", vim.log.levels.INFO)
      else
        local parts = { string.format("%d code selection(s):", #s.references) }
        for i, ref in ipairs(s.references) do
          table.insert(
            parts,
            string.format(
              "  %d. %s:%d-%d",
              i,
              vim.fn.fnamemodify(ref.file, ":."),
              ref.start_line,
              ref.end_line
            )
          )
        end
        table.insert(parts, "Use /selections clear or /selections N to remove")
        vim.notify(table.concat(parts, "\n"), vim.log.levels.INFO)
      end
    end
    return true
  elseif cmd == "pending" then
    if arg == "clear" then
      M.clear_pending()
    else
      local s = session.current()
      vim.notify(
        string.format(
          "Pending: %d code selection(s), %d attachment(s) — /pending clear to drop all",
          #s.references,
          #s.attachments
        ),
        vim.log.levels.INFO
      )
    end
    return true
  elseif cmd == "history" then
    if arg == "" then
      M.pick_history()
    else
      vim.notify("Use /history to browse archived chats", vim.log.levels.INFO)
    end
    return true
  elseif cmd == "queue" then
    if arg == "clear" then
      session.clear_queue()
      vim.notify("Prompt queue cleared", vim.log.levels.INFO)
      refresh_input_chrome()
    else
      local n = session.queue_length()
      vim.notify(string.format("%d prompt(s) queued", n), vim.log.levels.INFO)
    end
    return true
  elseif cmd == "mcp" then
    local sub, rest = arg:match("^(%S*)%s*(.*)$")
    sub = (sub or ""):lower()
    rest = vim.trim(rest or "")
    if sub == "" or sub == "list" then
      vim.notify(mcp.status_summary(), vim.log.levels.INFO)
    elseif sub == "auto" then
      if rest == "on" or rest == "true" then
        mcp.set_auto_approve(true)
        vim.notify("MCP auto-approve enabled", vim.log.levels.INFO)
      elseif rest == "off" or rest == "false" then
        mcp.set_auto_approve(false)
        vim.notify("MCP auto-approve disabled", vim.log.levels.INFO)
      elseif rest == "" then
        vim.notify("MCP auto-approve: " .. (mcp.auto_approve() and "on" or "off"), vim.log.levels.INFO)
      else
        vim.notify("Use /mcp auto on|off", vim.log.levels.WARN)
      end
    elseif sub == "enable" and rest ~= "" then
      local ok, err = mcp.enable(rest)
      vim.notify(ok and ("Enabled MCP: " .. rest) or err, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    elseif sub == "disable" and rest ~= "" then
      local ok, err = mcp.disable(rest)
      vim.notify(ok and ("Disabled MCP: " .. rest) or err, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    elseif sub == "login" and rest ~= "" then
      local ok, err = mcp.login(rest)
      vim.notify(ok and ("MCP login started for " .. rest) or err, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    elseif sub == "tools" and rest ~= "" then
      local ok, out = mcp.list_tools(rest)
      vim.notify(ok and out or out, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    else
      vim.notify(
        "MCP: /mcp list | /mcp auto on|off | /mcp enable ID | /mcp disable ID | /mcp login ID | /mcp tools ID",
        vim.log.levels.INFO
      )
    end
    return true
  elseif cmd == "plugin" or cmd == "plugins" then
    local sub, rest = arg:match("^(%S*)%s*(.*)$")
    sub = (sub or ""):lower()
    rest = vim.trim(rest or "")
    if sub == "" or sub == "list" then
      local lines = { plugins.status_summary() }
      for _, dir in ipairs(plugins.dirs()) do
        table.insert(lines, "  • " .. dir)
      end
      for _, ext in ipairs(plugins.list_extensions()) do
        table.insert(lines, "  • extension: " .. ext.id .. (ext.name and (" (" .. ext.name .. ")") or ""))
      end
      vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    elseif sub == "add" and rest ~= "" then
      local ok, err = plugins.add_dir(rest)
      vim.notify(ok and ("Added plugin dir: " .. rest) or err, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    elseif sub == "remove" and rest ~= "" then
      local ok = plugins.remove_dir(rest)
      vim.notify(
        ok and ("Removed plugin dir: " .. rest) or "Plugin dir not in runtime list: " .. rest,
        ok and vim.log.levels.INFO or vim.log.levels.WARN
      )
    else
      vim.notify("Plugin: /plugin list | /plugin add path | /plugin remove path", vim.log.levels.INFO)
    end
    return true
  elseif cmd == "help" or cmd == "h" then
    vim.notify(
      "Slash: /mcp /plugin /selections /attach /pending /history /mode /cli /model /new /close /clear /cancel /queue",
      vim.log.levels.INFO
    )
    return true
  end
  return false
end

local function bind_input_keys()
  local bufnr = M.input_bufnr
  if not buf_ok(bufnr) then
    return
  end

  local opts = { buffer = bufnr, silent = true, nowait = true, remap = false }

  local function map(modes, lhs, fn, desc)
    vim.keymap.set(modes, lhs, fn, vim.tbl_extend("force", opts, { desc = desc }))
  end

  map({ "n", "i" }, "<C-s>", function()
    M.send_from_input()
  end, "Send agent prompt")

  for _, lhs in ipairs({ "<CR>", "<C-m>" }) do
    map("n", lhs, function()
      M.send_from_input()
    end, "Send agent prompt")
  end

  map("i", "<C-CR>", function()
    M.send_from_input()
  end, "Send agent prompt")

  map("n", "m", function()
    M.pick_mode()
  end, "Pick agent mode")
  map("n", "M", function()
    M.cycle_mode()
  end, "Cycle agent mode")
  map("n", "c", function()
    M.pick_cli()
  end, "Pick agent CLI")
  map("n", "C", function()
    M.cycle_cli()
  end, "Cycle agent CLI")
  map("n", "o", function()
    M.pick_model()
  end, "Pick agent model")
  map("n", "n", function()
    M.new_agent()
  end, "New agent chat (parallel)")
  map("n", "d", function()
    M.close_agent()
  end, "Close current chat")
  map("n", "x", function()
    M.cancel()
  end, "Cancel agent job")
  map("n", "a", function()
    M.add_file_attachment()
  end, "Attach file to prompt")
  map("n", "r", function()
    M.clear_pending_selections()
  end, "Clear pending code selections")
  map("n", "R", function()
    M.clear_pending()
  end, "Clear all pending selections, attachments, and @paths")
  map("i", "<C-g>a", function()
    vim.cmd("stopinsert")
    M.add_file_attachment()
  end, "Attach file to prompt")
  map("n", "q", function()
    M.close()
  end, "Close agent chat panel")
  map("n", "]", function()
    M.next_agent()
  end, "Next chat")
  map("n", "[", function()
    M.prev_agent()
  end, "Prev chat")

  for i = 1, 9 do
    map("n", tostring(i), function()
      persist_input_draft()
      if session.focus(i) then
        M.open()
        apply_input_draft()
        M.refresh()
        M.focus_input()
      end
    end, "Jump to chat " .. tostring(i))
  end

  map("i", "<C-g>m", function()
    vim.cmd("stopinsert")
    M.pick_mode()
  end, "Pick agent mode")
  map("i", "<C-g>c", function()
    vim.cmd("stopinsert")
    M.pick_cli()
  end, "Pick agent CLI")
  map("i", "<C-g>o", function()
    vim.cmd("stopinsert")
    M.pick_model()
  end, "Pick agent model")
  map("i", "<C-g>n", function()
    vim.cmd("stopinsert")
    M.new_agent()
  end, "New agent chat")
end

--- Move a normal file buffer out of agent chat windows into the code editor.
---@param bufnr integer
local function bounce_buffer_from_chat_wins(bufnr)
  if not buf_ok(bufnr) or M.is_chat_buf(bufnr) then
    return
  end

  local bounced = false
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if M.is_chat_win(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      local owned = win == M.winid and M.bufnr or M.input_bufnr
      if buf_ok(owned) then
        pcall(vim.api.nvim_win_set_buf, win, owned)
        bounced = true
      end
    end
  end

  if not bounced then
    return
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  if path ~= "" then
    M.open_file_in_editor(path)
  end
end

local ide_integration_installed = false

--- Track editor focus and keep file opens out of the agent panel (neo-tree, pickers, etc.).
function M.install_ide_integration()
  if ide_integration_installed then
    return
  end
  ide_integration_installed = true

  vim.api.nvim_create_autocmd("WinEnter", {
    group = focus_group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if not is_editor_win(win) then
        return
      end
      M.last_editor_win = win
      local mode = vim.api.nvim_get_mode().mode
      if mode:find("^[vV]") or mode == "\22" then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = protect_group,
    callback = function(args)
      if M.is_chat_buf(args.buf) then
        return
      end
      vim.schedule(function()
        bounce_buffer_from_chat_wins(args.buf)
      end)
    end,
  })
end

local function ensure_chat_bindings()
  bind_input_keys()
  bind_transcript_scroll_follow()
end

local function render()
  persist_input_draft()
  local bufnr = ensure_transcript_buf()
  local s = session.current()
  local title = config.get().chat_title or "Agent Chat"
  local km = config.get().keymaps
  local body_fp = body_fingerprint(s)

  -- Fast path: transcript body unchanged — only refresh tabs/status chrome.
  if render_cache.session_id == s.id and render_cache.body_fp == body_fp and buf_ok(M.bufnr) then
    patch_transcript_header(M.bufnr, title)
    refresh_input_chrome()
    apply_input_draft()
    restore_stream_preview_if_running(s.id)
    if agent.is_running(s.id) then
      set_transcript_markdown(false)
    else
      set_transcript_markdown(true)
    end
    return
  end

  render_cache.session_id = s.id
  render_cache.body_fp = body_fp

  local lines = {
    "# " .. title,
    session.tabs_line(),
    session.status_line(),
    "",
  }
  if #s.messages == 0 then
    vim.list_extend(lines, build_transcript_help(km))
  end

  for _, msg in ipairs(s.messages) do
    local role = msg.role == "user" and "You" or (msg.role == "assistant" and "Agent" or msg.role)
    local body = msg.role == "assistant" and sanitize_user_facing(msg.text or "") or (msg.text or "")
    if body == "" and msg.role == "assistant" then
      body = "_(filtered empty reply)_"
    end
    table.insert(lines, "### " .. role)
    for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
      table.insert(lines, line)
    end
    table.insert(lines, "")
  end

  if #s.references > 0 then
    table.insert(lines, "### Pending code selections")
    table.insert(lines, "_Added via `<leader>Cr` — clear with `r`, `/selections clear`, or `/selections N`_")
    for i, ref in ipairs(s.references) do
      local loc = string.format(
        "%d. `%s:%d-%d`",
        i,
        vim.fn.fnamemodify(ref.file, ":."),
        ref.start_line,
        ref.end_line
      )
      table.insert(lines, loc)
      local preview = preview_one_line(ref.text or "", 64)
      if preview ~= "" then
        table.insert(lines, "   ```")
        table.insert(lines, "   " .. preview)
        table.insert(lines, "   ```")
      end
    end
    table.insert(lines, "")
  end

  if #s.attachments > 0 then
    table.insert(lines, "### Pending file attachments")
    table.insert(lines, "_Clear with `/attach clear` or `/pending clear`_")
    for _, att in ipairs(s.attachments) do
      local label = vim.fn.fnamemodify(att.path, ":.")
      if att.kind == "image" then
        table.insert(lines, string.format("- 🖼 %s", label))
      else
        table.insert(lines, string.format("- 📎 %s", label))
      end
    end
    table.insert(lines, "")
  end

  if #s.prompt_queue > 0 then
    table.insert(lines, "### Queued prompts (runs after current reply)")
    for i, q in ipairs(s.prompt_queue) do
      table.insert(lines, string.format("%d. %s", i, preview_one_line(q, 72)))
    end
    table.insert(lines, "")
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  local streaming = agent.is_running(s.id)
  if streaming then
    if scroll_follow then
      scroll_transcript_bottom(true)
    end
  else
    scroll_follow = true
    scroll_transcript_bottom(true)
  end
  bind_transcript_scroll_follow()
  restore_stream_preview_if_running(s.id)

  refresh_input_chrome()
  apply_input_draft()
  if agent.is_running(s.id) then
    set_transcript_markdown(false)
  else
    set_transcript_markdown(true)
  end
end

---@return string
local function read_input_text()
  if not buf_ok(M.input_bufnr) then
    return ""
  end
  local lines = vim.api.nvim_buf_get_lines(M.input_bufnr, 0, -1, false)
  return vim.trim(table.concat(lines, "\n"))
end

local function clear_input()
  if not buf_ok(M.input_bufnr) then
    return
  end
  session.clear_draft()
  vim.bo[M.input_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M.input_bufnr, 0, -1, false, { "" })
end

--- Strip `@path` file tokens typed in the prompt bar (from the @ completion menu).
---@return integer removed number of @ tokens removed
local function strip_prompt_at_tokens()
  if not buf_ok(M.input_bufnr) then
    return 0
  end
  local lines = vim.api.nvim_buf_get_lines(M.input_bufnr, 0, -1, false)
  local removed = 0
  for i, line in ipairs(lines) do
    local new_line = line:gsub("@[%w%./%-_%:]+", function()
      removed = removed + 1
      return ""
    end)
    new_line = vim.trim(new_line:gsub("%s+", " "))
    lines[i] = new_line
  end
  if removed > 0 then
    vim.bo[M.input_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(M.input_bufnr, 0, -1, false, lines)
  end
  return removed
end

function M.focus_input()
  if not win_ok(M.input_winid) then
    M.open()
  end
  if win_ok(M.input_winid) then
    vim.api.nvim_set_current_win(M.input_winid)
    vim.cmd("startinsert!")
  end
end

local function open_full_layout()
  if win_ok(M.winid) then
    pcall(function()
      vim.wo[M.winid].winfixbuf = false
    end)
    pcall(vim.api.nvim_win_close, M.winid, true)
  end
  if win_ok(M.input_winid) then
    pcall(function()
      vim.wo[M.input_winid].winfixbuf = false
    end)
    pcall(vim.api.nvim_win_close, M.input_winid, true)
  end
  M.winid = nil
  M.input_winid = nil

  local width = config.get().chat_width or 72
  vim.cmd("botright vsplit")
  M.winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.winid, M.bufnr)
  vim.api.nvim_win_set_width(M.winid, width)
  configure_chat_win(M.winid)

  vim.cmd("belowright split")
  M.input_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.input_winid, M.input_bufnr)
  configure_chat_win(M.input_winid, INPUT_HEIGHT)
end

function M.open()
  ensure_transcript_buf()
  ensure_input_buf()

  -- Recover window ids after :AgentReload (module state reset, buffers may remain).
  if not win_ok(M.winid) then
    M.winid = find_win_for_buf(M.bufnr)
  end
  if not win_ok(M.input_winid) then
    M.input_winid = find_win_for_buf(M.input_bufnr)
  end

  if win_ok(M.winid) and win_ok(M.input_winid) then
    ensure_chat_bindings()
    return
  end

  local restored = false
  local ok, err = pcall(function()
    if win_ok(M.winid) and not win_ok(M.input_winid) then
      vim.api.nvim_set_current_win(M.winid)
      vim.cmd("belowright split")
      M.input_winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(M.input_winid, M.input_bufnr)
      configure_chat_win(M.input_winid, INPUT_HEIGHT)
      restored = true
    elseif win_ok(M.input_winid) and not win_ok(M.winid) then
      local width = config.get().chat_width or 72
      vim.api.nvim_set_current_win(M.input_winid)
      vim.cmd("aboveleft split")
      M.winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(M.winid, M.bufnr)
      configure_chat_win(M.winid)
      pcall(vim.api.nvim_win_set_width, M.winid, width)
      restored = true
    else
      open_full_layout()
    end
  end)

  if not ok then
    vim.notify("Failed to open agent chat: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  ensure_chat_bindings()
  render()
  M.focus_input()
  if restored then
    vim.notify("Agent prompt restored — type below, <C-s> to send", vim.log.levels.INFO)
  else
    vim.notify("Agent chat ready — type below, <C-s> to send", vim.log.levels.INFO)
  end
end

function M.close()
  local input_win = M.input_winid
  local chat_win = M.winid
  M.input_winid = nil
  M.winid = nil

  if win_ok(input_win) then
    pcall(function()
      vim.wo[input_win].winfixbuf = false
    end)
    pcall(vim.api.nvim_win_close, input_win, true)
  end
  if win_ok(chat_win) then
    pcall(function()
      vim.wo[chat_win].winfixbuf = false
    end)
    pcall(vim.api.nvim_win_close, chat_win, true)
  end
end

function M.toggle()
  if win_ok(M.winid) and win_ok(M.input_winid) then
    M.close()
    vim.notify("Agent chat closed", vim.log.levels.INFO)
  else
    M.open()
  end
end

function M.focus()
  M.open()
  M.focus_input()
end

function M.refresh()
  if buf_ok(M.bufnr) then
    render()
  end
end

--- Capture visual selection (or current line) as a chat reference.
function M.add_selection_reference()
  local mode = vim.fn.mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    vim.notify("No file name for reference", vim.log.levels.WARN)
    return
  end

  local start_line, end_line
  if mode == "v" or mode == "V" or mode == "\22" then
    local start_pos = vim.fn.getpos("v")
    local end_pos = vim.fn.getpos(".")
    start_line = math.min(start_pos[2], end_pos[2])
    end_line = math.max(start_pos[2], end_pos[2])
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
  else
    local mark_start = vim.fn.getpos("'<")
    local mark_end = vim.fn.getpos("'>")
    if mark_start[2] > 0 and mark_end[2] > 0 then
      start_line = mark_start[2]
      end_line = mark_end[2]
    else
      start_line = vim.fn.line(".")
      end_line = start_line
    end
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  if #lines == 0 then
    vim.notify("Empty selection", vim.log.levels.WARN)
    return
  end

  session.add_reference({
    file = path,
    start_line = start_line,
    end_line = end_line,
    text = table.concat(lines, "\n"),
  })

  vim.notify(
    string.format("Referenced %s:%d-%d", vim.fn.fnamemodify(path, ":."), start_line, end_line),
    vim.log.levels.INFO
  )
  M.open()
  M.refresh()
end

--- Only keep user-facing text parts (skip tool_use / tool_result / images / …).
---@param content any
---@return string
local function extract_text_parts(content)
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return ""
  end

  local bits = {}
  for _, part in ipairs(content) do
    if type(part) == "table" then
      local ptype = part.type
      if (ptype == "text" or ptype == "output_text" or ptype == nil) and type(part.text) == "string" then
        table.insert(bits, part.text)
      end
    elseif type(part) == "string" then
      table.insert(bits, part)
    end
  end
  return table.concat(bits)
end

---@param a string
---@param b string
---@return integer
local function common_prefix_len(a, b)
  local n = math.min(#a, #b)
  for i = 1, n do
    if a:byte(i) ~= b:byte(i) then
      return i - 1
    end
  end
  return n
end

--- Merge assistant text from cumulative snapshots and token deltas.
--- Cursor --stream-partial-output often revises earlier tokens; naive append duplicates lines.
---@param acc { text: string }
---@param new_text string
local function merge_assistant_text(acc, new_text)
  if type(new_text) ~= "string" or new_text == "" then
    return
  end

  local cur = acc.text or ""
  if cur == "" then
    acc.text = new_text
    return
  end
  if new_text == cur then
    return
  end

  -- Growing cumulative snapshot.
  if #new_text >= #cur and new_text:sub(1, #cur) == cur then
    acc.text = new_text
    return
  end

  -- Shorter / stale cumulative snapshot.
  if #new_text <= #cur and cur:sub(1, #new_text) == new_text then
    return
  end

  -- Already present verbatim.
  if cur:find(new_text, 1, true) then
    return
  end

  -- Revised cumulative snapshot (same start, rewritten tail — common with partial streaming).
  local cp = common_prefix_len(cur, new_text)
  local threshold = math.max(12, math.floor(math.min(#cur, #new_text) * 0.3))
  if cp >= threshold then
    acc.text = new_text
    return
  end

  -- Token delta with suffix/prefix overlap.
  local max_overlap = math.min(#cur, #new_text)
  for overlap = max_overlap, 1, -1 do
    if cur:sub(-overlap) == new_text:sub(1, overlap) then
      acc.text = cur .. new_text:sub(overlap + 1)
      return
    end
  end

  acc.text = cur .. new_text
end

---@param text string
---@return boolean
local function is_auth_error(text)
  if type(text) ~= "string" or text == "" then
    return false
  end
  local lower = text:lower()
  return lower:find("not logged in", 1, true) ~= nil
    or lower:find("please run /login", 1, true) ~= nil
    or lower:find("please run login", 1, true) ~= nil
    or lower:find("run /login", 1, true) ~= nil
    or lower:find("please run `agent login`", 1, true) ~= nil
    or lower:find("agent login", 1, true) ~= nil
end

--- Stop the job and clear queued prompts when auth fails mid-stream.
---@param acc table
---@param session_id string
local function abort_on_auth_failure(acc, session_id)
  if not is_auth_error(acc.text) and not is_auth_error(acc.plain or "") then
    return false
  end
  session.clear_chat_id(session_id)
  session.clear_queue(session_id)
  agent.cancel(session_id)
  stop_stream_anim(session_id)
  return true
end

---@param items string[]
---@param prompt string
---@param current string|nil
---@param on_choice fun(choice: string|nil)
local function pick_option(items, prompt, current, on_choice)
  if #items == 0 then
    on_choice(nil)
    return
  end

  local ordered = {}
  local seen = {}
  if current then
    for _, item in ipairs(items) do
      if item == current then
        table.insert(ordered, item)
        seen[item] = true
      end
    end
  end
  for _, item in ipairs(items) do
    if not seen[item] then
      table.insert(ordered, item)
    end
  end

  vim.ui.select(ordered, {
    prompt = prompt,
    format_item = function(item)
      if item == current then
        return item .. "  (current)"
      end
      return item
    end,
  }, function(choice)
    on_choice(choice)
  end)
end

--- Drop tool/telemetry blobs that sometimes leak into assistant text.
--- Preserves normal markdown, tables, and fenced code blocks.
---@param text string
---@return string
local function restore_fenced_blocks(text, blocks)
  return text:gsub("\27FENCED(%d+)\27", function(idx)
    return blocks[tonumber(idx)] or ""
  end)
end

---@param text string
---@return string protected, table<integer,string> blocks
local function protect_fenced_blocks(text)
  local blocks = {}
  local out = {}
  local pos = 1
  while pos <= #text do
    local start = text:find("```", pos, true)
    if not start then
      table.insert(out, text:sub(pos))
      break
    end
    table.insert(out, text:sub(pos, start - 1))
    local close = text:find("```", start + 3, true)
    if not close then
      table.insert(out, text:sub(start))
      break
    end
    local n = #blocks + 1
    blocks[n] = text:sub(start, close + 2)
    table.insert(out, string.format("\27FENCED%d\27", n))
    pos = close + 3
  end
  return table.concat(out), blocks
end

---@param text string
---@return boolean
local function looks_like_protocol_dump(text)
  if type(text) ~= "string" or text == "" then
    return false
  end
  local markers = {
    '"afterFullFileContent"%s*:',
    '"beforeFullFileContent"%s*:',
    '"toolCallId"%s*:',
    '"model_call_id"%s*:',
    '"hookAdditionalContexts"%s*:',
  }
  local hits = 0
  for _, pat in ipairs(markers) do
    if text:find(pat) then
      hits = hits + 1
    end
  end
  if hits >= 1 then
    return true
  end
  local jsonish = 0
  for line in vim.gsplit(text, "\n", { plain = true }) do
    local trimmed = vim.trim(line)
    if trimmed:match('^"[%w_]+"%s*:') or trimmed:match("^[%[{]") then
      jsonish = jsonish + 1
    end
  end
  return jsonish >= 6
end

---@param text string
---@return string
local function filter_protocol_lines(text)
  local protected, blocks = protect_fenced_blocks(text)
  local kept = {}
  for line in vim.gsplit(protected, "\n", { plain = true }) do
    if line:match("^\27FENCED%d+\27$") then
      table.insert(kept, line)
    else
      local trimmed = vim.trim(line)
      local is_noise = trimmed == ""
        or trimmed:match("^[%[{]")
        or trimmed:match("^[%]}]],?$")
        or trimmed:match('^"[%w_]+"%s*:')
        or trimmed:match("^\\\\?n")
        or trimmed:find("afterFullFileContent", 1, true)
        or trimmed:find("toolCallId", 1, true)
        or trimmed:find("beforeFullFileContent", 1, true)
        or trimmed:find("hookAdditionalContexts", 1, true)
      if not is_noise then
        table.insert(kept, line)
      end
    end
  end
  return restore_fenced_blocks(table.concat(kept, "\n"), blocks)
end

--- Remove back-to-back near-duplicate lines (streaming revision artifacts).
---@param text string
---@return string
local function dedupe_adjacent_lines(text)
  if text == "" then
    return text
  end
  local function key(line)
    return (line:gsub("[%s–—%-]+", " "):gsub("^%s+", ""):gsub("%s+$", ""):lower())
  end
  local out = {}
  local prev_key = nil
  for line in vim.gsplit(text, "\n", { plain = true }) do
    local k = key(line)
    if k ~= "" and k == prev_key then
      -- Drop near-duplicate of the previous line.
    else
      table.insert(out, line)
      prev_key = k ~= "" and k or prev_key
    end
  end
  return table.concat(out, "\n")
end

sanitize_user_facing = function(text)
  if type(text) ~= "string" or text == "" then
    return ""
  end

  -- Strip fenced JSON that looks like tool/protocol payloads.
  text = text:gsub('```json%s*\n%s*{%s*\n%s*"[^\n]*tool[^\n]*".-```', "")
  text = text:gsub('```json%s*\n%s*{.-"afterFullFileContent".-```', "")
  text = text:gsub('```json%s*\n%s*{.-"toolCallId".-```', "")

  if looks_like_protocol_dump(text) then
    text = filter_protocol_lines(text)
  end

  text = dedupe_adjacent_lines(text)
  text = text:gsub("\n\n\n+", "\n\n")
  return vim.trim(text)
end

---@param name string|nil
---@param acc { activity: string[] }
local function note_activity(acc, name)
  if type(name) ~= "string" or name == "" then
    return
  end
  name = name:gsub("^mcp_", ""):gsub("_", " ")
  for _, existing in ipairs(acc.activity) do
    if existing == name then
      return
    end
  end
  table.insert(acc.activity, name)
end

---@param event table
---@param acc { text: string, thinking: string, activity: string[], saw_json: boolean, session_id?: string }
handle_stream_event = function(event, acc)
  acc.saw_json = true

  local owner = acc.session_id and session.get_by_id(acc.session_id) or session.current()
  if owner and event.session_id and (not owner.chat_id or owner.chat_id == "") then
    owner.chat_id = event.session_id
  end

  local etype = event.type

  if etype == "assistant" then
    local piece = ""
    if event.message and event.message.content then
      piece = extract_text_parts(event.message.content)
    elseif type(event.text) == "string" then
      piece = event.text
    end
    if piece ~= "" then
      merge_assistant_text(acc, piece)
    end
  elseif etype == "thinking" and event.subtype == "delta" and type(event.text) == "string" then
    acc.thinking = acc.thinking .. event.text
  elseif etype == "tool_call" or etype == "tool_use" or etype == "tool_result" then
    local name = event.name or event.tool_name or (event.tool_call and event.tool_call.name)
    if not name and type(event.toolCallId) == "string" then
      name = event.toolCallId:match("^([%w]+)")
    end
    note_activity(acc, name or "tool")
  elseif etype == "result" then
    if acc.text == "" and event.result ~= nil then
      local candidate = sanitize_user_facing(tostring(event.result))
      if candidate ~= "" and #candidate < 4000 and not candidate:find("afterFullFileContent", 1, true) then
        acc.text = candidate
      end
    end
  end

  if abort_on_auth_failure(acc, acc.session_id or session.current().id) then
    return
  end

  plugins.emit("on_stream_event", event, acc)
end

local function update_stream_preview(acc)
  -- Only paint live preview onto the visible chat for the owning session.
  if not buf_ok(M.bufnr) then
    return
  end
  if acc.session_id and session.current().id ~= acc.session_id then
    return
  end

  ensure_stream_anim(acc)
  schedule_stream_preview(acc)
end

---@param acc { text: string, thinking: string, activity: string[], session_id?: string, _stream_scroll_key?: string, _stream_virt_lines?: string[][] }
---@param frame integer
---@param opts { streaming?: boolean, spinner_only?: boolean }|nil
render_stream_preview = function(acc, frame, opts)
  opts = opts or {}
  if not buf_ok(M.bufnr) then
    return
  end
  if acc.session_id and session.current().id ~= acc.session_id then
    return
  end

  define_stream_highlights()

  local preview = opts.streaming and (acc.text or "") or sanitize_user_facing(acc.text or "")
  local thinking = acc.thinking or ""
  local width = stream_wrap_width()
  local scroll_key = preview .. "\0" .. thinking .. "\0" .. table.concat(acc.activity, ",")
  local glyph = spinner.frame(nil, frame)

  if opts.spinner_only and acc._stream_scroll_key == scroll_key and acc._stream_virt_lines then
    local virt_lines = acc._stream_virt_lines
    if virt_lines[1] and virt_lines[1][1] then
      virt_lines[1][1][1] = glyph
    end
    vim.api.nvim_buf_clear_namespace(M.bufnr, STREAM_NS, 0, -1)
    local last = vim.api.nvim_buf_line_count(M.bufnr)
    vim.api.nvim_buf_set_extmark(M.bufnr, STREAM_NS, math.max(0, last - 1), 0, {
      virt_lines = virt_lines,
      virt_lines_above = false,
    })
    return
  end

  vim.api.nvim_buf_clear_namespace(M.bufnr, STREAM_NS, 0, -1)

  local virt_lines = {}

  if preview == "" and thinking ~= "" then
    local wrapped = wrap_text(thinking, width)
    local visible = tail_lines(wrapped, THINKING_MAX_LINES)
    table.insert(virt_lines, {
      { glyph, "AgentEngineSpinner" },
      { " Thinking", "AgentEngineThinkingLabel" },
    })
    for _, line in ipairs(visible) do
      table.insert(virt_lines, {
        { "  " .. line, "AgentEngineThinking" },
      })
    end
  elseif preview ~= "" then
    local wrapped_lines = {}
    for line in vim.gsplit(preview, "\n", { plain = true }) do
      vim.list_extend(wrapped_lines, wrap_text(line, width))
    end
    local visible = tail_lines(wrapped_lines, 8)
    for i, line in ipairs(visible) do
      if i == 1 then
        table.insert(virt_lines, {
          { glyph, "AgentEngineSpinner" },
          { " ▌ " .. line, "AgentEngineStream" },
        })
      else
        table.insert(virt_lines, {
          { "     " .. line, "AgentEngineStream" },
        })
      end
    end
  elseif #acc.activity > 0 then
    table.insert(virt_lines, {
      { glyph, "AgentEngineSpinner" },
      { " working: " .. table.concat(acc.activity, ", "), "AgentEngineStream" },
    })
  else
    table.insert(virt_lines, {
      { glyph, "AgentEngineSpinner" },
      { " Working…", "AgentEngineStream" },
    })
  end

  acc._stream_scroll_key = scroll_key
  acc._stream_virt_lines = virt_lines

  local last = vim.api.nvim_buf_line_count(M.bufnr)
  vim.api.nvim_buf_set_extmark(M.bufnr, STREAM_NS, math.max(0, last - 1), 0, {
    virt_lines = virt_lines,
    virt_lines_above = false,
  })

  if scroll_key ~= (acc._scroll_key or "") then
    acc._scroll_key = scroll_key
    scroll_transcript_bottom(false)
  end
end

---@param chunk string
---@param acc { text: string, thinking: string, activity: string[], line_buf: string, saw_json: boolean, plain: string }
apply_stream_chunk = function(chunk, acc)
  if type(chunk) ~= "string" or chunk == "" then
    return
  end

  acc.line_buf = (acc.line_buf or "") .. chunk

  while true do
    local nl = acc.line_buf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = acc.line_buf:sub(1, nl - 1)
    acc.line_buf = acc.line_buf:sub(nl + 1)
    if line ~= "" then
      local ok, event = pcall(vim.json.decode, line)
      if ok and type(event) == "table" and event.type ~= nil then
        handle_stream_event(event, acc)
      elseif not acc.saw_json then
        -- Plain-text CLIs only — never dump partial/failed JSON into the chat.
        acc.plain = (acc.plain or "") .. line .. "\n"
      end
    end
  end

  if not acc.saw_json and acc.plain and acc.plain ~= "" then
    acc.text = acc.plain
  end

  if abort_on_auth_failure(acc, acc.session_id or session.current().id) then
    update_stream_preview(acc)
    return
  end

  update_stream_preview(acc)
end

---@param acc { text: string, thinking: string, activity: string[], plain?: string, saw_json: boolean }
---@param stderr_acc string[]
---@param code integer|nil
---@return string
finalize_reply = function(acc, stderr_acc, code)
  local reply = sanitize_user_facing(acc.text)
  if reply == "" and not acc.saw_json and type(acc.plain) == "string" then
    reply = sanitize_user_facing(acc.plain)
  end

  if reply == "" and #stderr_acc > 0 then
    local err_text = sanitize_user_facing(table.concat(stderr_acc))
    if err_text ~= "" then
      reply = err_text
    end
  end

  if reply == "" and #acc.activity > 0 then
    reply = "_Done:_ " .. table.concat(acc.activity, ", ")
  end

  -- Stderr only as a short last resort (never dump huge CLI noise).
  if reply == "" and code and code ~= 0 and #stderr_acc > 0 then
    local err = sanitize_user_facing(table.concat(stderr_acc))
    if #err > 500 then
      err = err:sub(1, 500) .. "…"
    end
    if err ~= "" then
      reply = "_error:_ " .. err
    end
  end

  if is_auth_error(reply) then
    reply = "**Not logged in.** Run `agent login` in a terminal, then try again."
  end

  if reply == "" then
    reply = string.format("_(no output, exit %s)_", tostring(code))
  end
  return reply
end

---@param input string
---@param session_id string|nil
---@param opts { raw?: boolean }|nil
local function run_prompt(input, session_id, opts)
  opts = opts or {}
  session_id = session_id or session.current().id
  local s = session.get_by_id(session_id)
  if not s then
    return
  end

  if agent.is_running(session_id) then
    local refs = session.consume_references_block(session_id)
    local attachments = session.consume_attachments_block(session_id)
    local preamble = refs
    if attachments ~= "" then
      preamble = preamble ~= "" and (preamble .. "\n" .. attachments) or attachments
    end
    local full = preamble ~= "" and (preamble .. input) or input
    local n = session.queue_prompt(full, session_id)
    session.append_message("user", full .. "\n\n_(queued)_", session_id)
    vim.notify(string.format("Queued prompt (%d waiting for this chat)", n), vim.log.levels.INFO)
    if session.current().id == session_id then
      clear_input()
      refresh_input_chrome()
      M.refresh()
    end
    return
  end

  if not agent.resolve_cli(s.cli) then
    vim.notify("No agent CLI found on PATH — install cursor/copilot/claude/aider/…", vim.log.levels.ERROR)
    return
  end

  local cli = agent.resolve_cli(s.cli)
  if cli and cli.dialect == "cursor" then
    local ok_auth, auth_err = agent.check_auth(s.cli)
    if not ok_auth then
      vim.notify(auth_err or "Agent CLI not logged in — run: agent login", vim.log.levels.ERROR)
      session.append_message(
        "assistant",
        "**Not logged in.** Run `agent login` in a terminal, then try again.",
        session_id
      )
      if session.current().id == session_id then
        M.refresh()
      end
      return
    end
  end

  local refs = ""
  local attachments = ""
  if not opts.raw then
    refs = session.consume_references_block(session_id)
    attachments = session.consume_attachments_block(session_id)
  end
  local preamble = refs
  if attachments ~= "" then
    preamble = preamble ~= "" and (preamble .. "\n" .. attachments) or attachments
  end
  local prompt = opts.raw and input or (preamble ~= "" and (preamble .. input) or input)

  session.ensure_chat_id(session_id)
  local s2 = session.get_by_id(session_id) or s
  prompt = plugins.apply_before_send(prompt, { prompt = prompt, session = s2, raw = opts.raw })

  -- Only the current prompt is sent to the CLI. Local transcript is UI-only;
  -- remote Cursor continuity uses this session's chat_id (--resume), never another chat's.
  if not opts.raw then
    session.append_message("user", prompt, session_id)
  end
  if session.current().id == session_id then
    M.open()
    M.refresh()
    clear_input()
    append_streaming_header()
  else
    M.refresh()
  end

  local acc = {
    text = "",
    thinking = "",
    activity = {},
    line_buf = "",
    saw_json = false,
    plain = "",
    session_id = session_id,
  }
  local stderr_acc = {}

  local ok, err = agent.run_prompt(session_id, {
    prompt = prompt,
    mode = s2.mode,
    model = s2.model,
    chat_id = s2.chat_id,
    cli = s2.cli,
    workspace = vim.fn.getcwd(),
  }, function(chunk)
    apply_stream_chunk(chunk, acc)
  end, function(chunk)
    table.insert(stderr_acc, chunk)
  end, function(code, _signal)
    if stream_ui_pending[session_id] then
      flush_stream_preview(session_id)
    end
    stop_stream_anim(session_id)
    if buf_ok(M.bufnr) and session.current().id == session_id then
      vim.api.nvim_buf_clear_namespace(M.bufnr, STREAM_NS, 0, -1)
    end

    if acc.line_buf and acc.line_buf ~= "" then
      local ok_json, event = pcall(vim.json.decode, acc.line_buf)
      if ok_json and type(event) == "table" and event.type ~= nil then
        handle_stream_event(event, acc)
      elseif not acc.saw_json then
        acc.plain = (acc.plain or "") .. acc.line_buf
      end
      acc.line_buf = ""
    end

    local reply = finalize_reply(acc, stderr_acc, code)
    local auth_failed = is_auth_error(reply)
    if auth_failed then
      session.clear_chat_id(session_id)
      session.clear_queue(session_id)
    end
    session.append_message("assistant", reply, session_id)

    local owner = session.get_by_id(session_id)
    plugins.emit("on_after_reply", { reply = reply, session = owner or s2, code = code })

    local title = owner and owner.title or "chat"
    if session.current().id == session_id then
      M.refresh()
      if win_ok(M.input_winid) then
        vim.api.nvim_set_current_win(M.input_winid)
      end
    else
      -- Background chat finished while another tab is focused.
      M.refresh() -- refresh tab strip (● markers)
      vim.notify(string.format("Chat finished: %s", title), vim.log.levels.INFO)
    end

    if code and code ~= 0 then
      vim.notify("Agent exited with code " .. tostring(code), vim.log.levels.WARN)
    elseif is_auth_error(reply) then
      vim.notify("Agent CLI not logged in — run: agent login", vim.log.levels.ERROR)
    end

    if auth_failed then
      return
    end

    local queued = session.pop_queued_prompt(session_id)
    if queued then
      vim.schedule(function()
        run_prompt(queued, session_id, { raw = true })
      end)
    end
  end)

  if not ok then
    vim.notify(err or "Failed to start agent", vim.log.levels.ERROR)
  else
    ensure_stream_anim(acc)
    render_stream_preview(acc, 1, { streaming = true })
    local n = agent.running_count()
    if n > 1 then
      vim.notify(string.format("Agent running… (%d chats in parallel)", n), vim.log.levels.INFO)
    else
      vim.notify("Agent running…", vim.log.levels.INFO)
    end
    refresh_input_chrome()
  end
end

--- Attach a readable file (or image) to the next prompt (@path syntax for Cursor/Claude).
---@param path string|nil defaults to current buffer path
function M.add_file_attachment(path)
  local s = session.current()
  if not agent.cli_supports_attachments(s.cli) then
    vim.notify("Current CLI does not support file attachments", vim.log.levels.WARN)
    return
  end

  if type(path) ~= "string" or path == "" then
    path = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  end
  if path == "" then
    vim.notify("No file path to attach", vim.log.levels.WARN)
    return
  end

  if not agent.model_supports_attachments(s.model) then
    vim.notify("Current model may not support attachments — images need a vision-capable model", vim.log.levels.WARN)
  end

  if session.add_attachment(path) then
    vim.notify("Attached " .. vim.fn.fnamemodify(path, ":."), vim.log.levels.INFO)
    M.open()
    M.refresh()
    refresh_input_chrome()
  end
end

function M.pick_file_attachment()
  vim.ui.input({ prompt = "Attach file path: " }, function(path)
    if path and path ~= "" then
      M.add_file_attachment(path)
    end
  end)
end

--- Send a prompt string (used by :AgentSend and the input bar).
---@param text string
function M.send_text(text)
  if type(text) ~= "string" or vim.trim(text) == "" then
    vim.notify("Prompt is empty", vim.log.levels.WARN)
    return
  end
  text = vim.trim(text)
  if try_slash_command(text) then
    clear_input()
    refresh_input_chrome()
    return
  end
  run_prompt(text)
end

--- Wipe the visible transcript and drop remote chat id (fresh next send).
function M.clear_transcript()
  session.clear_messages()
  M.refresh()
  vim.notify("Transcript cleared — next send starts a fresh remote chat", vim.log.levels.INFO)
end

--- Drop pending code selections (from `<leader>Cr`) so they are not sent with the next prompt.
function M.clear_pending_selections()
  local n = #session.current().references
  session.clear_references()
  M.refresh()
  if n > 0 then
    vim.notify(string.format("Cleared %d code selection(s)", n), vim.log.levels.INFO)
  else
    vim.notify("No pending code selections", vim.log.levels.INFO)
  end
end

--- Back-compat alias.
M.clear_pending_refs = M.clear_pending_selections

--- Drop pending file attachments so they are not sent with the next prompt.
function M.clear_pending_attachments()
  local n = #session.current().attachments
  local at_removed = strip_prompt_at_tokens()
  session.clear_attachments()
  M.refresh()
  refresh_input_chrome()
  local total = n + at_removed
  if total > 0 then
    local parts = {}
    if n > 0 then
      table.insert(parts, string.format("%d attachment(s)", n))
    end
    if at_removed > 0 then
      table.insert(parts, string.format("%d @path token(s)", at_removed))
    end
    vim.notify("Cleared " .. table.concat(parts, ", "), vim.log.levels.INFO)
  else
    vim.notify("No pending file attachments or @paths in prompt", vim.log.levels.INFO)
  end
end

--- Drop all pending code selections, file attachments, and `@path` tokens in the prompt.
function M.clear_pending()
  local s = session.current()
  local sel_n = #s.references
  local att_n = #s.attachments
  local at_removed = strip_prompt_at_tokens()
  session.clear_pending()
  M.refresh()
  refresh_input_chrome()
  local total = sel_n + att_n + at_removed
  if total > 0 then
    local parts = {}
    if sel_n > 0 then
      table.insert(parts, string.format("%d selection(s)", sel_n))
    end
    if att_n > 0 then
      table.insert(parts, string.format("%d attachment(s)", att_n))
    end
    if at_removed > 0 then
      table.insert(parts, string.format("%d @path(s)", at_removed))
    end
    vim.notify("Cleared " .. table.concat(parts, ", "), vim.log.levels.INFO)
  else
    vim.notify("Nothing pending to clear", vim.log.levels.INFO)
  end
end

---@param item { kind: "header"|"entry", label?: string, entry?: table }
---@return string
local function format_history_item(item)
  if item.kind == "header" then
    return "── " .. (item.label or "") .. " ──"
  end
  local e = item.entry
  if not e then
    return ""
  end
  local title = (e.title or "Chat"):gsub("%s+", " ")
  local msg_n = type(e.messages) == "table" and #e.messages or 0
  local when = session.format_relative_time(e.updated_at or e.archived_at or e.created_at)
  return string.format("%s  ·  %d msg%s  ·  %s", title, msg_n, msg_n == 1 and "" or "s", when)
end

--- Browse archived chats grouped by time (Today, Yesterday, Previous 7 days, …).
function M.pick_history()
  local groups = session.history_groups()
  if #groups == 0 then
    vim.notify("No archived chats yet — close a tab with messages to save it", vim.log.levels.INFO)
    return
  end

  local items = {}
  for _, group in ipairs(groups) do
    table.insert(items, { kind = "header", label = group.label })
    for _, entry in ipairs(group.entries) do
      table.insert(items, { kind = "entry", entry = entry })
    end
  end

  vim.ui.select(items, {
    prompt = "Chat history",
    format_item = format_history_item,
  }, function(choice)
    if not choice or choice.kind ~= "entry" or not choice.entry then
      return
    end
    local restored = session.restore_history(choice.entry.id)
    if not restored then
      vim.notify("Failed to restore chat", vim.log.levels.ERROR)
      return
    end
    M.open()
    M.refresh()
    M.focus_input()
    vim.notify("Restored: " .. (restored.title or "chat"), vim.log.levels.INFO)
  end)
end

--- Send whatever is currently in the bottom input bar.
function M.send_from_input()
  local text = read_input_text()
  if text == "" then
    vim.notify("Prompt is empty", vim.log.levels.WARN)
    M.focus_input()
    return
  end
  local mode = vim.api.nvim_get_mode().mode
  if mode:sub(1, 1) == "i" then
    vim.cmd("stopinsert")
  end
  if try_slash_command(text) then
    clear_input()
    refresh_input_chrome()
    M.focus_input()
    return
  end
  run_prompt(text)
end

--- <Space>Cs: send input text if present, otherwise focus the input bar.
function M.send()
  if not win_ok(M.input_winid) or not buf_ok(M.input_bufnr) then
    M.open()
    return
  end

  local text = read_input_text()
  if text ~= "" then
    M.send_from_input()
  else
    M.focus_input()
  end
end

function M.cancel()
  local s = session.current()
  stop_stream_anim(s.id)
  session.clear_queue(s.id)
  if agent.cancel(s.id) then
    vim.notify("Cancelled agent job (queue cleared)", vim.log.levels.WARN)
    M.refresh()
    refresh_input_chrome()
  else
    vim.notify("No running job for this session", vim.log.levels.INFO)
  end
end

function M.pick_mode()
  local current = session.current().mode
  pick_option(session.MODES, "Agent mode", current, function(choice)
    if choice then
      session.set_mode(choice)
      vim.notify("Mode: " .. choice, vim.log.levels.INFO)
      M.refresh()
    end
  end)
end

function M.cycle_mode()
  local mode = session.cycle_mode()
  vim.notify("Mode: " .. mode, vim.log.levels.INFO)
  M.refresh()
end

function M.pick_model()
  local models = agent.list_models()
  local current = session.current().model
  pick_option(models, "Agent model", current, function(choice)
    if choice then
      session.set_model(choice)
      vim.notify("Model: " .. choice, vim.log.levels.INFO)
      M.refresh()
    end
  end)
end

function M.pick_cli()
  local installed = agent.list_installed()
  if #installed == 0 then
    vim.notify("No agent CLIs found on PATH", vim.log.levels.ERROR)
    return
  end

  local labels = {}
  local by_label = {}
  local current_label = nil
  local current_id = session.current().cli
  for _, cli in ipairs(installed) do
    local label = string.format("%s (%s)", cli.label, cli.binary)
    table.insert(labels, label)
    by_label[label] = cli
    if cli.id == current_id then
      current_label = label
    end
  end

  pick_option(labels, "Agent CLI", current_label, function(choice)
    if not choice then
      return
    end
    local cli = by_label[choice]
    if cli and session.set_cli(cli.id) then
      vim.notify("CLI: " .. cli.label .. " (" .. cli.binary .. ")", vim.log.levels.INFO)
      M.refresh()
    end
  end)
end

function M.cycle_cli()
  local cli = session.cycle_cli()
  if cli then
    vim.notify("CLI: " .. cli.label .. " (" .. cli.binary .. ")", vim.log.levels.INFO)
    M.refresh()
  end
end

function M.show_mcp()
  vim.notify(mcp.status_summary(), vim.log.levels.INFO)
end

function M.pick_mcp()
  local servers = mcp.list_servers()
  if #servers == 0 then
    vim.notify("No MCP servers in .cursor/mcp.json", vim.log.levels.WARN)
    return
  end
  local labels = {}
  local by_label = {}
  for _, s in ipairs(servers) do
    local label = string.format("%s — %s", s.id, s.status or "unknown")
    table.insert(labels, label)
    by_label[label] = s
  end
  table.insert(labels, "(toggle auto-approve)")
  pick_option(labels, "MCP servers", nil, function(choice)
    if not choice then
      return
    end
    if choice == "(toggle auto-approve)" then
      mcp.set_auto_approve(not mcp.auto_approve())
      vim.notify("MCP auto-approve: " .. (mcp.auto_approve() and "on" or "off"), vim.log.levels.INFO)
      return
    end
    local s = by_label[choice]
    if not s then
      return
    end
    local actions = { "enable", "disable", "login", "list tools" }
    pick_option(actions, "MCP: " .. s.id, nil, function(action)
      if action == "enable" then
        local ok, err = mcp.enable(s.id)
        vim.notify(ok and ("Enabled " .. s.id) or err, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
      elseif action == "disable" then
        local ok, err = mcp.disable(s.id)
        vim.notify(ok and ("Disabled " .. s.id) or err, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
      elseif action == "login" then
        local ok, err = mcp.login(s.id)
        vim.notify(ok and ("Login: " .. s.id) or err, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
      elseif action == "list tools" then
        local ok, out = mcp.list_tools(s.id)
        vim.notify(ok and out or out, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
      end
    end)
  end)
end

function M.show_plugins()
  local lines = { plugins.status_summary() }
  for _, dir in ipairs(plugins.dirs()) do
    table.insert(lines, "  • " .. dir)
  end
  for _, ext in ipairs(plugins.list_extensions()) do
    table.insert(lines, "  • extension: " .. ext.id)
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

function M.new_agent()
  persist_input_draft()
  session.new()
  M.open()
  apply_input_draft()
  M.refresh()
  local n = agent.running_count()
  if n > 0 then
    vim.notify(string.format("New chat ready — %d other agent(s) still running in parallel", n), vim.log.levels.INFO)
  else
    vim.notify("New chat (fresh transcript, no resume)", vim.log.levels.INFO)
  end
  M.focus_input()
end

function M.close_agent()
  persist_input_draft()
  session.close()
  M.open()
  apply_input_draft()
  M.refresh()
  vim.notify("Chat closed", vim.log.levels.INFO)
  M.focus_input()
end

function M.next_agent()
  persist_input_draft()
  session.cycle(1)
  M.open()
  apply_input_draft()
  M.refresh()
  M.focus_input()
end

function M.prev_agent()
  persist_input_draft()
  session.cycle(-1)
  M.open()
  apply_input_draft()
  M.refresh()
  M.focus_input()
end

return M
