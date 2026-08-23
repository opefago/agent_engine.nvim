-- @ file references and / slash commands in the agent prompt bar.
-- Uses blink.cmp when available; falls back to snacks picker / vim.ui.select.

local agent = require("agent_engine.agent")
local config = require("agent_engine.config")

local M = {}

local MAX_FILES = 250

local SLASH_COMMANDS = {
  { cmd = "mode", desc = "Switch mode (agent, plan, ask)", short = "m" },
  { cmd = "cli", desc = "Switch CLI backend", short = "i" },
  { cmd = "model", desc = "Switch model", short = "o" },
  { cmd = "attach", desc = "Attach a file for the next send", short = "a" },
  { cmd = "selections", desc = "Manage code selections from <leader>Cr", short = nil },
  { cmd = "refs", desc = "Alias for /selections", short = nil },
  { cmd = "pending", desc = "Show or clear all pending context", short = nil },
  { cmd = "history", desc = "Browse archived chats", short = nil },
  { cmd = "new", desc = "New chat tab", short = "n" },
  { cmd = "close", desc = "Close current chat tab", short = "d" },
  { cmd = "clear", desc = "Clear transcript", short = nil },
  { cmd = "cancel", desc = "Cancel job and clear queue", short = "x" },
  { cmd = "queue", desc = "Show or clear queued prompts", short = nil },
  { cmd = "help", desc = "Show slash command summary", short = "h" },
}

---@param path string
---@return string
local function rel_path(path)
  path = vim.fs.normalize(path)
  local cwd = vim.fs.normalize(vim.fn.getcwd()) .. "/"
  if path:sub(1, #cwd) == cwd then
    return path:sub(#cwd + 1)
  end
  return path
end

---@param bufnr integer
---@return integer row, integer start_col, integer end_col|nil
function M.at_token_range(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  if winid < 0 then
    return 1, 1, 1
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(winid))
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local start_col = col
  while start_col >= 1 do
    local ch = line:sub(start_col, start_col)
    if ch == "@" then
      break
    end
    if ch:match("[%w%./%-_%:]") then
      start_col = start_col - 1
    else
      return row, col, nil
    end
  end
  if line:sub(start_col, start_col) ~= "@" then
    return row, col, nil
  end
  return row, start_col, col
end

---@param bufnr integer
---@param path string
---@param row integer|nil
---@param start_col integer|nil
---@param end_col integer|nil
function M.insert_file_reference(bufnr, path, row, start_col, end_col)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not row or not start_col or not end_col then
    local r, s, e = M.at_token_range(bufnr)
    row = row or r
    start_col = start_col or s
    end_col = end_col or e
  end
  if not start_col or not end_col then
    local winid = vim.fn.bufwinid(bufnr)
    if winid >= 0 then
      row, end_col = unpack(vim.api.nvim_win_get_cursor(winid))
      start_col = end_col
    else
      return
    end
  end

  local display = "@" .. rel_path(path)
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local new_line = line:sub(1, start_col - 1) .. display .. line:sub(end_col + 1)
  vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { new_line })

  local winid = vim.fn.bufwinid(bufnr)
  if winid >= 0 then
    vim.api.nvim_win_set_cursor(winid, { row, start_col + #display })
  end
end

---@param query string
---@param callback fun(files: string[])
function M.collect_files(query, callback)
  query = query or ""
  local cwd = vim.fn.getcwd()

  if vim.fn.executable("fd") == 1 or vim.fn.executable("fdfind") == 1 then
    local bin = vim.fn.executable("fd") == 1 and "fd" or "fdfind"
    local args = { "--type", "f", "--type", "l", "--color", "never", "-E", ".git" }
    if query ~= "" then
      table.insert(args, query)
    end
    vim.system({ bin, unpack(args) }, { cwd = cwd, text = true }, function(obj)
      local files = {}
      if obj.code == 0 and obj.stdout then
        for file in vim.gsplit(vim.trim(obj.stdout), "\n", { plain = true, trimempty = true }) do
          table.insert(files, vim.fs.normalize(file))
          if #files >= MAX_FILES then
            break
          end
        end
      end
      vim.schedule(function()
        callback(files)
      end)
    end)
    return
  end

  if vim.fn.executable("rg") == 1 then
    vim.system(
      { "rg", "--files", "--no-messages", "--color", "never", "-g", "!.git" },
      { cwd = cwd, text = true },
      function(obj)
        local files = {}
        if obj.code == 0 and obj.stdout then
          local q = query:lower()
          for file in vim.gsplit(vim.trim(obj.stdout), "\n", { plain = true, trimempty = true }) do
            local norm = vim.fs.normalize(file)
            if q == "" or norm:lower():find(q, 1, true) then
              table.insert(files, norm)
              if #files >= MAX_FILES then
                break
              end
            end
          end
        end
        vim.schedule(function()
          callback(files)
        end)
      end
    )
    return
  end

  local pattern = query ~= "" and ("**/*" .. query .. "*") or "**/*"
  local files = vim.fn.globpath(cwd, pattern, false, true)
  local out = {}
  for i = 1, math.min(#files, MAX_FILES) do
    table.insert(out, vim.fs.normalize(files[i]))
  end
  callback(out)
end

---@param line string
---@param col integer
---@return "slash"|"at"|nil kind, string|nil query, string|nil cmd, string|nil arg
local function prompt_context(line, col, row)
  local before = line:sub(1, col)

  if row == 1 and before:match("^/") then
    local cmd, arg = before:match("^/(%S*)%s*(.*)$")
    if cmd ~= nil then
      return "slash", before, cmd:lower(), vim.trim(arg or "")
    end
  end

  local at_start = before:match("(@[%w%./%-_%:]*)$")
  if at_start then
    return "at", at_start:sub(2), nil, nil
  end

  return nil, nil, nil, nil
end

---@param cmd string
---@param arg string
---@return table[]
local function slash_items(cmd, arg)
  if cmd == "" then
    local items = {}
    for _, spec in ipairs(SLASH_COMMANDS) do
      table.insert(items, {
        label = "/" .. spec.cmd,
        desc = spec.desc,
        insert = "/" .. spec.cmd .. " ",
      })
    end
    return items
  end

  for _, spec in ipairs(SLASH_COMMANDS) do
    if spec.cmd == cmd or (spec.short and spec.short == cmd) then
      if spec.cmd == "mode" then
        local modes = { "agent", "plan", "ask" }
        local items = {}
        for _, mode in ipairs(modes) do
          if arg == "" or mode:find("^" .. vim.pesc(arg)) then
            table.insert(items, {
              label = "/mode " .. mode,
              desc = "Switch to " .. mode .. " mode",
              insert = "/mode " .. mode,
            })
          end
        end
        return items
      elseif spec.cmd == "model" then
        local items = {}
        for _, model in ipairs(config.get().models or {}) do
          if arg == "" or model:find("^" .. vim.pesc(arg)) then
            table.insert(items, {
              label = "/model " .. model,
              desc = "Use model " .. model,
              insert = "/model " .. model,
            })
          end
        end
        return items
      elseif spec.cmd == "cli" then
        local items = {}
        for _, cli in ipairs(agent.discover()) do
          if arg == "" or cli.id:find("^" .. vim.pesc(arg)) then
            table.insert(items, {
              label = "/cli " .. cli.id,
              desc = cli.label,
              insert = "/cli " .. cli.id,
            })
          end
        end
        return items
      elseif spec.cmd == "queue" and arg ~= "" then
        return {
          {
            label = "/queue clear",
            desc = "Clear queued prompts",
            insert = "/queue clear",
          },
        }
      elseif spec.cmd == "refs" or spec.cmd == "selections" then
        if arg == "clear" then
          return {
            {
              label = "/" .. spec.cmd .. " clear",
              desc = "Clear all pending code selections",
              insert = "/" .. spec.cmd .. " clear",
            },
          }
        end
        local items = {
          {
            label = "/" .. spec.cmd .. " clear",
            desc = "Clear all pending code selections",
            insert = "/" .. spec.cmd .. " clear",
          },
        }
        for i = 1, 9 do
          table.insert(items, {
            label = "/" .. spec.cmd .. " " .. tostring(i),
            desc = "Remove code selection #" .. tostring(i),
            insert = "/" .. spec.cmd .. " " .. tostring(i),
          })
        end
        return items
      elseif spec.cmd == "attach" and arg ~= "" then
        return {
          {
            label = "/attach clear",
            desc = "Clear pending attachments",
            insert = "/attach clear",
          },
        }
      elseif spec.cmd == "pending" and arg ~= "" then
        return {
          {
            label = "/pending clear",
            desc = "Clear all pending refs and attachments",
            insert = "/pending clear",
          },
        }
      end
      return {
        {
          label = "/" .. spec.cmd,
          desc = spec.desc,
          insert = "/" .. spec.cmd .. " ",
        },
      }
    end
  end

  local items = {}
  for _, spec in ipairs(SLASH_COMMANDS) do
    if spec.cmd:find("^" .. vim.pesc(cmd)) or (spec.short and spec.short:find("^" .. vim.pesc(cmd))) then
      table.insert(items, {
        label = "/" .. spec.cmd,
        desc = spec.desc,
        insert = "/" .. spec.cmd .. " ",
      })
    end
  end
  return items
end

---@param bufnr integer
---@param items table[]
---@param replace_start integer
---@param replace_end integer
local function ui_select(bufnr, items, replace_start, replace_end)
  if #items == 0 then
    return
  end
  local labels = vim.tbl_map(function(item)
    return item.label .. " — " .. (item.desc or "")
  end, items)
  vim.ui.select(labels, { prompt = "Agent prompt" }, function(choice, idx)
    if not choice or not idx then
      return
    end
    local item = items[idx]
    if not item then
      return
    end
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    local new_line = line:sub(1, replace_start - 1) .. item.insert .. line:sub(replace_end + 1)
    vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { new_line })
    local winid = vim.fn.bufwinid(bufnr)
    if winid >= 0 then
      vim.api.nvim_win_set_cursor(winid, { row, replace_start + #item.insert })
    end
  end)
end

--- Open snacks file picker and insert @path at the current @ token.
---@param bufnr integer
function M.pick_file_reference(bufnr)
  local row, start_col, end_col = M.at_token_range(bufnr)
  if not start_col then
    local winid = vim.fn.bufwinid(bufnr)
    if winid >= 0 then
      row, start_col = vim.api.nvim_win_get_cursor(winid)[1], vim.api.nvim_win_get_cursor(winid)[2]
      end_col = start_col
    else
      return
    end
  end

  local ok, picker = pcall(require, "snacks.picker")
  if ok then
    picker.files({
      title = "@ File reference",
      confirm = function(p, item)
        p:close()
        if item and item.file then
          vim.schedule(function()
            M.insert_file_reference(bufnr, item.file, row, start_col, end_col)
          end)
        end
      end,
    })
    return
  end

  M.collect_files("", function(files)
    local labels = vim.tbl_map(function(path)
      return rel_path(path)
    end, files)
    vim.ui.select(labels, { prompt = "@ File reference" }, function(choice, idx)
      if choice and files[idx] then
        M.insert_file_reference(bufnr, files[idx], row, start_col, end_col)
      end
    end)
  end)
end

--- Fallback when blink.cmp is not active: open menu right after @ or /.
---@param bufnr integer
function M.setup_input(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.b.agent_prompt_complete then
    return
  end
  vim.b.agent_prompt_complete = true

  vim.api.nvim_create_autocmd("InsertCharPre", {
    buffer = bufnr,
    callback = function(ev)
      if vim.bo[ev.buf].filetype ~= "agentprompt" then
        return
      end
      if pcall(require, "blink.cmp") then
        return
      end
      local char = vim.v.char
      if char == "@" then
        vim.schedule(function()
          M.pick_file_reference(ev.buf)
        end)
      elseif char == "/" then
        local row, col = unpack(vim.api.nvim_win_get_cursor(0))
        if row ~= 1 then
          return
        end
        local line = vim.api.nvim_buf_get_lines(ev.buf, row - 1, row, false)[1] or ""
        if col == 1 or line:sub(1, col - 1) == "" then
          vim.schedule(function()
            local items = slash_items("", "")
            ui_select(ev.buf, items, 1, col)
          end)
        end
      end
    end,
  })
end

-- blink.cmp source ------------------------------------------------------------

---@class blink.cmp.Source
local source = {}

function source.new(_opts)
  return setmetatable({}, { __index = source })
end

function source:enabled()
  return vim.bo.filetype == "agentprompt"
end

function source:get_trigger_characters()
  return { "@", "/" }
end

---@param ctx blink.cmp.Context
function source:get_completions(ctx, callback)
  callback = vim.schedule_wrap(callback)
  local row = ctx.cursor[1]
  local col = ctx.cursor[2]
  local kind, query, slash_cmd, slash_arg = prompt_context(ctx.line, col, row)

  if kind == "slash" then
    local items = slash_items(slash_cmd or "", slash_arg or "")
    local start_col = 1
    local end_col = col
    ---@type lsp.CompletionItem[]
    local out = {}
    for _, item in ipairs(items) do
      table.insert(out, {
        label = item.label,
        kind = require("blink.cmp.types").CompletionItemKind.Enum,
        detail = item.desc,
        insertText = item.insert,
        textEdit = {
          newText = item.insert,
          range = {
            start = { line = row - 1, character = start_col - 1 },
            ["end"] = { line = row - 1, character = end_col },
          },
        },
      })
    end
    callback({
      items = out,
      is_incomplete_forward = false,
      is_incomplete_backward = false,
    })
    return
  end

  if kind ~= "at" then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return
  end

  local start_col = col - #(query or "") - 1
  M.collect_files(query or "", function(files)
    ---@type lsp.CompletionItem[]
    local out = {}
    for _, path in ipairs(files) do
      local rel = rel_path(path)
      local insert_text = "@" .. rel
      table.insert(out, {
        label = rel,
        kind = require("blink.cmp.types").CompletionItemKind.File,
        detail = path,
        filterText = rel .. " " .. path,
        textEdit = {
          newText = insert_text,
          range = {
            start = { line = row - 1, character = math.max(0, start_col - 1) },
            ["end"] = { line = row - 1, character = col },
          },
        },
      })
    end
    callback({
      items = out,
      is_incomplete_forward = true,
      is_incomplete_backward = false,
    })
  end)
end

M.blink = source

return M
