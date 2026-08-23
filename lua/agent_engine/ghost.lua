-- File: lua/agent_engine/ghost.lua
-- Inline ghost review: proposed agent edits overlaid on the current buffer,
-- with per-hunk accept/reject, next/prev navigation, and accept-all.

local config = require("agent_engine.config")
local storage = require("agent_engine.storage")

local M = {}

local NS = vim.api.nvim_create_namespace("AgentEngineGhost")
local SIGN_GROUP = "AgentEngineGhost"

---@class GhostHunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field status "pending"|"accepted"|"rejected"
---@field display_line integer|nil

---@class GhostReview
---@field bufnr integer
---@field filepath string
---@field old_lines string[]
---@field new_lines string[]
---@field hunks GhostHunk[]
---@field current integer

---@type table<integer, GhostReview>
local reviews = {}

local function define_highlights()
  vim.api.nvim_set_hl(0, "AgentEngineGhostOld", { default = true, link = "DiffDelete" })
  vim.api.nvim_set_hl(0, "AgentEngineGhostNew", { default = true, link = "DiffAdd" })
  vim.api.nvim_set_hl(0, "AgentEngineGhostCurrent", {
    default = true,
    bold = true,
    underline = true,
  })
  pcall(vim.fn.sign_define, "AgentEngineGhostHunk", {
    text = "┃",
    texthl = "DiffChange",
    numhl = "DiffChange",
  })
  pcall(vim.fn.sign_define, "AgentEngineGhostCurrent", {
    text = "▶",
    texthl = "DiffText",
    numhl = "DiffText",
  })
end

---@param old_lines string[]
---@param new_lines string[]
---@return GhostHunk[]
local function compute_hunks(old_lines, new_lines)
  local a = table.concat(old_lines, "\n")
  local b = table.concat(new_lines, "\n")
  local indices = vim.diff(a, b, { result_type = "indices", algorithm = "myers" })
  if type(indices) ~= "table" then
    return {}
  end

  local hunks = {}
  for _, h in ipairs(indices) do
    if type(h) == "table" and #h >= 4 then
      table.insert(hunks, {
        old_start = h[1],
        old_count = h[2],
        new_start = h[3],
        new_count = h[4],
        status = "pending",
        display_line = nil,
      })
    end
  end
  return hunks
end

--- Compose buffer lines from old/new + hunk decisions.
--- Pending/rejected hunks keep the old side; accepted take the new side.
---@param review GhostReview
---@return string[]
local function compose(review)
  local old_lines = review.old_lines
  local new_lines = review.new_lines
  local result = {}
  local old_i = 1
  local n_old = #old_lines

  for _, h in ipairs(review.hunks) do
    if h.old_count == 0 then
      -- Insertion after old_start.
      while old_i <= h.old_start and old_i <= n_old do
        table.insert(result, old_lines[old_i])
        old_i = old_i + 1
      end
      h.display_line = #result
      if h.status == "accepted" then
        for j = 0, h.new_count - 1 do
          local line = new_lines[h.new_start + j]
          if line ~= nil then
            table.insert(result, line)
          end
        end
      end
    else
      while old_i < h.old_start and old_i <= n_old do
        table.insert(result, old_lines[old_i])
        old_i = old_i + 1
      end
      h.display_line = #result + 1

      if h.status == "accepted" then
        for j = 0, h.new_count - 1 do
          local line = new_lines[h.new_start + j]
          if line ~= nil then
            table.insert(result, line)
          end
        end
      else
        for j = 0, h.old_count - 1 do
          local line = old_lines[h.old_start + j]
          if line ~= nil then
            table.insert(result, line)
          end
        end
      end
      old_i = h.old_start + h.old_count
    end
  end

  while old_i <= n_old do
    table.insert(result, old_lines[old_i])
    old_i = old_i + 1
  end

  return result
end

---@param review GhostReview
---@return integer[]
local function pending_indices(review)
  local out = {}
  for i, h in ipairs(review.hunks) do
    if h.status == "pending" then
      table.insert(out, i)
    end
  end
  return out
end

---@param review GhostReview
local function clear_decorations(review)
  if vim.api.nvim_buf_is_valid(review.bufnr) then
    vim.api.nvim_buf_clear_namespace(review.bufnr, NS, 0, -1)
    pcall(vim.fn.sign_unplace, SIGN_GROUP, { buffer = review.bufnr })
  end
end

---@param review GhostReview
---@param h GhostHunk
---@param j integer
---@return string
local function new_line_at(review, h, j)
  return review.new_lines[h.new_start + j] or ""
end

---@param review GhostReview
local function render(review)
  if not vim.api.nvim_buf_is_valid(review.bufnr) then
    return
  end

  define_highlights()
  clear_decorations(review)

  local lines = compose(review)
  local bo = vim.bo[review.bufnr]
  local was_modifiable = bo.modifiable
  bo.modifiable = true
  vim.api.nvim_buf_set_lines(review.bufnr, 0, -1, false, lines)
  bo.modifiable = was_modifiable
  bo.modified = true

  local pending = pending_indices(review)
  if #pending == 0 then
    return
  end

  if review.hunks[review.current] == nil or review.hunks[review.current].status ~= "pending" then
    review.current = pending[1]
  end

  local buf_line_count = vim.api.nvim_buf_line_count(review.bufnr)

  for _, hi in ipairs(pending) do
    local h = review.hunks[hi]
    local is_current = hi == review.current
    local anchor = math.max(1, h.display_line or 1)

    if h.old_count > 0 then
      for j = 0, h.old_count - 1 do
        local lnum = anchor + j - 1
        if lnum >= 0 and lnum < buf_line_count then
          vim.api.nvim_buf_set_extmark(review.bufnr, NS, lnum, 0, {
            end_line = lnum + 1,
            end_col = 0,
            hl_group = is_current and "AgentEngineGhostCurrent" or "AgentEngineGhostOld",
            hl_eol = true,
            priority = is_current and 90 or 80,
          })
        end
      end
    end

    if h.new_count > 0 and buf_line_count > 0 then
      local virt = {}
      for j = 0, h.new_count - 1 do
        table.insert(virt, { { "+ " .. new_line_at(review, h, j), "AgentEngineGhostNew" } })
      end

      local virt_row
      if h.old_count == 0 then
        virt_row = math.min(math.max(0, (h.display_line or 1) - 1), buf_line_count - 1)
      else
        virt_row = math.min(math.max(0, anchor + h.old_count - 2), buf_line_count - 1)
      end

      vim.api.nvim_buf_set_extmark(review.bufnr, NS, virt_row, 0, {
        virt_lines = virt,
        virt_lines_above = false,
        priority = is_current and 95 or 85,
      })
    end

    local sign_name = is_current and "AgentEngineGhostCurrent" or "AgentEngineGhostHunk"
    local sign_line = math.max(1, math.min(h.display_line or 1, buf_line_count))
    pcall(vim.fn.sign_place, 0, SIGN_GROUP, sign_name, review.bufnr, {
      lnum = sign_line,
      priority = 20,
    })
  end
end

---@param review GhostReview
local function jump_to_current(review)
  local h = review.hunks[review.current]
  if not h or not vim.api.nvim_buf_is_valid(review.bufnr) then
    return
  end
  local lnum = math.max(1, h.display_line or 1)
  local line_count = vim.api.nvim_buf_line_count(review.bufnr)
  lnum = math.min(lnum, line_count)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == review.bufnr then
      pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
      pcall(vim.api.nvim_win_call, win, function()
        vim.cmd("normal! zz")
      end)
      break
    end
  end
end

---@param review GhostReview
---@param delta integer
---@return boolean
local function move_current(review, delta)
  local pending = pending_indices(review)
  if #pending == 0 then
    return false
  end

  local pos = 1
  for i, hi in ipairs(pending) do
    if hi == review.current then
      pos = i
      break
    end
  end
  pos = pos + delta
  if pos < 1 then
    pos = #pending
  elseif pos > #pending then
    pos = 1
  end
  review.current = pending[pos]
  render(review)
  jump_to_current(review)
  return true
end

---@param bufnr integer
---@param filepath string
---@param write_disk boolean
local function finish_review(bufnr, filepath, write_disk)
  local review = reviews[bufnr]
  if not review then
    return
  end

  clear_decorations(review)
  M.unbind_keymaps(bufnr)
  reviews[bufnr] = nil
  storage.clear_transaction(filepath)

  if write_disk and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("write!")
    end)
  end
end

---@param bufnr integer
function M.unbind_keymaps(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local km = config.get().keymaps
  for _, lhs in ipairs({
    km.accept_change,
    km.reject_change,
    km.accept_all,
    km.reject_all,
    km.next_hunk,
    km.prev_hunk,
  }) do
    if type(lhs) == "string" and lhs ~= "" then
      pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
    end
  end
end

---@param bufnr integer
local function bind_keymaps(bufnr)
  local km = config.get().keymaps
  local function map(lhs, fn, desc)
    if type(lhs) ~= "string" or lhs == "" then
      return
    end
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, desc = desc })
  end

  map(km.accept_change, function()
    M.accept_hunk(bufnr)
  end, "Accept current ghost hunk")
  map(km.reject_change, function()
    M.reject_hunk(bufnr)
  end, "Reject current ghost hunk")
  map(km.accept_all, function()
    M.accept_all(bufnr)
  end, "Accept all ghost hunks in file")
  map(km.reject_all, function()
    M.reject_all(bufnr)
  end, "Reject all ghost hunks in file")
  map(km.next_hunk, function()
    M.next_hunk(bufnr)
  end, "Next ghost hunk")
  map(km.prev_hunk, function()
    M.prev_hunk(bufnr)
  end, "Previous ghost hunk")
end

--- Start (or replace) a ghost review for a buffer.
---@param bufnr integer
---@param filepath string
---@param old_lines string[]
---@param new_lines string[]
---@return boolean
function M.start(bufnr, filepath, old_lines, new_lines)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if type(old_lines) ~= "table" or type(new_lines) ~= "table" then
    return false
  end

  local hunks = compute_hunks(old_lines, new_lines)
  if #hunks == 0 then
    return false
  end

  if reviews[bufnr] then
    clear_decorations(reviews[bufnr])
    M.unbind_keymaps(bufnr)
  end

  ---@type GhostReview
  local review = {
    bufnr = bufnr,
    filepath = filepath,
    old_lines = old_lines,
    new_lines = new_lines,
    hunks = hunks,
    current = 1,
  }
  reviews[bufnr] = review
  bind_keymaps(bufnr)
  render(review)
  jump_to_current(review)

  local km = config.get().keymaps
  vim.notify(
    string.format(
      "Ghost review: %d edit(s). %s accept · %s reject · %s accept-all · %s reject-all · %s/%s hunks",
      #hunks,
      km.accept_change,
      km.reject_change,
      km.accept_all,
      km.reject_all,
      km.next_hunk,
      km.prev_hunk
    ),
    vim.log.levels.INFO
  )
  return true
end

---@param bufnr integer|nil
---@return GhostReview|nil
function M.get(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return reviews[bufnr]
end

---@param bufnr integer|nil
---@return boolean
function M.is_active(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return reviews[bufnr] ~= nil
end

--- Active ghost reviews plus on-disk pending transactions, sorted like a tree walk.
---@param exclude string|nil
---@return string[]
local function pending_file_queue(exclude)
  local seen = {}
  local paths = {}

  local function add(path)
    if type(path) ~= "string" or path == "" then
      return
    end
    local norm = vim.fs.normalize(path)
    if not norm or norm == "" or seen[norm] then
      return
    end
    if exclude and vim.fs.normalize(exclude) == norm then
      return
    end
    seen[norm] = true
    table.insert(paths, norm)
  end

  for _, review in pairs(reviews) do
    add(review.filepath)
  end
  for _, path in ipairs(storage.list_pending()) do
    add(path)
  end

  table.sort(paths)
  return paths
end

--- Open the next file (path order) that still has pending agent changes.
---@param after_filepath string|nil
---@return boolean
function M.goto_next_pending_file(after_filepath)
  local queue = pending_file_queue(after_filepath)
  if #queue == 0 then
    vim.notify("No more files with pending agent changes", vim.log.levels.INFO)
    return false
  end

  local next_path = queue[1]
  if after_filepath then
    local after = vim.fs.normalize(after_filepath)
    local found_after = false
    for _, path in ipairs(queue) do
      if path > after then
        next_path = path
        found_after = true
        break
      end
    end
    if not found_after then
      next_path = queue[1]
    end
  end

  local chat = require("agent_engine.chat")
  local bufnr = chat.open_file_in_editor(next_path)
  if not bufnr then
    vim.notify("Could not open " .. next_path, vim.log.levels.ERROR)
    return false
  end

  if not reviews[bufnr] then
    local state = storage.load_transaction(next_path)
    if state and state.shadow_path and vim.fn.filereadable(state.shadow_path) == 1 then
      local new_lines = vim.fn.readfile(state.shadow_path)
      local old_lines
      if state.base_path and vim.fn.filereadable(state.base_path) == 1 then
        old_lines = vim.fn.readfile(state.base_path)
      else
        old_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      end
      if type(new_lines) == "table" and type(old_lines) == "table" then
        -- Show the pre-agent version so ghost overlays make sense.
        local bo = vim.bo[bufnr]
        local was_modifiable = bo.modifiable
        bo.modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, old_lines)
        bo.modifiable = was_modifiable
        M.start(bufnr, next_path, old_lines, new_lines)
      end
    end
  end

  if reviews[bufnr] then
    jump_to_current(reviews[bufnr])
  end

  vim.notify("Next review: " .. vim.fn.fnamemodify(next_path, ":."), vim.log.levels.INFO)
  return true
end

---@param review GhostReview
local function after_decision(review)
  local pending = pending_indices(review)
  if #pending == 0 then
    local finished = review.filepath
    render(review)
    finish_review(review.bufnr, review.filepath, true)
    vim.notify("Ghost review complete — file saved", vim.log.levels.INFO)
    vim.schedule(function()
      M.goto_next_pending_file(finished)
    end)
    return
  end

  local next_hi = pending[1]
  for _, hi in ipairs(pending) do
    if hi >= review.current then
      next_hi = hi
      break
    end
  end
  review.current = next_hi
  render(review)
  jump_to_current(review)
  vim.notify(string.format("Ghost: %d edit(s) remaining", #pending), vim.log.levels.INFO)
end

---@param bufnr integer|nil
function M.accept_hunk(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local review = reviews[bufnr]
  if not review then
    vim.notify("No ghost review active", vim.log.levels.WARN)
    return
  end
  local h = review.hunks[review.current]
  if not h or h.status ~= "pending" then
    move_current(review, 1)
    return
  end
  h.status = "accepted"
  after_decision(review)
end

---@param bufnr integer|nil
function M.reject_hunk(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local review = reviews[bufnr]
  if not review then
    vim.notify("No ghost review active", vim.log.levels.WARN)
    return
  end
  local h = review.hunks[review.current]
  if not h or h.status ~= "pending" then
    move_current(review, 1)
    return
  end
  h.status = "rejected"
  after_decision(review)
end

---@param bufnr integer|nil
function M.accept_all(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local review = reviews[bufnr]
  if not review then
    vim.notify("No ghost review active", vim.log.levels.WARN)
    return
  end
  local finished = review.filepath
  for _, h in ipairs(review.hunks) do
    if h.status == "pending" then
      h.status = "accepted"
    end
  end
  render(review)
  finish_review(bufnr, finished, true)
  vim.notify("Accepted all agent edits", vim.log.levels.INFO)
  vim.schedule(function()
    M.goto_next_pending_file(finished)
  end)
end

---@param bufnr integer|nil
function M.reject_all(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local review = reviews[bufnr]
  if not review then
    vim.notify("No ghost review active", vim.log.levels.WARN)
    return
  end
  local finished = review.filepath
  for _, h in ipairs(review.hunks) do
    if h.status == "pending" then
      h.status = "rejected"
    end
  end
  render(review)
  finish_review(bufnr, finished, true)
  vim.notify("Rejected all agent edits", vim.log.levels.WARN)
  vim.schedule(function()
    M.goto_next_pending_file(finished)
  end)
end

---@param bufnr integer|nil
function M.next_hunk(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local review = reviews[bufnr]
  if review then
    move_current(review, 1)
  end
end

---@param bufnr integer|nil
function M.prev_hunk(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local review = reviews[bufnr]
  if review then
    move_current(review, -1)
  end
end

---@param bufnr integer
function M.clear(bufnr)
  local review = reviews[bufnr]
  if not review then
    return
  end
  clear_decorations(review)
  M.unbind_keymaps(bufnr)
  reviews[bufnr] = nil
end

return M
