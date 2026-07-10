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
  model = "gemma4:e2b-mlx",
  endpoint = "http://localhost:11434/v1/chat/completions",
  api_key_env = "TERM", -- Ollama ignores the key; mirrors the OpenAI-compatible setup.
  filetypes = { "markdown" },
  debounce = 150, -- ms before the LLM tier fires
  order = 3, -- n-gram order (uni/bi/tri)
  min_count = 2, -- prune threshold when the model grows past `prune_cap`
  prune_cap = 15000, -- unique unigrams before pruning kicks in
  save_interval = 60, -- seconds between periodic model saves
  context_lines = 20, -- lines of buffer context sent to the LLM
  max_tokens = 48,
  llm = true, -- set false to run on the n-gram tier alone
  highlight = { fg = "#808080", italic = true },
  system_prompt = "You are a writing assistant completing prose in the author's voice. "
    .. "Continue the given text naturally with a short single-line continuation. "
    .. "Avoid hedging, filler and lists. Do not repeat the text given. "
    .. "Reply with only the continuation, no quotes or commentary.",
  data_file = nil, -- default: stdpath('data')/cotyper/model.json
}

local cfg = vim.deepcopy(defaults)
local ns = api.nvim_create_namespace("cotyper")
local ftset = {} -- eligible filetypes as a set

-- ── n-gram model ─────────────────────────────────────────────────────────────
-- uni[w] = count ; bi[w1][w2] = count ; tri["w1 w2"][w3] = count
local model = { uni = {}, bi = {}, tri = {} }
local dirty = false

-- pending ghost: { buf, row, col, text } — text is the un-accepted remainder.
local current = nil
local debounce_timer = nil
local save_timer = nil
local enabled = true
local llm_seq = 0 -- request generation, to drop stale LLM responses

-- ── helpers ──────────────────────────────────────────────────────────────────

local function words_of(str)
  local out = {}
  for w in str:gmatch("[%w']+") do
    out[#out + 1] = w:lower()
  end
  return out
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

-- Instant n-gram suggestion for the current cursor position.
local function ngram_suggest()
  local buf, row, col, before = cursor_prefix()
  if not before then
    clear()
    return false
  end

  local text
  local mid_word = before:match("[%w']$") ~= nil
  if mid_word then
    local partial = before:match("[%w']+$")
    local word = complete_prefix(partial)
    if word then
      text = word:sub(#partial + 1)
    end
  else
    local nw = next_word(words_of(before))
    if nw then
      text = (before:match("%s$") and "" or " ") .. nw
    end
  end

  if not text or text == "" then
    clear()
    return false
  end
  current = { buf = buf, row = row, col = col, text = text }
  render()
  return true
end

-- ── LLM tier ─────────────────────────────────────────────────────────────────

local function llm_request()
  if not cfg.llm then
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
  local body = vim.json.encode({
    model = cfg.model,
    stream = false,
    max_tokens = cfg.max_tokens,
    messages = {
      { role = "system", content = cfg.system_prompt },
      { role = "user", content = ctx },
    },
  })

  llm_seq = llm_seq + 1
  local seq = llm_seq
  local key = vim.env[cfg.api_key_env] or "cotyper"

  vim.system({
    "curl", "-s", "-m", "30", cfg.endpoint,
    "-H", "Content-Type: application/json",
    "-H", "Authorization: Bearer " .. key,
    "-d", body,
  }, { text = true }, function(res)
    if res.code ~= 0 or not res.stdout or res.stdout == "" then
      return
    end
    local ok, parsed = pcall(vim.json.decode, res.stdout)
    if not ok or type(parsed) ~= "table" then
      return
    end
    local choice = parsed.choices and parsed.choices[1]
    local content = choice and choice.message and choice.message.content
    if type(content) ~= "string" then
      return
    end
    content = content:gsub("^%s+", ""):gsub("[\r\n].*$", "")
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
      local text = (bf:match("%s$") and content or (" " .. content))
      current = { buf = b, row = r, col = c, text = text }
      render()
    end)
  end)
end

local function schedule_llm()
  if not cfg.llm then
    return
  end
  if debounce_timer then
    debounce_timer:stop()
    debounce_timer:close()
    debounce_timer = nil
  end
  debounce_timer = uv.new_timer()
  debounce_timer:start(cfg.debounce, 0, function()
    debounce_timer:stop()
    debounce_timer:close()
    debounce_timer = nil
    vim.schedule(llm_request)
  end)
end

-- Public: recompute the whole suggestion (instant tier now, LLM tier soon).
function M.trigger()
  if ngram_suggest() then
    schedule_llm()
  else
    schedule_llm() -- LLM may still have something at a boundary the n-gram missed
  end
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
  api.nvim_buf_set_text(buf, row, col, row, col, { chunk })
  local newcol = col + #chunk
  api.nvim_win_set_cursor(0, { row + 1, newcol })

  local remaining = current.text:sub(#chunk + 1)
  if remaining == "" then
    clear()
    M.trigger() -- keep the flow going
  else
    current = { buf = buf, row = row, col = newcol, text = remaining }
    render()
  end
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
      M.trigger()
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
end

return M
