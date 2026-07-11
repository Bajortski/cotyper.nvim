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
    .. "already written; begin with the next new word, not a word already on the page.",
  -- Personal style/voice preferences, appended after `system_prompt`. Keep this for the
  -- author's own settings (name, dialect, tone) so it stays separate from the general
  -- instruction above. nil/empty = none.
  style = nil,
  data_file = nil, -- default: stdpath('data')/cotyper/model.json
  debug = false, -- notify on debounce fire, query start, and query completion
  -- :CotyperAssessStyle asks the model to write a style guide from your writing and folds
  -- it into every completion prompt so output tracks your voice over time. Every assessment
  -- is kept as a timestamped version under style_dir/<tag>/; nothing is overwritten.
  style_dir = nil, -- default: stdpath('data')/cotyper/styles
  style_by_tag = false, -- true = pick the guide from the note's frontmatter first tag
  default_tag = "default", -- guide used when style_by_tag=false, or a note has no tags
  assess_sample_lines = 400, -- lines of the current buffer sampled when assessing
  assess_max_tokens = 512, -- num_predict for the assessment (a longer, one-off generation)
  assess_num_ctx = 8192, -- context window for the assessment (must fit the writing sample)
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
local styles_cache = {} -- tag -> current (newest) style guide text, loaded from disk lazily
local assessing = false -- guard against concurrent :CotyperAssessStyle runs
local current_style -- fwd decl: resolves the active tag's guide (defined in the style block)

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
    -- "replace" so the ghost renders purely as CotyperGhost; "combine" lets a background
    -- highlight under the cursor (matchparen, autopairs) bleed into the ghost text.
    hl_mode = "replace",
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

-- General instruction, then the author's own style block, then the model's learned style
-- assessment (from :CotyperAssessStyle) — each kept as a separate section.
local function system_content()
  local parts = { cfg.system_prompt }
  if cfg.style and cfg.style ~= "" then
    parts[#parts + 1] = cfg.style
  end
  local learned = current_style()
  if learned and learned ~= "" then
    parts[#parts + 1] = "Observed style of this author — match it for voice, rhythm and "
      .. "diction, but where it conflicts with the author's stated preferences above, the "
      .. "stated preferences win:\n" .. learned
  end
  return table.concat(parts, "\n\n")
end

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
      { role = "system", content = system_content() },
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

-- ── style assessment ─────────────────────────────────────────────────────────
--
-- Guides live under style_dir()/<tag>/<epoch>.md. The newest file in a tag dir is that
-- tag's active guide; :CotyperAssessStyle writes a fresh timestamped file each time, so
-- older versions are kept forever. The tag is `default` unless `style_by_tag` is on, in
-- which case it comes from the current note's frontmatter (first `tags:` entry).

local function style_dir()
  return cfg.style_dir or (vim.fn.stdpath("data") .. "/cotyper/styles")
end

-- Make a tag safe to use as a directory name; empty/blank falls back to the default tag.
local function sanitize_tag(s)
  s = (s or ""):lower():gsub("[%s/]+", "-"):gsub("[^%w%._-]", "")
  s = s:gsub("^-+", ""):gsub("-+$", "")
  if s == "" then
    return cfg.default_tag
  end
  return s
end

-- Resolve the active tag for a buffer. With style_by_tag off, always the default tag.
-- Otherwise read the leading YAML frontmatter and return the first `tags:`/`tag:` value.
local function buf_tag(buf)
  if not cfg.style_by_tag then
    return cfg.default_tag
  end
  buf = buf or api.nvim_get_current_buf()
  local lines = api.nvim_buf_get_lines(buf, 0, 40, false)
  if not lines[1] or lines[1] ~= "---" then
    return cfg.default_tag
  end
  local in_tags = false
  for i = 2, #lines do
    local line = lines[i]
    if line == "---" or line == "..." then
      break
    end
    -- inline forms: `tags: [a, b]`, `tags: a, b`, `tags: a`
    local inline = line:match("^%s*tags?%s*:%s*(.+)$")
    if inline and inline:match("%S") then
      inline = inline:gsub("^%[", ""):gsub("%]$", "")
      local first = inline:match("[^,%s][^,]*")
      if first then
        return sanitize_tag((first:gsub("^['\"]", ""):gsub("['\"]$", "")))
      end
    elseif line:match("^%s*tags?%s*:%s*$") then
      in_tags = true -- block list follows
    elseif in_tags then
      local item = line:match("^%s*-%s*(.+)$")
      if item then
        return sanitize_tag((item:gsub("^['\"]", ""):gsub("['\"]$", "")))
      elseif line:match("%S") then
        break -- block list ended without an item
      end
    end
  end
  return cfg.default_tag
end

-- All saved versions for a tag, newest-first, as { path = ..., time = <epoch> }.
local function versions(tag)
  local dir = style_dir() .. "/" .. tag
  local out = {}
  local it = vim.fs.dir(dir)
  if it then
    for name, typ in it do
      if typ == "file" then
        local epoch, suffix = name:match("^(%d+)%-?(%d*)%.md$")
        if epoch then
          out[#out + 1] = {
            path = dir .. "/" .. name,
            time = tonumber(epoch),
            seq = tonumber(suffix) or 1, -- collision suffix; bare file = 1, -2 = 2, …
          }
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.time ~= b.time then
      return a.time > b.time
    end
    return a.seq > b.seq -- newer collisions (higher suffix) rank first
  end)
  return out
end

local function read_file(path)
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

local function newest(tag)
  local v = versions(tag)
  return v[1]
end

-- Load (and memoise) the newest guide for a tag into styles_cache. Returns the text or nil.
local function load_tag(tag)
  if styles_cache[tag] == nil then
    local v = newest(tag)
    styles_cache[tag] = (v and read_file(v.path)) or false
  end
  return styles_cache[tag] or nil
end

-- The active guide for the current buffer (resolves tag, loads lazily). Assigned to the
-- forward-declared local so system_content() can call it.
function current_style()
  return load_tag(buf_tag(api.nvim_get_current_buf()))
end

-- Write a new timestamped version for `tag`; never overwrites an existing file.
local function save_style(tag, text)
  local dir = style_dir() .. "/" .. tag
  vim.fn.mkdir(dir, "p")
  local base = os.time()
  local path = dir .. "/" .. base .. ".md"
  local n = 2
  while uv.fs_stat(path) do
    path = dir .. "/" .. base .. "-" .. n .. ".md"
    n = n + 1
  end
  local fd = io.open(path, "w")
  if fd then
    fd:write(text)
    fd:close()
  end
  styles_cache[tag] = text
  return path
end

-- One-time migration: fold a pre-versioning style.md into the default tag's history.
local function migrate_legacy_style()
  local legacy = vim.fn.stdpath("data") .. "/cotyper/style.md"
  if not uv.fs_stat(legacy) then
    return
  end
  if #versions(cfg.default_tag) > 0 then
    return -- already have versioned guides; leave the legacy file alone
  end
  local content = read_file(legacy)
  if content then
    save_style(cfg.default_tag, content)
    styles_cache[cfg.default_tag] = nil -- re-read from the new versioned file on demand
  end
end

-- Ask the model to write (or refine) a style guide from the current buffer's writing, then
-- persist it and fold it into future completion prompts.
local function assess_style()
  if not cfg.model or cfg.model == "" then
    vim.notify("cotyper: set `model` before assessing style.", vim.log.levels.WARN)
    return
  end
  if assessing then
    vim.notify("cotyper: a style assessment is already running.")
    return
  end

  local buf = api.nvim_get_current_buf()
  local tag = buf_tag(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, cfg.assess_sample_lines, false)
  local sample = table.concat(lines, "\n")
  if not sample:match("%S") then
    vim.notify("cotyper: buffer is empty — nothing to assess.", vim.log.levels.WARN)
    return
  end

  local instruction = "You are a writing coach building a concise style guide so another "
    .. "model can imitate this author. Read the writing sample and produce a short, "
    .. "prescriptive style guide (6-10 bullet points) covering: voice and tone; typical "
    .. "sentence length and rhythm; vocabulary and diction; punctuation habits; "
    .. "dialect/spelling; and any recurring quirks. Be specific and actionable. If a "
    .. "PREVIOUS STYLE GUIDE is given, revise and sharpen it using the new sample rather "
    .. "than starting over. Output only the style guide, no preamble."
  local prev = load_tag(tag)
  local user = sample
  if prev and prev ~= "" then
    user = "PREVIOUS STYLE GUIDE:\n" .. prev .. "\n\nWRITING SAMPLE:\n" .. sample
  end

  local body = vim.json.encode({
    model = cfg.model,
    stream = false,
    think = cfg.think,
    messages = {
      { role = "system", content = instruction },
      { role = "user", content = user },
    },
    keep_alive = cfg.keep_alive,
    options = { num_predict = cfg.assess_max_tokens, num_ctx = cfg.assess_num_ctx },
  })

  assessing = true
  vim.notify("cotyper: assessing writing style…")
  local t0 = uv.hrtime()

  vim.system({
    "curl", "-s", "-m", "120", cfg.endpoint,
    "-H", "Content-Type: application/json",
    "-d", body,
  }, { text = true }, function(res)
    local ms = math.floor((uv.hrtime() - t0) / 1e6)
    vim.schedule(function()
      assessing = false
      if res.code ~= 0 or not res.stdout or res.stdout == "" then
        vim.notify("cotyper: style assessment failed (curl " .. res.code .. ").", vim.log.levels.ERROR)
        return
      end
      local ok, parsed = pcall(vim.json.decode, res.stdout)
      local content = ok and parsed and parsed.message and parsed.message.content
      if type(content) ~= "string" or not content:match("%S") then
        vim.notify("cotyper: style assessment returned nothing.", vim.log.levels.WARN)
        return
      end
      content = content:gsub("<think>.-</think>", ""):gsub("^%s+", ""):gsub("%s+$", "")
      local path = save_style(tag, content)
      vim.notify("cotyper: [" .. tag .. "] style guide updated in " .. ms .. "ms (" .. path .. ").")
    end)
  end)
end
M.assess_style = assess_style

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
-- Exposed for testing the style tier headlessly.
function M._save_style(tag, text)
  return save_style(sanitize_tag(tag), text)
end
function M._versions(tag)
  return versions(sanitize_tag(tag))
end
function M._buf_tag(buf)
  return buf_tag(buf)
end
function M._current_style()
  return current_style()
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
  migrate_legacy_style()
  load_tag(cfg.default_tag) -- pre-warm the default guide

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
  api.nvim_create_user_command("CotyperAssessStyle", assess_style, {
    desc = "Have the model assess this buffer's writing style and use it in completions",
  })
  api.nvim_create_user_command("CotyperStyle", function(a)
    local tag = buf_tag(api.nvim_get_current_buf())
    local v = versions(tag)
    if #v == 0 then
      vim.notify("cotyper: [" .. tag .. "] no style guide yet — run :CotyperAssessStyle.")
      return
    end
    local n = tonumber(a.args) or 1
    local entry = v[n]
    if not entry then
      vim.notify("cotyper: [" .. tag .. "] version " .. n .. " does not exist (1.." .. #v .. ").", vim.log.levels.WARN)
      return
    end
    local text = read_file(entry.path) or "(empty)"
    vim.notify("── [" .. tag .. "] style guide " .. n .. "/" .. #v .. " ──\n" .. text)
  end, { nargs = "?", desc = "Show the active tag's style guide (optional version number, 1=newest)" })
  api.nvim_create_user_command("CotyperStyleHistory", function()
    local tag = buf_tag(api.nvim_get_current_buf())
    local v = versions(tag)
    if #v == 0 then
      vim.notify("cotyper: [" .. tag .. "] no style guide yet — run :CotyperAssessStyle.")
      return
    end
    local lines = { "── [" .. tag .. "] style history (" .. #v .. ") ──" }
    for i, entry in ipairs(v) do
      lines[#lines + 1] = string.format(
        "%d  %s%s",
        i,
        os.date("%Y-%m-%d %H:%M", entry.time),
        i == 1 and "  (current)" or ""
      )
    end
    vim.notify(table.concat(lines, "\n"))
  end, { desc = "List saved style-guide versions for the active tag (newest first)" })
  api.nvim_create_user_command("CotyperTag", function()
    local tag = buf_tag(api.nvim_get_current_buf())
    local mode = cfg.style_by_tag and "from frontmatter" or "style_by_tag off"
    vim.notify("cotyper: active style tag = [" .. tag .. "] (" .. mode .. ")")
  end, { desc = "Show which style tag the current buffer resolves to" })
end

return M
