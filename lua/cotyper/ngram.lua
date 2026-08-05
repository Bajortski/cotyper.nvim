-- The instant tier: a local n-gram model that learns from your typing.
--
-- uni[w] = count ; bi[w1][w2] = count ; tri["w1 w2"][w3] = count
-- Predictions back off trigram → bigram, and chain greedily up to `lookahead`
-- words. The model persists to disk as JSON and is pruned once it grows large.

local config = require("cotyper.config")
local util = require("cotyper.util")

local M = {}

local cfg = config.values
local model = { uni = {}, bi = {}, tri = {} }
local dirty = false

local function bump(tbl, key, sub)
  local m = tbl[key]
  if not m then
    m = {}
    tbl[key] = m
  end
  m[sub] = (m[sub] or 0) + 1
end

--- Fold a sequence of tokens into the n-gram counts.
---@param tokens string[]
function M.learn(tokens)
  for i = 1, #tokens do
    local w = tokens[i]
    model.uni[w] = (model.uni[w] or 0) + 1
    if i >= 2 then
      bump(model.bi, tokens[i - 1], w)
    end
    if i >= 3 then
      bump(model.tri, tokens[i - 2] .. " " .. tokens[i - 1], w)
    end
  end
  if #tokens > 0 then
    dirty = true
  end
end

-- Highest-count sub-key of a count table, ignoring a given prefix word.
local function argmax(counts, avoid)
  local best, best_n = nil, 0
  if not counts then
    return nil
  end
  for w, n in pairs(counts) do
    if n > best_n and w ~= avoid then
      best, best_n = w, n
    end
  end
  return best
end

--- Best next word by trigram → bigram backoff.
---@param tokens string[]
---@return string|nil
function M.next_word(tokens)
  local n = #tokens
  if n >= 2 then
    local w = argmax(model.tri[tokens[n - 1] .. " " .. tokens[n]])
    if w then
      return w
    end
  end
  if n >= 1 then
    local w = argmax(model.bi[tokens[n]])
    if w then
      return w
    end
  end
  return nil
end

-- Greedily predict up to `budget` further words, feeding each back into the context.
-- Stops on a dead end or a short repetition cycle so we don't ghost "the the the...".
local function chain(tokens, budget)
  local ctx = vim.list_slice and vim.list_slice(tokens, 1, #tokens) or { unpack(tokens) }
  local out = {}
  for _ = 1, math.max(0, budget) do
    local w = M.next_word(ctx)
    if not w then
      break
    end
    if #out >= 1 and out[#out] == w then
      break -- immediate repeat
    end
    if #out >= 2 and out[#out - 1] == w then
      break -- two-word cycle (a b a b ...)
    end
    out[#out + 1] = w
    ctx[#ctx + 1] = w
  end
  return out
end

--- Highest-count vocab word beginning with `prefix` (lowercased), other than prefix itself.
---@param prefix string
---@return string|nil
function M.complete_prefix(prefix)
  local p = prefix:lower()
  local best, best_n = nil, 0
  for w, n in pairs(model.uni) do
    if n > best_n and #w > #p and w:sub(1, #p) == p then
      best, best_n = w, n
    end
  end
  return best
end

--- Build the ghost text for a before-cursor string: complete the current word (if
--- mid-word) and/or chain up to `lookahead` predicted words. "" means no suggestion.
---@param before string
---@return string
function M.build_text(before)
  local tokens = util.words_of(before)
  if before:match("[%w']$") then
    -- mid-word: finish the partial word, then chain the rest up to the lookahead budget.
    local partial = before:match("[%w']+$")
    local word = M.complete_prefix(partial)
    if not word then
      return ""
    end
    local text = word:sub(#partial + 1)
    tokens[#tokens] = word -- the completed word is now the last context token
    for _, w in ipairs(chain(tokens, cfg.lookahead - 1)) do
      text = text .. " " .. w
    end
    return text
  else
    -- word boundary: chain up to `lookahead` next words.
    local text, sep = "", (before:match("%s$") and "" or " ")
    for _, w in ipairs(chain(tokens, cfg.lookahead)) do
      text = text .. sep .. w
      sep = " "
    end
    return text
  end
end

-- ── persistence ──────────────────────────────────────────────────────────────

local function prune()
  local count = 0
  for _ in pairs(model.uni) do
    count = count + 1
  end
  if count <= cfg.prune_cap then
    return
  end
  local function sweep(tbl, nested)
    for k, v in pairs(tbl) do
      if nested then
        for k2, n in pairs(v) do
          if n < cfg.min_count then
            v[k2] = nil
          end
        end
        if next(v) == nil then
          tbl[k] = nil
        end
      elseif v < cfg.min_count then
        tbl[k] = nil
      end
    end
  end
  sweep(model.uni, false)
  sweep(model.bi, true)
  sweep(model.tri, true)
end

--- Persist the model if it has changed since the last save.
function M.save()
  if not dirty then
    return
  end
  prune()
  local path = config.data_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, encoded = pcall(vim.json.encode, model)
  if not ok then
    return
  end
  if util.write_file(path, encoded) then
    dirty = false
  end
end

--- Load a previously saved model, if one exists.
function M.load()
  local content = util.read_file(config.data_path())
  if not content then
    return
  end
  local ok, parsed = pcall(vim.json.decode, content)
  if ok and type(parsed) == "table" then
    model.uni = parsed.uni or {}
    model.bi = parsed.bi or {}
    model.tri = parsed.tri or {}
  end
end

return M
