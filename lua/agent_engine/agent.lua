-- File: lua/agent_engine/agent.lua
-- Safe process spawning for discovered agent CLIs (Cursor, Copilot, Claude, …).

local config = require("agent_engine.config")

local M = {}

---@type table<string, { handle: uv.uv_process_t|nil, stdout: uv.uv_pipe_t|nil, stderr: uv.uv_pipe_t|nil, pid: integer|nil }>
M.jobs = {}

--- Batched stdout/stderr per job — fewer vim.schedule calls while the CLI streams.
---@type table<string, string>
local chunk_buffers = {}

---@type table<string, uv.uv_timer_t>
local chunk_timers = {}

---@return integer
local function chunk_interval_ms()
  local ms = config.get().stream_chunk_interval_ms
  if type(ms) ~= "number" or ms < 0 then
    return 16
  end
  return ms
end

---@param job_id string
---@param stream "stdout"|"stderr"
---@return string
local function chunk_key(job_id, stream)
  return job_id .. ":" .. stream
end

---@param key string
---@param cb fun(chunk: string)|nil
local function flush_chunk_buffer(key, cb)
  local timer = chunk_timers[key]
  if timer then
    pcall(function()
      timer:stop()
      timer:close()
    end)
    chunk_timers[key] = nil
  end
  local data = chunk_buffers[key]
  chunk_buffers[key] = nil
  if data and data ~= "" and cb then
    cb(data)
  end
end

---@param job_id string
---@param stream "stdout"|"stderr"
---@param data string
---@param cb fun(chunk: string)|nil
local function append_chunk(job_id, stream, data, cb)
  if not cb then
    return
  end
  local key = chunk_key(job_id, stream)
  chunk_buffers[key] = (chunk_buffers[key] or "") .. data
  if chunk_timers[key] then
    return
  end
  local interval = chunk_interval_ms()
  if interval == 0 then
    flush_chunk_buffer(key, cb)
    return
  end
  local timer = vim.uv.new_timer()
  if not timer then
    flush_chunk_buffer(key, cb)
    return
  end
  chunk_timers[key] = timer
  timer:start(interval, 0, function()
    vim.schedule(function()
      flush_chunk_buffer(key, cb)
    end)
  end)
end

---@param job_id string
---@param on_stdout fun(chunk: string)|nil
---@param on_stderr fun(chunk: string)|nil
local function flush_job_chunks(job_id, on_stdout, on_stderr)
  flush_chunk_buffer(chunk_key(job_id, "stdout"), on_stdout)
  flush_chunk_buffer(chunk_key(job_id, "stderr"), on_stderr)
end

---@class AgentEngineDiscoveredCli
---@field id string provider id
---@field label string human label
---@field binary string executable name/path
---@field dialect string

---@type string|nil currently selected provider id
M.selected_cli = nil

--- Discover every configured provider that has an executable on PATH.
---@return AgentEngineDiscoveredCli[]
function M.list_installed()
  local cfg = config.get()
  local found = {}
  local seen_bin = {}

  for _, provider in ipairs(cfg.providers or {}) do
    if type(provider) == "table" and type(provider.binaries) == "table" then
      for _, name in ipairs(provider.binaries) do
        if type(name) == "string" and name ~= "" and not seen_bin[name] then
          if vim.fn.executable(name) == 1 then
            seen_bin[name] = true
            table.insert(found, {
              id = provider.id or name,
              label = provider.label or provider.id or name,
              binary = name,
              dialect = provider.dialect or "generic",
            })
            break -- one binary per provider is enough
          end
        end
      end
    end
  end

  return found
end

--- Resolve the active CLI entry (selected → default → first installed).
---@param prefer_id string|nil
---@return AgentEngineDiscoveredCli|nil
function M.resolve_cli(prefer_id)
  local installed = M.list_installed()
  if #installed == 0 then
    return nil
  end

  local want = prefer_id or M.selected_cli or config.get().default_cli
  if want and want ~= "" then
    for _, cli in ipairs(installed) do
      if cli.id == want then
        return cli
      end
    end
  end

  return installed[1]
end

--- Set the active provider by id. Returns the resolved entry or nil.
---@param id string
---@return AgentEngineDiscoveredCli|nil
---@return string|nil err
function M.set_cli(id)
  if type(id) ~= "string" or id == "" then
    return nil, "cli id must be a non-empty string"
  end
  local cli = M.resolve_cli(id)
  if not cli or cli.id ~= id then
    -- resolve_cli falls back; verify the id is actually installed
    for _, entry in ipairs(M.list_installed()) do
      if entry.id == id then
        M.selected_cli = id
        return entry, nil
      end
    end
    return nil, "CLI not installed: " .. id
  end
  M.selected_cli = id
  return cli, nil
end

--- Cycle to the next installed CLI.
---@return AgentEngineDiscoveredCli|nil
function M.cycle_cli()
  local installed = M.list_installed()
  if #installed == 0 then
    return nil
  end
  local current = M.resolve_cli()
  local idx = 1
  if current then
    for i, cli in ipairs(installed) do
      if cli.id == current.id then
        idx = i
        break
      end
    end
  end
  local next_cli = installed[(idx % #installed) + 1]
  M.selected_cli = next_cli.id
  return next_cli
end

---@return string|nil binary name
function M.find_binary()
  local cli = M.resolve_cli()
  return cli and cli.binary or nil
end

--- Standalone `agent` / `cursor-agent` run subcommands directly; IDE `cursor` needs `agent`.
---@param binary string
---@return string[]
local function cursor_subcommand_prefix(binary)
  if vim.fs.basename(binary) == "cursor" then
    return { "agent" }
  end
  return {}
end

--- Build argv for a Cursor-dialect subcommand (create-chat, models, status, …).
---@param cli AgentEngineDiscoveredCli
---@param subcmd string
---@param extra string[]|nil
---@return string[]
local function cursor_subcommand_argv(cli, subcmd, extra)
  local argv = { cli.binary }
  vim.list_extend(argv, cursor_subcommand_prefix(cli.binary))
  table.insert(argv, subcmd)
  if extra then
    vim.list_extend(argv, extra)
  end
  return argv
end

--- Whether the active (or given) CLI speaks the Cursor agent dialect.
---@param binary_or_cli string|AgentEngineDiscoveredCli|nil
---@return boolean
function M.is_cursor_cli(binary_or_cli)
  if type(binary_or_cli) == "table" then
    return binary_or_cli.dialect == "cursor"
  end
  local cli = M.resolve_cli()
  if binary_or_cli and type(binary_or_cli) == "string" then
    local base = vim.fs.basename(binary_or_cli)
    if cli and cli.binary == binary_or_cli then
      return cli.dialect == "cursor"
    end
    return base == "agent" or base == "cursor-agent" or base == "cursor"
  end
  return cli ~= nil and cli.dialect == "cursor"
end

--- Whether the CLI dialect can pass @file attachments in prompts.
---@param cli_id string|nil
---@return boolean
function M.cli_supports_attachments(cli_id)
  local cli = M.resolve_cli(cli_id)
  return cli ~= nil and (cli.dialect == "cursor" or cli.dialect == "claude")
end

--- Heuristic: model likely supports image / file context (vision or multimodal).
---@param model string|nil
---@return boolean
function M.model_supports_attachments(model)
  if type(model) ~= "string" or model == "" or model == "auto" then
    return true
  end
  local m = model:lower()
  local patterns = {
    "vision",
    "image",
    "gpt-4o",
    "gpt-5",
    "gemini",
    "claude",
    "grok",
    "composer",
  }
  for _, pat in ipairs(patterns) do
    if m:find(pat, 1, true) then
      return true
    end
  end
  local cfg = config.get()
  if type(cfg.attachment_models) == "table" then
    for _, id in ipairs(cfg.attachment_models) do
      if id == model then
        return true
      end
    end
  end
  return false
end

---@param prompt string
---@param preamble string|nil
---@return string
local function compose_prompt(prompt, preamble)
  if type(preamble) ~= "string" or preamble == "" then
    return prompt
  end
  return preamble .. prompt
end

---@param pipe uv.uv_pipe_t|nil
local function safe_close_pipe(pipe)
  if not pipe then
    return
  end
  local ok_closing, closing = pcall(function()
    return pipe:is_closing()
  end)
  if ok_closing and closing then
    return
  end
  pcall(function()
    pipe:read_stop()
  end)
  pcall(function()
    pipe:close()
  end)
end

---@param handle uv.uv_process_t|nil
local function safe_close_handle(handle)
  if not handle then
    return
  end
  local ok_closing, closing = pcall(function()
    return handle:is_closing()
  end)
  if ok_closing and closing then
    return
  end
  pcall(function()
    handle:close()
  end)
end

--- Build CLI argv for a prompt run, dialect-aware.
---@param opts { prompt: string, mode?: string, model?: string, chat_id?: string, workspace?: string, cli?: string, attachments_preamble?: string }
---@return string[]|nil args
---@return string|nil err
---@return AgentEngineDiscoveredCli|nil cli
function M.build_args(opts)
  if type(opts) ~= "table" then
    return nil, "opts must be a table", nil
  end
  local prompt = opts.prompt
  if type(prompt) ~= "string" or vim.trim(prompt) == "" then
    return nil, "prompt must be a non-empty string", nil
  end
  prompt = compose_prompt(prompt, opts.attachments_preamble)

  local cli = M.resolve_cli(opts.cli)
  if not cli then
    return nil, "No executable agent found on PATH", nil
  end

  local cfg = config.get()
  local args = {}
  local dialect = cli.dialect or "generic"

  if dialect == "cursor" then
    vim.list_extend(args, cursor_subcommand_prefix(cli.binary))
    vim.list_extend(args, {
      "--print",
      "--output-format",
      "stream-json",
      "--stream-partial-output",
    })

    local mode = opts.mode or cfg.default_mode or "agent"
    if mode == "plan" or mode == "ask" then
      table.insert(args, "--mode")
      table.insert(args, mode)
    end

    local model = opts.model or cfg.default_model
    if type(model) == "string" and model ~= "" and model ~= "auto" then
      table.insert(args, "--model")
      table.insert(args, model)
    end

    if opts.chat_id and opts.chat_id ~= "" then
      table.insert(args, "--resume")
      table.insert(args, opts.chat_id)
    end

    local workspace = opts.workspace or vim.fn.getcwd()
    if type(workspace) == "string" and workspace ~= "" then
      table.insert(args, "--workspace")
      table.insert(args, workspace)
    end

    if cfg.trust then
      table.insert(args, "--trust")
    end
    if cfg.force then
      table.insert(args, "--force")
    end

    local mcp_mod = require("agent_engine.mcp")
    if mcp_mod.auto_approve() then
      table.insert(args, "--approve-mcps")
    end

    for _, dir in ipairs(require("agent_engine.plugins").dirs()) do
      table.insert(args, "--plugin-dir")
      table.insert(args, dir)
    end

    table.insert(args, prompt)
  elseif dialect == "copilot" then
    -- GitHub Copilot CLI: non-interactive prompt
    vim.list_extend(args, { "-p", prompt, "--allow-all-tools" })
  elseif dialect == "claude" then
    -- Claude Code: print mode
    vim.list_extend(args, { "-p", prompt })
    local model = opts.model or cfg.default_model
    if type(model) == "string" and model ~= "" and model ~= "auto" then
      table.insert(args, "--model")
      table.insert(args, model)
    end
  elseif dialect == "aider" then
    vim.list_extend(args, { "--message", prompt, "--yes-always" })
  elseif dialect == "codex" then
    vim.list_extend(args, { "exec", prompt })
  elseif dialect == "gemini" then
    vim.list_extend(args, { "-p", prompt })
  else
    -- Generic fallback: pass the prompt as the sole argument.
    table.insert(args, prompt)
  end

  return args, nil, cli
end

--- Create an empty Cursor chat and return its id (Cursor dialect only).
---@return string|nil chat_id
---@return string|nil err
function M.create_chat()
  local cli = M.resolve_cli()
  if not cli then
    return nil, "No executable agent found on PATH"
  end
  if cli.dialect ~= "cursor" then
    return nil, "create-chat requires the Cursor agent CLI"
  end

  local out = vim.fn.system(cursor_subcommand_argv(cli, "create-chat"))
  if vim.v.shell_error ~= 0 then
    return nil, "create-chat failed: " .. vim.trim(out or "")
  end

  local chat_id = vim.trim(out or "")
  if chat_id == "" then
    return nil, "create-chat returned an empty id"
  end
  return chat_id, nil
end

--- Verify Cursor agent login (no-op for other dialects).
---@param cli_id string|nil
---@return boolean ok
---@return string|nil err
function M.check_auth(cli_id)
  local cli = M.resolve_cli(cli_id)
  if not cli or cli.dialect ~= "cursor" then
    return true, nil
  end

  local out = vim.fn.system(cursor_subcommand_argv(cli, "status"))
  local text = vim.trim(out or "")
  if vim.v.shell_error ~= 0 then
    return false, text ~= "" and text or "agent status failed"
  end
  local lower = text:lower()
  if lower:find("logged in", 1, true) and not lower:find("not logged in", 1, true) then
    return true, nil
  end
  if lower:find("not logged in", 1, true) then
    return false, text
  end
  return true, nil
end

--- List models from the CLI when available; otherwise return config defaults.
---@return string[]
function M.list_models()
  local cli = M.resolve_cli()
  local fallback = vim.deepcopy(config.get().models or {})

  if not cli or cli.dialect ~= "cursor" then
    return fallback
  end

  local out = vim.fn.system(cursor_subcommand_argv(cli, "models"))
  if vim.v.shell_error ~= 0 or not out or out == "" then
    return fallback
  end

  local models = {}
  for line in vim.gsplit(out, "\n", { plain = true, trimempty = true }) do
    local id = line:match("^(%S+)")
    if id and id ~= "Available" and id ~= "-" then
      table.insert(models, id)
    end
  end

  if #models == 0 then
    return fallback
  end
  return models
end

--- Cancel a running job by id (or every job when id is nil).
---@param job_id string|nil
---@return boolean cancelled
function M.cancel(job_id)
  local function kill_one(id, job)
    if not job then
      return false
    end
    if job.handle and job.pid and job.pid > 0 then
      pcall(vim.uv.process_kill, job.handle, "sigterm")
      pcall(vim.uv.kill, job.pid, "sigterm")
    end
    safe_close_pipe(job.stdout)
    safe_close_pipe(job.stderr)
    safe_close_handle(job.handle)
    M.jobs[id] = nil
    return true
  end

  if job_id then
    return kill_one(job_id, M.jobs[job_id])
  end

  local any = false
  for id, job in pairs(M.jobs) do
    if kill_one(id, job) then
      any = true
    end
  end
  return any
end

--- Whether a job id is currently running.
---@param job_id string
---@return boolean
function M.is_running(job_id)
  return M.jobs[job_id] ~= nil
end

--- How many agent jobs are in flight (for parallel-chat UI).
---@return integer
function M.running_count()
  local n = 0
  for _ in pairs(M.jobs) do
    n = n + 1
  end
  return n
end

---@return string[] session/job ids
function M.list_running()
  local ids = {}
  for id in pairs(M.jobs) do
    table.insert(ids, id)
  end
  table.sort(ids)
  return ids
end

--- Spawn the agent non-blocking. Streams stdout/stderr via callbacks.
---@param job_id string Unique job / session key
---@param args string[]
---@param on_stdout fun(chunk: string)|nil
---@param on_stderr fun(chunk: string)|nil
---@param on_exit fun(code: integer|nil, signal: integer|nil)|nil
---@param binary string|nil override binary (defaults to active CLI)
---@return boolean ok
---@return string|nil err
function M.run_agent_command(job_id, args, on_stdout, on_stderr, on_exit, binary)
  if type(job_id) ~= "string" or job_id == "" then
    return false, "job_id must be a non-empty string"
  end
  if type(args) ~= "table" then
    return false, "args must be a table"
  end

  binary = binary or M.find_binary()
  if not binary then
    return false, "No executable agent found on PATH"
  end

  if M.jobs[job_id] then
    return false, "An agent job is already running for this session"
  end

  local stdout = vim.uv.new_pipe(false)
  local stderr = vim.uv.new_pipe(false)
  if not stdout or not stderr then
    safe_close_pipe(stdout)
    safe_close_pipe(stderr)
    return false, "Failed to allocate stdio pipes"
  end

  local options = {
    args = args,
    stdio = { nil, stdout, stderr },
    detached = true,
    hide = true,
  }

  local headroom_mod = package.loaded["agent_engine.headroom"]
  if headroom_mod and headroom_mod.enabled() then
    local spawn_env = vim.fn.environ()
    local cli = M.resolve_cli()
    for k, v in pairs(headroom_mod.spawn_env(cli)) do
      spawn_env[k] = v
    end
    options.env = spawn_env
  end

  local log = package.loaded["agent_engine.integration_log"]
  if log and log.enabled() then
    log.info("agent", "spawn " .. binary .. " " .. table.concat(args, " "))
    if options.env then
      local env_keys = {}
      for k in pairs(options.env) do
        if k:find("HEADROOM") or k:find("ANTHROPIC") or k:find("OPENAI") then
          table.insert(env_keys, k .. "=" .. tostring(options.env[k]))
        end
      end
      if #env_keys > 0 then
        log.debug("agent", "spawn env: " .. table.concat(env_keys, " "))
      end
    end
  end

  local handle, pid_or_err = vim.uv.spawn(binary, options, function(code, signal)
    flush_job_chunks(job_id, on_stdout, on_stderr)

    local job = M.jobs[job_id]
    if job then
      safe_close_pipe(job.stdout)
      safe_close_pipe(job.stderr)
      safe_close_handle(job.handle)
      M.jobs[job_id] = nil
    else
      safe_close_pipe(stdout)
      safe_close_pipe(stderr)
      safe_close_handle(handle)
    end

    if on_exit then
      vim.schedule(function()
        on_exit(code, signal)
      end)
    end
  end)

  if not handle then
    safe_close_pipe(stdout)
    safe_close_pipe(stderr)
    return false, "Failed to spawn agent: " .. tostring(pid_or_err)
  end

  M.jobs[job_id] = {
    handle = handle,
    stdout = stdout,
    stderr = stderr,
    pid = type(pid_or_err) == "number" and pid_or_err or nil,
  }

  local function start_reader(pipe, cb, label)
    local ok, err = pcall(function()
      vim.uv.read_start(pipe, function(read_err, data)
        if read_err then
          vim.schedule(function()
            vim.notify(string.format("Agent %s read error: %s", label, tostring(read_err)), vim.log.levels.WARN)
          end)
          return
        end
        if data and cb then
          append_chunk(job_id, label == "stderr" and "stderr" or "stdout", data, cb)
        end
      end)
    end)
    if not ok then
      vim.notify(string.format("Agent failed to start %s reader: %s", label, tostring(err)), vim.log.levels.ERROR)
    end
  end

  start_reader(stdout, on_stdout, "stdout")
  start_reader(stderr, on_stderr, "stderr")

  return true, nil
end

--- Convenience: build args and run.
---@param job_id string
---@param opts table
---@param on_stdout fun(chunk: string)|nil
---@param on_stderr fun(chunk: string)|nil
---@param on_exit fun(code: integer|nil, signal: integer|nil)|nil
---@return boolean ok
---@return string|nil err
function M.run_prompt(job_id, opts, on_stdout, on_stderr, on_exit)
  local args, err, cli = M.build_args(opts)
  if not args then
    return false, err
  end

  local binary = cli and cli.binary or nil
  local headroom_mod = package.loaded["agent_engine.headroom"]
  if headroom_mod and headroom_mod.enabled() then
    binary, args = headroom_mod.adjust_spawn(binary or M.find_binary() or "", args, cli)
  end

  if not binary or binary == "" then
    return false, "No executable agent found on PATH"
  end

  return M.run_agent_command(job_id, args, on_stdout, on_stderr, on_exit, binary)
end

-- Back-compat alias used by older call sites.
M.active_job = nil

return M
