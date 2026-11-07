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

--- Tidy raw model output into one ghost-sized phrase: first line only, no wrapping
--- quotes or fences, cut after the first sentence ending, and — when generation hit
--- the token limit — without the half-generated last word.
---@param s string
---@param truncated boolean|nil
---@return string
-- Wrapping quotes a model may put around its answer. Matched as whole strings: the
-- curly ones are multibyte, so a Lua character class would chew stray UTF-8 bytes.
local quotes = { '"', "'", "`", "“", "”", "‘", "’" }

local function unquote(s)
  local changed = true
  while changed do
    changed = false
    for _, q in ipairs(quotes) do
      if s:sub(1, #q) == q then
        s, changed = s:sub(#q + 1), true
      end
      if #s >= #q and s:sub(-#q) == q then
        s, changed = s:sub(1, -#q - 1), true
      end
    end
  end
  return s
end

function M.clip_completion(s, truncated)
  s = unquote(s:match("^[^\r\n]*"):gsub("^%s+", ""):gsub("%s+$", ""))
  local sentence = s:match("^(.-[%.!?;][\"')%]]?)%s")
  if sentence then
    return sentence
  end
  if truncated and not s:match("[%.!?;]$") then
    s = s:gsub("%s+%S+$", "")
  end
  return s
end

local function normalized(s)
  return " " .. s:lower():gsub("[^%w']+", " "):gsub("^%s+", ""):gsub("%s+$", "") .. " "
end

--- Does `text` (three words or more) already appear verbatim in `context`? Small
--- models love to copy a nearby line back out; such a ghost is never what's wanted.
---@param context string
---@param text string
---@return boolean
function M.echoes(context, text)
  local t = normalized(text)
  local _, words = t:gsub("%S+", "")
  if words < 3 then
    return false
  end
  return normalized(context):find(t, 1, true) ~= nil
end

-- Words that can't follow one another: "a the", "the my", …
local determiners = {}
for _, w in ipairs({ "a", "an", "the", "my", "your", "his", "her", "its", "our", "their" }) do
  determiners[w] = true
end

--- When `before` ends on a determiner, drop a determiner the model opened with
--- ("…the point is that a" + "the system" → "system").
---@param before string
---@param cont string
---@return string
function M.drop_double_determiner(before, cont)
  local last = (before:match("([%w']+)%s*$") or ""):lower()
  local first = (cont:match("^%s*([%w']+)") or ""):lower()
  if determiners[last] and determiners[first] then
    return (cont:gsub("^%s*[%w']+%s*", "", 1))
  end
  return cont
end

--- Strip a model's reasoning block and surrounding blank space.
---@param s string
---@return string
function M.strip_thinking(s)
  return (s:gsub("<think>.-</think>", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

return M
