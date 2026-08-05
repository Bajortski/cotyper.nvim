-- Small helpers shared across the tiers: debug notifications, word splitting,
-- file reading, and the overlap trimmer that keeps LLM output from repeating the
-- words already on the page.

local config = require("cotyper.config")

local M = {}

--- Debug notify. A no-op unless `debug` is set; scheduled so it is safe to call
--- from libuv callbacks.
---@param msg string
---@param level integer|nil
function M.dbg(msg, level)
  if config.values.debug then
    vim.schedule(function()
      vim.notify("cotyper: " .. msg, level or vim.log.levels.INFO)
    end)
  end
end

--- Lowercased word tokens of a string.
---@param str string
---@return string[]
function M.words_of(str)
  local out = {}
  for w in str:gmatch("[%w']+") do
    out[#out + 1] = w:lower()
  end
  return out
end

--- Read a file, returning nil when missing or blank.
---@param path string
---@return string|nil
function M.read_file(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  if content and content:match("%S") then
    return content
  end
  return nil
end

--- Write `text` to `path`, returning whether it succeeded.
---@param path string
---@param text string
---@return boolean
function M.write_file(path, text)
  local fd = io.open(path, "w")
  if not fd then
    return false
  end
  fd:write(text)
  fd:close()
  return true
end

-- Models often echo the last word(s) already typed ("...contextual" -> "contextual aware").
-- Drop any leading words of `cont` that repeat the tail of `before` (case-insensitive,
-- ignoring surrounding punctuation), so the suggestion picks up where the author left off.
---@param before string
---@param cont string
---@return string
function M.strip_overlap(before, cont)
  local function split(s)
    local t = {}
    for w in s:gmatch("%S+") do
      t[#t + 1] = w
    end
    return t
  end
  local function norm(w)
    return w:lower():gsub("^%p+", ""):gsub("%p+$", "")
  end
  local bw, cw = split(before), split(cont)
  local maxn = math.min(#bw, #cw, 8)
  local best = 0
  for n = 1, maxn do
    local match = true
    for i = 1, n do
      if norm(bw[#bw - n + i]) ~= norm(cw[i]) then
        match = false
        break
      end
    end
    if match then
      best = n
    end
  end
  for _ = 1, best do
    cont = cont:gsub("^%s*%S+", "", 1)
  end
  return (cont:gsub("^%s+", ""))
end

--- Strip a model's reasoning block and surrounding blank space.
---@param s string
---@return string
function M.strip_thinking(s)
  return (s:gsub("<think>.-</think>", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

return M
