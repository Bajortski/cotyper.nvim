-- The ghost: eligibility, cursor context, inline extmark rendering, and
-- acceptance. Owns the single pending suggestion and the debounce timer.

local api = vim.api
local uv = vim.uv or vim.loop

local config = require("cotyper.config")
local util = require("cotyper.util")

local M = {}

local cfg = config.values
local ns = api.nvim_create_namespace("cotyper")

local ftset = {} -- eligible filetypes as a set
local current = nil -- { buf, row, col, text } — text is the un-accepted remainder
local trigger_timer = nil
local enabled = true

--- True for one tick after an accept, so the resulting TextChangedI doesn't wipe
--- the words the author hasn't taken yet.
M.squelch = false

--- Rebuild the filetype allow-set from the current config.
function M.refresh_filetypes()
  ftset = {}
  for _, ft in ipairs(cfg.filetypes or {}) do
    ftset[ft] = true
  end
end

function M.set_hl()
  local h = cfg.highlight
  if type(h) == "string" then
    api.nvim_set_hl(0, "CotyperGhost", { link = h })
  else
    api.nvim_set_hl(0, "CotyperGhost", h)
  end
end

--- Toggle the plugin. Returns the new state.
---@return boolean
function M.toggle()
  enabled = not enabled
  if not enabled then
    M.clear()
  end
  return enabled
end

--- Drop any pending ghost and stop a scheduled recompute.
function M.clear()
  if trigger_timer then
    trigger_timer:stop()
    trigger_timer:close()
    trigger_timer = nil
  end
  if current then
    pcall(api.nvim_buf_clear_namespace, current.buf, ns, 0, -1)
  end
  current = nil
end

local function render()
  if not current or current.text == "" then
    M.clear()
    return
  end
  api.nvim_buf_clear_namespace(current.buf, ns, 0, -1)
  pcall(api.nvim_buf_set_extmark, current.buf, ns, current.row, current.col, {
    virt_text = { { current.text, "CotyperGhost" } },
    virt_text_pos = "inline",
    -- "replace" so the ghost renders purely as CotyperGhost; "combine" lets a background
    -- highlight under the cursor (matchparen, autopairs) bleed into the ghost text.
    hl_mode = "replace",
  })
end

--- Show `text` as the ghost at a known position.
function M.show(buf, row, col, text)
  current = { buf = buf, row = row, col = col, text = text }
  render()
end

--- Is `buf` one we suggest in? (enabled + normal buffer + filetype gate)
---@param buf integer
---@return boolean
function M.eligible(buf)
  if not enabled then
    return false
  end
  if vim.bo[buf].buftype ~= "" then
    return false
  end
  if next(ftset) == nil then
    return true
  end
  return ftset[vim.bo[buf].filetype] == true
end

--- Buffer, row, col and before-cursor text, or nil if we shouldn't suggest here.
---@return integer|nil buf, integer|nil row, integer|nil col, string|nil before
function M.cursor_prefix()
  local buf = api.nvim_get_current_buf()
  if not M.eligible(buf) then
    return nil
  end
  local pos = api.nvim_win_get_cursor(0)
  local row, col = pos[1] - 1, pos[2]
  local line = api.nvim_get_current_line()
  if col < #line then
    return nil -- only complete at end of line
  end
  local before = line:sub(1, col)
  if not before:find("%S") then
    return nil -- blank / whitespace-only prefix
  end
  return buf, row, col, before
end

--- Hide any stale ghost, then recompute once typing pauses for `debounce` ms.
function M.schedule_trigger()
  M.clear() -- also stops any pending timer; don't show an out-of-date ghost mid-type
  if (cfg.debounce or 0) <= 0 then
    require("cotyper").trigger()
    return
  end
  trigger_timer = uv.new_timer()
  trigger_timer:start(cfg.debounce, 0, function()
    trigger_timer:stop()
    trigger_timer:close()
    trigger_timer = nil
    util.dbg("debounce fired after " .. cfg.debounce .. "ms idle -> triggering")
    vim.schedule(function()
      require("cotyper").trigger()
    end)
  end)
end

-- ── acceptance ───────────────────────────────────────────────────────────────

---@return boolean
function M.is_visible()
  return current ~= nil and current.text ~= ""
end

--- Accept the next word (leading spaces + one word) of the ghost.
---@return boolean accepted
function M.accept_word()
  if not M.is_visible() then
    return false
  end
  local t = current.text
  local lead = t:match("^%s+") or ""
  local rest = t:sub(#lead + 1)
  local word = rest:match("^%S+") or ""
  local chunk = lead .. word
  if chunk == "" then
    M.clear()
    return false
  end

  local buf, row, col = current.buf, current.row, current.col
  -- The insert + cursor move below fire TextChangedI/CursorMovedI; squelch the resulting
  -- recompute for this tick so the un-accepted words survive instead of being cleared.
  M.squelch = true
  api.nvim_buf_set_text(buf, row, col, row, col, { chunk })
  local newcol = col + #chunk
  api.nvim_win_set_cursor(0, { row + 1, newcol })

  local remaining = current.text:sub(#chunk + 1)
  if remaining == "" then
    M.clear()
    require("cotyper").trigger() -- phrase exhausted: fetch a fresh continuation
  else
    M.show(buf, row, newcol, remaining)
  end
  vim.schedule(function()
    M.squelch = false
  end)
  return true
end

--- Accept the whole remaining ghost at once.
---@return boolean accepted
function M.accept_all()
  if not M.is_visible() then
    return false
  end
  local buf, row, col, chunk = current.buf, current.row, current.col, current.text
  api.nvim_buf_set_text(buf, row, col, row, col, { chunk })
  api.nvim_win_set_cursor(0, { row + 1, col + #chunk })
  M.clear()
  return true
end

return M
