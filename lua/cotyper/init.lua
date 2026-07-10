-- cotyper.nvim — always-on inline autocomplete inspired by the Cotypist macOS app.
-- Two tiers:
--   1. instant: a local n-gram model that learns from your typing and persists to disk.
--   2. smart:   a debounced async call to a local LLM (gemma via Ollama) that supersedes
--               the n-gram guess with a richer continuation when it arrives.
-- Tab (wired in your keymap) accepts the ghost one word at a time; keep typing to reject.

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

local defaults = {
  model = nil, -- REQUIRED for the LLM tier: any Ollama model you've pulled, e.g. "gemma4:e2b-mlx"
  endpoint = "http://localhost:11434/api/chat", -- Ollama native (honours `think`)
  think = false, -- false = no reasoning tokens (fast); only affects thinking-capable models
  filetypes = { "markdown" },
  debounce = 150, -- ms of idle after typing before a suggestion appears (0 = instant)
  order = 3, -- n-gram order (uni/bi/tri)
  lookahead = 5, -- words the n-gram tier predicts ahead (Tab still accepts one at a time)
  min_count = 2, -- prune threshold when the model grows past `prune_cap`
  prune_cap = 15000, -- unique unigrams before pruning kicks in
  save_interval = 60, -- seconds between periodic model saves
  context_lines = 8, -- lines of buffer context sent to the LLM (smaller = faster eval)
  max_tokens = 20, -- num_predict: tokens the LLM generates per completion
  num_ctx = 1024, -- context window; cap it (gemma4 defaults to 128K, which is slow)
  keep_alive = "10m", -- keep the model resident so it doesn't cold-reload after a pause
  llm = true, -- set false to run on the n-gram tier alone
  highlight = { fg = "#808080", italic = true },
  system_prompt = "You are an inline autocomplete engine, like the grey ghost text in a "
    .. "code editor. The user message is a document the author is in the middle of writing; "
    .. "it ends exactly at the cursor, possibly mid-sentence. Output ONLY the text that comes "
    .. "immediately next, so it can be appended verbatim to what they wrote. Continue their "
    .. "current sentence and train of thought — do not restate, rephrase, summarize, answer, "
    .. "greet, or comment. Match the author's tense, tone, and style. Keep it to a single short "
    .. "line, at most one sentence. No new paragraphs, no lists, no quotation marks. If the "
    .. "text ends mid-word, finish that word first. Never repeat words the author has "
    .. "already written; begin with the next new word, not a word already on the page. "
    .. "The author's name is Toast and usually writes in English. Use British English (with "
    .. "-ise spellings) spelling and punctuation. Write in a clear, sardonic voice. Keep "
    .. "sentences short, concise and readable.",
  data_file = nil, -- default: stdpath('data')/cotyper/model.json
  debug = false, -- notify on debounce fire, query start, and query completion
}

local cfg = vim.deepcopy(defaults)
local ns = api.nvim_create_namespace("cotyper")
local ftset = {} -- eligible filetypes as a set

-- Debug notify (no-op unless cfg.debug). Scheduled so it's safe from libuv callbacks.
local function dbg(msg, level)
  if cfg.debug then
    vim.schedule(function()
      vim.notify("cotyper: " .. msg, level or vim.log.levels.INFO)
    end)
  end
end

-- ── n-gram model ─────────────────────────────────────────────────────────────
-- uni[w] = count ; bi[w1][w2] = count ; tri["w1 w2"][w3] = count
local model = { uni = {}, bi = {}, tri = {} }
local dirty = false

-- pending ghost: { buf, row, col, text } — text is the un-accepted remainder.
local current = nil
local trigger_timer = nil
local save_timer = nil
local enabled = true
local squelch = false -- skip the auto-recompute for one tick right after an accept
local llm_seq = 0 -- request generation, to drop stale LLM responses

-- ── helpers ──────────────────────────────────────────────────────────────────

local function words_of(str)
  local out = {}
  for w in str:gmatch("[%w']+") do
    out[#out + 1] = w:lower()
  end
  return out
end

-- Models often echo the last word(s) already typed ("...contextual" -> "contextual aware").
-- Drop any leading words of `cont` that repeat the tail of `before` (case-insensitive,
-- ignoring surrounding punctuation), so the suggestion picks up where the author left off.
local function strip_overlap(before, cont)
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

local function bump(tbl, key, sub)
  local m = tbl[key]
  if not m then
    m = {}
    tbl[key] = m
  end
  m[sub] = (m[sub] or 0) + 1
end

-- Fold a sequence of tokens into the n-gram counts.
local function learn(tokens)
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

-- Best next word by trigram → bigram backoff.
local function next_word(tokens)
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
    local w = next_word(ctx)
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

-- Highest-count vocab word beginning with `prefix` (lowercased), other than prefix itself.
local function complete_prefix(prefix)
  local p = prefix:lower()
  local best, best_n = nil, 0
  for w, n in pairs(model.uni) do
    if n > best_n and #w > #p and w:sub(1, #p) == p then
      best, best_n = w, n
    end
  end
  return best
end

-- ── ghost rendering ──────────────────────────────────────────────────────────

local function set_hl()
  local h = cfg.highlight
  if type(h) == "string" then
    api.nvim_set_hl(0, "CotyperGhost", { link = h })
  else
    api.nvim_set_hl(0, "CotyperGhost", h)
  end
end

local function clear()
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
    clear()
    return
  end
  api.nvim_buf_clear_namespace(current.buf, ns, 0, -1)
  pcall(api.nvim_buf_set_extmark, current.buf, ns, current.row, current.col, {
    virt_text = { { current.text, "CotyperGhost" } },
    virt_text_pos = "inline",
    hl_mode = "combine",
  })
end

-- ── eligibility + trigger ────────────────────────────────────────────────────

local function eligible(buf)
  if not enabled then
    return false
  end
  if api.nvim_buf_get_option(buf, "buftype") ~= "" then
    return false
  end
  if next(ftset) == nil then
    return true
  end
  return ftset[api.nvim_buf_get_option(buf, "filetype")] == true
end

-- Returns before-cursor text, or nil if we shouldn't suggest here.
local function cursor_prefix()
  local buf = api.nvim_get_current_buf()
  if not eligible(buf) then
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
    return nil -- blank / whitespace-only prefix (matches minuet's predicate)
  end
  return buf, row, col, before
end

-- Build the ghost text for a given before-cursor string: complete the current word (if
-- mid-word) and/or chain up to `lookahead` predicted words. Returns "" for no suggestion.
local function build_text(before)
  local tokens = words_of(before)
  if before:match("[%w']$") then
    -- mid-word: finish the partial word, then chain the rest up to the lookahead budget.
    local partial = before:match("[%w']+$")
    local word = complete_prefix(partial)
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

-- Instant n-gram suggestion for the current cursor position.
local function ngram_suggest()
  local buf, row, col, before = cursor_prefix()
  if not before then
    clear()
    return false
  end

  local text = build_text(before)
  if text == "" then
    clear()
    return false
  end
  current = { buf = buf, row = row, col = col, text = text }
  render()
  return true
end

-- ── LLM tier ─────────────────────────────────────────────────────────────────

local warned_no_model = false

local function llm_request()
  if not cfg.llm then
    return
  end
  if not cfg.model or cfg.model == "" then
    if not warned_no_model then
      warned_no_model = true
      vim.schedule(function()
        vim.notify(
          "cotyper: set `model` (an Ollama model you've pulled, e.g. 'gemma4:e2b-mlx') "
            .. "to enable LLM completions, or set `llm = false` to silence this. "
            .. "The n-gram tier works regardless.",
          vim.log.levels.WARN
        )
      end)
    end
    return
  end
  local buf, row, col, before = cursor_prefix()
  if not before then
    return
  end
  if before:match("[%w']$") then
    return -- don't ask the LLM to finish a half-typed word; that's the n-gram's job
  end

  local start = math.max(0, row - cfg.context_lines + 1)
  local ctx = table.concat(api.nvim_buf_get_lines(buf, start, row + 1, false), "\n")
  -- Ollama's native /api/chat honours `think`; the OpenAI-compatible /v1 endpoint does
  -- not, so a thinking model would waste time reasoning before every completion.
  local body = vim.json.encode({
    model = cfg.model,
    stream = false,
    think = cfg.think, -- false = skip reasoning entirely (fast); reasoning models only
    messages = {
      { role = "system", content = cfg.system_prompt },
      { role = "user", content = ctx },
    },
    keep_alive = cfg.keep_alive,
    options = { num_predict = cfg.max_tokens, num_ctx = cfg.num_ctx },
  })

  llm_seq = llm_seq + 1
  local seq = llm_seq
  local t0 = uv.hrtime()
  dbg("query start (" .. tostring(cfg.model) .. ")")

  vim.system({
    "curl", "-s", "-m", "30", cfg.endpoint,
    "-H", "Content-Type: application/json",
    "-d", body,
  }, { text = true }, function(res)
    local ms = math.floor((uv.hrtime() - t0) / 1e6)
    if res.code ~= 0 or not res.stdout or res.stdout == "" then
      dbg("query failed after " .. ms .. "ms (curl code " .. res.code .. ")", vim.log.levels.WARN)
      return
    end
    local ok, parsed = pcall(vim.json.decode, res.stdout)
    if not ok or type(parsed) ~= "table" then
      dbg("query returned unparseable response after " .. ms .. "ms", vim.log.levels.WARN)
      return
    end
    dbg("query complete in " .. ms .. "ms")
    -- Native /api/chat returns { message = { content, thinking } }; reasoning is kept out
    -- of content. Strip any inline <think>…</think> too, in case a template emits it.
    local content = parsed.message and parsed.message.content
    if type(content) ~= "string" then
      return
    end
    content = content:gsub("<think>.-</think>", ""):gsub("^%s+", ""):gsub("[\r\n].*$", "")
    if content == "" then
      return
    end
    vim.schedule(function()
      -- Only apply if nothing has moved since this request was issued.
      if seq ~= llm_seq then
        return
      end
      local b, r, c, bf = cursor_prefix()
      if not bf or b ~= buf or r ~= row or c ~= col then
        return
      end
      local deduped = strip_overlap(bf, content)
      if deduped == "" then
        return
      end
      local text = (bf:match("%s$") and deduped or (" " .. deduped))
      current = { buf = b, row = r, col = c, text = text }
      render()
    end)
  end)
end

-- Recompute the suggestion now: instant n-gram tier, then the async LLM tier.
function M.trigger()
  ngram_suggest()
  if cfg.llm then
    llm_request()
  end
end

-- Debounced entry point: hide any stale ghost while the user is typing, then fire the
-- suggestion once typing pauses for `debounce` ms (0 = trigger immediately).
local function schedule_trigger()
  clear() -- also stops any pending timer; don't show an out-of-date ghost mid-type
  if (cfg.debounce or 0) <= 0 then
    M.trigger()
    return
  end
  trigger_timer = uv.new_timer()
  trigger_timer:start(cfg.debounce, 0, function()
    trigger_timer:stop()
    trigger_timer:close()
    trigger_timer = nil
    dbg("debounce fired after " .. cfg.debounce .. "ms idle -> triggering")
    vim.schedule(M.trigger)
  end)
end

-- ── acceptance ───────────────────────────────────────────────────────────────

function M.is_visible()
  return current ~= nil and current.text ~= ""
end

-- Accept the next word (leading spaces + one word) of the ghost.
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
    clear()
    return false
  end

  local buf, row, col = current.buf, current.row, current.col
  -- The insert + cursor move below fire TextChangedI/CursorMovedI; squelch the resulting
  -- recompute for this tick so the un-accepted words survive instead of being cleared.
  squelch = true
  api.nvim_buf_set_text(buf, row, col, row, col, { chunk })
  local newcol = col + #chunk
  api.nvim_win_set_cursor(0, { row + 1, newcol })

  local remaining = current.text:sub(#chunk + 1)
  if remaining == "" then
    clear()
    M.trigger() -- phrase exhausted: fetch a fresh continuation
  else
    current = { buf = buf, row = row, col = newcol, text = remaining }
    render()
  end
  vim.schedule(function()
    squelch = false
  end)
  return true
end

function M.accept_all()
  if not M.is_visible() then
    return false
  end
  local buf, row, col, chunk = current.buf, current.row, current.col, current.text
  api.nvim_buf_set_text(buf, row, col, row, col, { chunk })
  api.nvim_win_set_cursor(0, { row + 1, col + #chunk })
  clear()
  return true
end

function M.dismiss()
  clear()
end

-- ── learning + persistence ───────────────────────────────────────────────────

local function data_path()
  return cfg.data_file or (vim.fn.stdpath("data") .. "/cotyper/model.json")
end

local function harvest(buf)
  if not eligible(buf) then
    return
  end
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, line in ipairs(lines) do
    learn(words_of(line))
  end
end

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

local function save()
  if not dirty then
    return
  end
  prune()
  local path = data_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, encoded = pcall(vim.json.encode, model)
  if not ok then
    return
  end
  local fd = io.open(path, "w")
  if fd then
    fd:write(encoded)
    fd:close()
    dirty = false
  end
end
M.save = save

local function load()
  local fd = io.open(data_path(), "r")
  if not fd then
    return
  end
  local content = fd:read("*a")
  fd:close()
  if not content or content == "" then
    return
  end
  local ok, parsed = pcall(vim.json.decode, content)
  if ok and type(parsed) == "table" then
    model.uni = parsed.uni or {}
    model.bi = parsed.bi or {}
    model.tri = parsed.tri or {}
  end
end
M.load = load

-- Exposed for testing the instant tier headlessly.
function M._learn_text(str)
  learn(words_of(str))
end
function M._predict(before)
  if before:match("[%w']$") then
    local partial = before:match("[%w']+$")
    local word = complete_prefix(partial)
    return word and word:sub(#partial + 1) or nil
  end
  return next_word(words_of(before))
end
function M._suggest_text(before)
  return build_text(before)
end

-- ── setup ────────────────────────────────────────────────────────────────────

function M.setup(opts)
  cfg = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  ftset = {}
  for _, ft in ipairs(cfg.filetypes or {}) do
    ftset[ft] = true
  end

  set_hl()
  load()

  local grp = api.nvim_create_augroup("cotyper", { clear = true })

  api.nvim_create_autocmd("ColorScheme", { group = grp, callback = set_hl })

  api.nvim_create_autocmd({ "TextChangedI", "CursorMovedI" }, {
    group = grp,
    callback = function()
      if squelch then
        return -- an accept just happened; keep the remaining ghost intact
      end
      schedule_trigger()
    end,
  })

  api.nvim_create_autocmd("InsertLeave", {
    group = grp,
    callback = function(ev)
      clear()
      harvest(ev.buf)
    end,
  })

  api.nvim_create_autocmd("BufWritePost", {
    group = grp,
    callback = function(ev)
      harvest(ev.buf)
    end,
  })

  api.nvim_create_autocmd("VimLeavePre", { group = grp, callback = save })

  -- Periodic background save.
  save_timer = uv.new_timer()
  save_timer:start(cfg.save_interval * 1000, cfg.save_interval * 1000, function()
    vim.schedule(save)
  end)

  api.nvim_create_user_command("CotyperToggle", function()
    enabled = not enabled
    if not enabled then
      clear()
    end
    vim.notify("cotyper " .. (enabled and "enabled" or "disabled"))
  end, {})
  api.nvim_create_user_command("CotyperDismiss", function()
    clear()
  end, {})
  api.nvim_create_user_command("CotyperDebug", function()
    cfg.debug = not cfg.debug
    vim.notify("cotyper debug " .. (cfg.debug and "on" or "off"))
  end, { desc = "Toggle cotyper debug notifications" })
end

return M
