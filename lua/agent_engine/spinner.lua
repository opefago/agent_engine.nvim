-- Spinner frames for agent chat streaming preview.
-- Prefers noice.nvim's cli-spinners collection when available; otherwise uses
-- the built-in braille dots (same as the original chat.lua reference).

local config = require("agent_engine.config")

local M = {}

--- Original chat.lua spinner (10-frame circle) — kept as reference.
-- local ORIGINAL_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- Braille terminal spinner with a longer frame cycle (cli-spinners "dots6").
local FALLBACK_FRAMES = {
  "⠁",
  "⠉",
  "⠙",
  "⠚",
  "⠒",
  "⠂",
  "⠂",
  "⠒",
  "⠲",
  "⠴",
  "⠤",
  "⠄",
  "⠄",
  "⠤",
  "⠴",
  "⠲",
  "⠒",
  "⠂",
  "⠂",
  "⠒",
  "⠚",
  "⠙",
  "⠉",
  "⠁",
}
local FALLBACK_INTERVAL = 80

---@type false|table|nil
local noice_spinners = nil

---@return table|nil
local function load_noice_spinners()
  if noice_spinners == nil then
    local ok, mod = pcall(require, "noice.util.spinners")
    noice_spinners = ok and mod or false
  end
  if noice_spinners == false then
    return nil
  end
  return noice_spinners
end

---@class AgentEngineSpinnerSpec
---@field frames string[]
---@field interval integer
---@field style string
---@field source "noice"|"fallback"

---@param style string|nil
---@return AgentEngineSpinnerSpec
function M.get(style)
  style = style or config.get().spinner_style or "dots6"

  local noice = load_noice_spinners()
  local spec = noice and noice.spinners and noice.spinners[style]
  if spec and type(spec.frames) == "table" and #spec.frames > 0 then
    return {
      frames = spec.frames,
      interval = spec.interval or FALLBACK_INTERVAL,
      style = style,
      source = "noice",
    }
  end

  return {
    frames = FALLBACK_FRAMES,
    interval = FALLBACK_INTERVAL,
    style = "dots6",
    source = "fallback",
  }
end

---@param style string|nil
---@param frame integer 1-based frame index
---@return string
function M.frame(style, frame)
  local spec = M.get(style)
  local idx = ((math.max(1, frame) - 1) % #spec.frames) + 1
  return spec.frames[idx]
end

---@param style string|nil
---@return integer
function M.interval(style)
  return M.get(style).interval
end

---@return string[]
function M.list_styles()
  local noice = load_noice_spinners()
  if not noice or not noice.spinners then
    return { "dots" }
  end
  local names = vim.tbl_keys(noice.spinners)
  table.sort(names)
  return names
end

return M
