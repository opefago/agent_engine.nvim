-- File: lua/agent_engine/init.lua
-- Multi-CLI agent engine for Neovim: chats, CLIs, modes, models, ghost review, watchers.

local agent = require("agent_engine.agent")
local chat = require("agent_engine.chat")
local config = require("agent_engine.config")
local ghost = require("agent_engine.ghost")
local headroom = require("agent_engine.headroom")
local integration_log = require("agent_engine.integration_log")
local mcp = require("agent_engine.mcp")
local plugins = require("agent_engine.plugins")
local session = require("agent_engine.session")
local storage = require("agent_engine.storage")
local watcher = require("agent_engine.watcher")

local M = {}

local agent_group = vim.api.nvim_create_augroup("AgentEngineGroup", { clear = true })
local setup_done = false

--- Track buffers that opened a classic diffsplit review.
---@type table<integer, string>
local pending_diff_bufs = {}

---@param bufnr integer
---@param filepath string
local function clear_diff_keymaps(bufnr, filepath)
  local km = config.get().keymaps
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.keymap.del, "n", km.accept_change, { buffer = bufnr })
    pcall(vim.keymap.del, "n", km.reject_change, { buffer = bufnr })
    pcall(vim.keymap.del, "n", km.accept_all, { buffer = bufnr })
  end
  pending_diff_bufs[bufnr] = nil
  storage.clear_transaction(filepath)
end

--- Classic whole-file diffsplit fallback.
---@param bufnr integer
---@param filepath string
---@param state { shadow_path: string, drifted?: boolean }
local function open_diffsplit_review(bufnr, filepath, state)
  local cur_win = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      vim.api.nvim_set_current_win(win)
      break
    end
  end

  local ok_diff, diff_err = pcall(vim.cmd, "vertical diffsplit " .. vim.fn.fnameescape(state.shadow_path))
  if not ok_diff then
    vim.notify("diff open failed: " .. tostring(diff_err), vim.log.levels.ERROR)
    storage.clear_transaction(filepath)
    return
  end

  local shadow_buf = vim.api.nvim_get_current_buf()
  vim.bo[shadow_buf].readonly = true
  vim.bo[shadow_buf].modifiable = false
  vim.bo[shadow_buf].bufhidden = "wipe"

  pending_diff_bufs[bufnr] = filepath

  local km = config.get().keymaps

  local function close_shadow_win()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == shadow_buf then
        pcall(vim.api.nvim_win_close, win, true)
        break
      end
    end
  end

  vim.keymap.set("n", km.accept_change, function()
    if not vim.api.nvim_buf_is_valid(shadow_buf) then
      clear_diff_keymaps(bufnr, filepath)
      return
    end
    local lines = vim.api.nvim_buf_get_lines(shadow_buf, 0, -1, false)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    clear_diff_keymaps(bufnr, filepath)
    close_shadow_win()
    pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("write!")
    end)
    vim.notify("Accepted agent changes", vim.log.levels.INFO)
    vim.schedule(function()
      ghost.goto_next_pending_file(filepath)
    end)
  end, { buffer = bufnr, silent = true, desc = "Accept all agent changes" })

  -- In diffsplit mode, accept_all is the same as accept (whole file).
  if km.accept_all and km.accept_all ~= km.accept_change then
    vim.keymap.set("n", km.accept_all, function()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(km.accept_change, true, false, true), "m", false)
    end, { buffer = bufnr, silent = true, desc = "Accept all agent changes" })
  end

  vim.keymap.set("n", km.reject_change, function()
    clear_diff_keymaps(bufnr, filepath)
    close_shadow_win()
    pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("write!")
    end)
    vim.notify("Rejected agent changes (restored editor version)", vim.log.levels.WARN)
    vim.schedule(function()
      ghost.goto_next_pending_file(filepath)
    end)
  end, { buffer = bufnr, silent = true, desc = "Reject agent changes" })

  if vim.api.nvim_win_is_valid(cur_win) then
    pcall(vim.api.nvim_set_current_win, cur_win)
  end
end

--- When an external agent updates a file we are viewing, start ghost (or diffsplit) review.
---@param bufnr integer
---@param filepath string
local function handle_background_file_mutation(bufnr, filepath)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if type(filepath) ~= "string" or filepath == "" then
    return
  end

  local mode = vim.api.nvim_get_mode().mode
  local mode_prefix = mode:sub(1, 1)
  if mode_prefix == "i" or mode_prefix == "R" then
    -- Defer review until insert ends so we don't yank the buffer mid-keystroke.
    vim.api.nvim_create_autocmd("InsertLeave", {
      group = agent_group,
      buffer = bufnr,
      once = true,
      callback = function()
        handle_background_file_mutation(bufnr, filepath)
      end,
    })
    return
  end

  if vim.fn.filereadable(filepath) == 0 then
    return
  end

  local ok_disk, disk_lines = pcall(vim.fn.readfile, filepath)
  if not ok_disk or type(disk_lines) ~= "table" then
    return
  end

  local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if table.concat(disk_lines, "\n") == table.concat(buffer_lines, "\n") then
    return
  end

  -- Already reviewing this file.
  if ghost.is_active(bufnr) or pending_diff_bufs[bufnr] == filepath then
    return
  end

  if not storage.save_transaction(filepath, buffer_lines, disk_lines) then
    vim.notify("agent_engine: failed to persist pending change", vim.log.levels.ERROR)
    return
  end

  local state = storage.load_transaction(filepath)
  if not state or not state.shadow_path then
    return
  end

  if state.drifted then
    vim.notify("Agent change detected but base drifted; review carefully.", vim.log.levels.WARN)
  end

  plugins.emit("on_file_changed", bufnr, filepath)

  local style = config.get().review_style or "ghost"
  if style == "ghost" then
    local ok = ghost.start(bufnr, filepath, buffer_lines, disk_lines)
    if not ok then
      vim.notify("Ghost review found no hunks; falling back to diffsplit", vim.log.levels.WARN)
      open_diffsplit_review(bufnr, filepath, state)
    end
    return
  end

  vim.notify("Agent changed file on disk. Opening diff…", vim.log.levels.INFO)
  open_diffsplit_review(bufnr, filepath, state)
end

local function register_keymaps()
  local km = config.get().keymaps

  -- Discoverable which-key group (leader is <Space>).
  pcall(function()
    local wk = require("which-key")
    wk.add({
      { "<leader>C", group = "agent chat" },
      { "<leader>v", group = "agent review" },
    })
  end)

  local maps = {
    { "n", km.toggle_chat, chat.toggle, "Toggle agent chat" },
    { "n", km.focus_chat, chat.focus, "Focus agent chat" },
    { "n", km.new_agent, chat.new_agent, "New agent session" },
    { "n", km.next_agent, chat.next_agent, "Next agent session" },
    { "n", km.prev_agent, chat.prev_agent, "Prev agent session" },
    { "n", km.send, chat.send, "Send agent prompt" },
    { "n", km.cycle_mode, chat.cycle_mode, "Cycle agent mode" },
    { "n", km.pick_mode, chat.pick_mode, "Pick agent mode" },
    { "n", km.pick_model, chat.pick_model, "Pick agent model" },
    { "n", km.pick_cli, chat.pick_cli, "Pick agent CLI" },
    { "n", km.cycle_cli, chat.cycle_cli, "Cycle agent CLI" },
    { "n", km.cancel_job, chat.cancel, "Cancel agent job" },
    { "n", km.attach_file, chat.add_file_attachment, "Attach file to agent prompt" },
    { "n", km.add_selection, chat.add_selection_reference, "Reference line in chat" },
    { "v", km.add_selection, chat.add_selection_reference, "Reference selection in chat" },
    { "n", km.clear_pending, chat.clear_pending, "Clear pending selections, attachments, and @paths" },
    { "n", km.pick_history, chat.pick_history, "Browse archived agent chats" },
    -- Global fallbacks (buffer-local maps override while a review is active).
    { "n", km.accept_change, ghost.accept_hunk, "Accept current ghost hunk" },
    { "n", km.reject_change, ghost.reject_hunk, "Reject current ghost hunk" },
    { "n", km.accept_all, ghost.accept_all, "Accept all ghost hunks in file" },
    { "n", km.reject_all, ghost.reject_all, "Reject all ghost hunks in file" },
    { "n", km.next_hunk, ghost.next_hunk, "Next ghost hunk" },
    { "n", km.prev_hunk, ghost.prev_hunk, "Previous ghost hunk" },
    {
      "n",
      km.next_pending_file,
      function()
        ghost.goto_next_pending_file()
      end,
      "Next file with pending agent edits",
    },
  }

  for _, m in ipairs(maps) do
    local map_mode, lhs, rhs, desc = m[1], m[2], m[3], m[4]
    if type(lhs) == "string" and lhs ~= "" then
      vim.keymap.set(map_mode, lhs, rhs, { silent = true, desc = desc })
    end
  end
end

local function register_commands()
  local function cmd_mode(opts)
    local mode_arg = opts.args
    if mode_arg == "" then
      chat.pick_mode()
    else
      session.set_mode(mode_arg)
      chat.refresh()
    end
  end

  local function cmd_model(opts)
    if opts.args ~= "" then
      session.set_model(opts.args)
      chat.refresh()
    else
      chat.pick_model()
    end
  end

  local function cmd_cli(opts)
    if opts.args ~= "" then
      if session.set_cli(opts.args) then
        chat.refresh()
      end
    else
      chat.pick_cli()
    end
  end

  local function cmd_send(opts)
    if opts.args ~= "" then
      chat.send_text(opts.args)
    else
      chat.send()
    end
  end

  local function complete_cli()
    local ids = {}
    for _, cli in ipairs(agent.list_installed()) do
      table.insert(ids, cli.id)
    end
    return ids
  end

  -- Primary generic commands
  vim.api.nvim_create_user_command("AgentChat", function()
    chat.open()
  end, { desc = "Open agent chat" })

  vim.api.nvim_create_user_command("AgentChatToggle", function()
    chat.toggle()
  end, { desc = "Toggle agent chat" })

  vim.api.nvim_create_user_command("AgentNew", function()
    chat.new_agent()
  end, { desc = "Open a new agent chat (runs in parallel with others)" })

  vim.api.nvim_create_user_command("AgentClose", function()
    chat.close_agent()
  end, { desc = "Close the active agent chat tab" })

  vim.api.nvim_create_user_command("AgentMode", cmd_mode, {
    nargs = "?",
    complete = function()
      return session.MODES
    end,
    desc = "Set or pick agent mode (agent|plan|ask)",
  })

  vim.api.nvim_create_user_command("AgentModel", cmd_model, {
    nargs = "?",
    desc = "Set or pick agent model",
  })

  vim.api.nvim_create_user_command("AgentCli", cmd_cli, {
    nargs = "?",
    complete = complete_cli,
    desc = "Set or pick agent CLI (installed providers)",
  })

  vim.api.nvim_create_user_command("AgentSend", cmd_send, {
    nargs = "*",
    desc = "Send prompt to the active agent CLI",
  })

  vim.api.nvim_create_user_command("AgentCancel", function()
    chat.cancel()
  end, { desc = "Cancel running agent job" })

  vim.api.nvim_create_user_command("AgentClear", function()
    chat.clear_transcript()
  end, { desc = "Clear the active agent chat transcript" })

  vim.api.nvim_create_user_command("AgentClearPending", function()
    chat.clear_pending()
  end, { desc = "Clear pending code selections, attachments, and @paths" })

  vim.api.nvim_create_user_command("AgentClearSelections", function()
    chat.clear_pending_selections()
  end, { desc = "Clear pending code selections (<leader>Cr)" })

  vim.api.nvim_create_user_command("AgentHistory", function()
    chat.pick_history()
  end, { desc = "Browse archived agent chats" })

  vim.api.nvim_create_user_command("AgentRef", function()
    chat.add_selection_reference()
  end, { range = true, desc = "Add visual/line selection as chat reference" })

  vim.api.nvim_create_user_command("AgentAttach", function(opts)
    if opts.args ~= "" then
      chat.add_file_attachment(opts.args)
    else
      chat.add_file_attachment()
    end
  end, { nargs = "?", complete = "file", desc = "Attach a file to the next agent prompt" })

  vim.api.nvim_create_user_command("AgentMcp", function(opts)
    if opts.args == "" or opts.args == "list" then
      chat.show_mcp()
    elseif opts.args == "pick" then
      chat.pick_mcp()
    else
      chat.send_text("/mcp " .. opts.args)
    end
  end, {
    nargs = "?",
    complete = function()
      return { "pick", "list", "auto on", "auto off" }
    end,
    desc = "List or manage MCP servers (Cursor CLI)",
  })

  vim.api.nvim_create_user_command("AgentHeadroom", function(opts)
    if opts.args == "" or opts.args == "status" then
      vim.notify(headroom.status_summary(), vim.log.levels.INFO)
    elseif opts.args == "on" or opts.args == "enable" then
      headroom.set_enabled(true)
      vim.notify("Headroom compression enabled", vim.log.levels.INFO)
    elseif opts.args == "off" or opts.args == "disable" then
      headroom.set_enabled(false)
      vim.notify("Headroom compression disabled", vim.log.levels.INFO)
    else
      chat.send_text("/headroom " .. opts.args)
    end
  end, {
    nargs = "?",
    complete = function()
      return { "status", "on", "off", "doctor", "perf", "proxy", "mcp install" }
    end,
    desc = "Headroom prompt compression (github.com/headroomlabs-ai/headroom)",
  })

  vim.api.nvim_create_user_command("AgentIntegrationsLog", function(opts)
    if opts.args == "path" then
      vim.notify("Log file: " .. integration_log.path(), vim.log.levels.INFO)
    elseif opts.args == "tail" or opts.args == "" then
      integration_log.show()
    else
      vim.notify("Usage: :AgentIntegrationsLog [tail|path]", vim.log.levels.INFO)
    end
  end, {
    nargs = "?",
    complete = function()
      return { "tail", "path" }
    end,
    desc = "Show integration debug log (Headroom, agent spawn)",
  })

  vim.api.nvim_create_user_command("AgentPlugin", function(opts)
    if opts.args == "" then
      chat.show_plugins()
    elseif opts.args:match("^add ") then
      local path = vim.trim(opts.args:sub(5))
      local ok, err = plugins.add_dir(path)
      vim.notify(ok and ("Added plugin dir: " .. path) or err, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    else
      chat.show_plugins()
    end
  end, { nargs = "*", desc = "List Cursor plugin dirs and agent_engine extensions" })

  vim.api.nvim_create_user_command("AgentReload", function()
    M.reload()
  end, { desc = "Reload agent_engine from disk (no Neovim restart)" })

  vim.api.nvim_create_user_command("AgentAcceptHunk", function()
    ghost.accept_hunk()
  end, { desc = "Accept current ghost hunk" })

  vim.api.nvim_create_user_command("AgentRejectHunk", function()
    ghost.reject_hunk()
  end, { desc = "Reject current ghost hunk" })

  -- Short aliases for single-hunk review.
  vim.api.nvim_create_user_command("AgentAccept", function()
    ghost.accept_hunk()
  end, { desc = "Accept current ghost hunk" })

  vim.api.nvim_create_user_command("AgentReject", function()
    ghost.reject_hunk()
  end, { desc = "Reject current ghost hunk" })

  vim.api.nvim_create_user_command("AgentAcceptAll", function()
    ghost.accept_all()
  end, { desc = "Accept all remaining ghost hunks in file" })

  vim.api.nvim_create_user_command("AgentRejectAll", function()
    ghost.reject_all()
  end, { desc = "Reject all remaining ghost hunks in file" })

  vim.api.nvim_create_user_command("AgentNextFile", function()
    ghost.goto_next_pending_file()
  end, { desc = "Jump to next file with pending agent edits" })

  vim.api.nvim_create_user_command("AgentNextHunk", function()
    ghost.next_hunk()
  end, { desc = "Jump to next ghost hunk" })

  vim.api.nvim_create_user_command("AgentPrevHunk", function()
    ghost.prev_hunk()
  end, { desc = "Jump to previous ghost hunk" })

  -- Back-compat aliases (Cursor* → Agent*)
  vim.api.nvim_create_user_command("CursorChat", function()
    chat.open()
  end, { desc = "Open agent chat (alias)" })

  vim.api.nvim_create_user_command("CursorChatToggle", function()
    chat.toggle()
  end, { desc = "Toggle agent chat (alias)" })

  vim.api.nvim_create_user_command("AgentEngineReload", function()
    M.reload()
  end, { desc = "Reload agent_engine (alias)" })

  vim.api.nvim_create_user_command("CursorEngineReload", function()
    M.reload()
  end, { desc = "Reload agent_engine (legacy alias)" })

  vim.api.nvim_create_user_command("CursorAgentNew", function()
    chat.new_agent()
  end, { desc = "New agent session (alias)" })

  vim.api.nvim_create_user_command("CursorMode", cmd_mode, {
    nargs = "?",
    complete = function()
      return session.MODES
    end,
    desc = "Set or pick agent mode (alias)",
  })

  vim.api.nvim_create_user_command("CursorModel", cmd_model, {
    nargs = "?",
    desc = "Set or pick agent model (alias)",
  })

  vim.api.nvim_create_user_command("CursorSend", cmd_send, {
    nargs = "*",
    desc = "Send prompt to agent (alias)",
  })

  vim.api.nvim_create_user_command("CursorCancel", function()
    chat.cancel()
  end, { desc = "Cancel running agent job (alias)" })

  vim.api.nvim_create_user_command("CursorRef", function()
    chat.add_selection_reference()
  end, { range = true, desc = "Add selection as chat reference (alias)" })

  vim.api.nvim_create_user_command("CursorAcceptHunk", function()
    ghost.accept_hunk()
  end, { desc = "Accept current ghost hunk (alias)" })

  vim.api.nvim_create_user_command("CursorRejectHunk", function()
    ghost.reject_hunk()
  end, { desc = "Reject current ghost hunk (alias)" })

  vim.api.nvim_create_user_command("CursorAccept", function()
    ghost.accept_hunk()
  end, { desc = "Accept current ghost hunk (alias)" })

  vim.api.nvim_create_user_command("CursorReject", function()
    ghost.reject_hunk()
  end, { desc = "Reject current ghost hunk (alias)" })

  vim.api.nvim_create_user_command("CursorAcceptAll", function()
    ghost.accept_all()
  end, { desc = "Accept all ghost hunks (alias)" })

  vim.api.nvim_create_user_command("CursorRejectAll", function()
    ghost.reject_all()
  end, { desc = "Reject all ghost hunks (alias)" })
end

---@param opts AgentEngineConfig|nil
---@param force boolean|nil
function M.setup(opts, force)
  if setup_done and not force then
    return
  end
  setup_done = true

  config.setup(opts)
  headroom.ensure_extension_loaded()
  plugins.load()
  session.load()

  if headroom.enabled() then
    vim.notify(headroom.status_summary(), headroom.available() and vim.log.levels.INFO or vim.log.levels.WARN)
    if integration_log.enabled() then
      integration_log.info("agent_engine", "started with headroom + integrations_log")
      integration_log.info("agent_engine", "log file: " .. integration_log.path())
      if headroom.available() then
        headroom.doctor_ok()
      end
    end
  end

  local installed = agent.list_installed()
  if #installed == 0 then
    vim.notify(
      "agent_engine: no agent CLI on PATH (cursor/copilot/claude/aider/…). UI still loads.",
      vim.log.levels.WARN
    )
  else
    local names = {}
    for _, cli in ipairs(installed) do
      table.insert(names, cli.id)
    end
    vim.notify("agent_engine: CLIs found — " .. table.concat(names, ", "), vim.log.levels.INFO)
  end

  register_keymaps()
  register_commands()
  chat.install_ide_integration()

  -- Keep 'autoread' on so timestamps are tracked, but never show the W12/W13
  -- "load file from disk?" prompt — agent edits are reviewed via ghost instead.
  vim.o.autoread = true

  if config.get().suppress_reload_prompt ~= false then
    vim.api.nvim_create_autocmd("FileChangedShell", {
      group = agent_group,
      pattern = "*",
      callback = function(args)
        local bufnr = args.buf
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        if vim.bo[bufnr].buftype ~= "" then
          return
        end

        local path = vim.api.nvim_buf_get_name(bufnr)
        local reason = vim.v.fcs_reason

        -- "" = keep the in-memory buffer, do not prompt, do not autoreload.
        -- Ghost review needs the pre-agent buffer contents vs disk.
        vim.v.fcs_choice = ""

        if reason == "deleted" or path == "" then
          return
        end

        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(bufnr) then
            handle_background_file_mutation(bufnr, path)
          end
        end)
      end,
    })
  end

  -- When a window shows a file, re-check disk quietly (FileChangedShell above
  -- swallows the prompt and hands off to ghost review).
  vim.api.nvim_create_autocmd({ "BufWinEnter", "FocusGained", "CursorHold" }, {
    group = agent_group,
    pattern = "*",
    callback = function(args)
      if not vim.api.nvim_buf_is_valid(args.buf) then
        return
      end
      if vim.bo[args.buf].buftype ~= "" then
        return
      end
      local path = vim.api.nvim_buf_get_name(args.buf)
      if path == "" then
        return
      end
      pcall(vim.cmd, "checktime " .. tostring(args.buf))
    end,
  })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = agent_group,
    pattern = "*",
    callback = function(args)
      local path = vim.api.nvim_buf_get_name(args.buf)
      if path == "" or vim.bo[args.buf].buftype ~= "" then
        return
      end
      watcher.watch_file(args.buf, path, handle_background_file_mutation)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = agent_group,
    pattern = "*",
    callback = function(args)
      watcher.unwatch_file(args.buf)
      pending_diff_bufs[args.buf] = nil
      ghost.clear(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = agent_group,
    callback = function()
      agent.cancel(nil)
      local s = session.current()
      if s then
        session.set_model(s.model)
      end
    end,
  })

  vim.notify("agent_engine ready — :AgentChat to open, :AgentCli to switch", vim.log.levels.INFO)
end

--- Drop cached modules and re-run setup (for use in a live session after edits).
function M.reload()
  agent.cancel(nil)
  local was_open = (chat.winid ~= nil and vim.api.nvim_win_is_valid(chat.winid))
    or (chat.input_winid ~= nil and vim.api.nvim_win_is_valid(chat.input_winid))
  pcall(function()
    if chat.teardown then
      chat.teardown()
    end
    chat.close()
  end)
  local cfg = config.get()
  -- Re-read config.lua defaults on reload; only preserve explicit runtime overrides.
  local setup_opts = {
    review_style = cfg.review_style,
    default_cli = cfg.default_cli,
    default_mode = cfg.default_mode,
    default_model = cfg.default_model,
    chat_width = cfg.chat_width,
    chat_title = cfg.chat_title,
    history_enabled = cfg.history_enabled,
    headroom = cfg.headroom,
    integrations_log = cfg.integrations_log,
    extensions = cfg.extensions,
    keymaps = cfg.keymaps,
  }
  for _, mod in ipairs({
    "agent_engine.agent",
    "agent_engine.chat",
    "agent_engine.config",
    "agent_engine.spinner",
    "agent_engine.ghost",
    "agent_engine.session",
    "agent_engine.storage",
    "agent_engine.watcher",
    "agent_engine.mcp",
    "agent_engine.headroom",
    "agent_engine.integration_log",
    "agent_engine.extensions.headroom",
    "agent_engine.plugins",
    "agent_engine.init",
    "agent_engine",
    -- Clear pre-rename module cache if this session still has it loaded.
    "cursor_engine.agent",
    "cursor_engine.chat",
    "cursor_engine.config",
    "cursor_engine.ghost",
    "cursor_engine.session",
    "cursor_engine.storage",
    "cursor_engine.watcher",
    "cursor_engine.init",
    "cursor_engine",
  }) do
    package.loaded[mod] = nil
  end
  setup_done = false
  package.loaded["agent_engine.config"] = nil
  local fresh = require("agent_engine")
  fresh.setup(setup_opts, true)
  if was_open then
    fresh.chat.open()
  end
  vim.notify("agent_engine reloaded", vim.log.levels.INFO)
end

M.chat = chat
M.session = session
M.agent = agent
M.config = config
M.ghost = ghost
M.mcp = mcp
M.headroom = headroom
M.integration_log = integration_log
M.plugins = plugins

return M
