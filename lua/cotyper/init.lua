-- cotyper.nvim — always-on inline autocomplete inspired by the Cotypist macOS app.
-- Two tiers:
--   1. instant: a local n-gram model that learns from your typing and persists to disk.
--   2. smart:   a debounced async call to a local LLM (gemma via Ollama) that supersedes
--               the n-gram guess with a richer continuation when it arrives.
-- Tab (wired in your keymap) accepts the ghost one word at a time; keep typing to reject.
--
-- Layout:
--   config    defaults + the shared, live settings table
--   util      word splitting, overlap trimming, file IO, debug notifications
--   ngram     the instant tier: learn, predict, persist
--   ghost     eligibility, cursor context, extmark rendering, acceptance
--   ollama    HTTP wrapper over Ollama's /api/chat
--   llm       the smart tier: prompt assembly and completion requests
--   style     learned, versioned, per-tag style guides
--   commands  the :Cotyper* user commands

local api = vim.api
local uv = vim.uv or vim.loop

local commands = require("cotyper.commands")
local config = require("cotyper.config")
local ghost = require("cotyper.ghost")
local llm = require("cotyper.llm")
local ngram = require("cotyper.ngram")
local style = require("cotyper.style")
local util = require("cotyper.util")

local M = {}

local cfg = config.values
local save_timer = nil

--- Recompute the suggestion now: instant n-gram tier, then the async LLM tier.
function M.trigger()
  local buf, row, col, before = ghost.cursor_prefix()
  if not before then
    ghost.clear()
  else
    local text = ngram.build_text(before)
    if text == "" then
      ghost.clear()
    else
      ghost.show(buf, row, col, text)
    end
  end
  if cfg.llm then
    llm.request()
  end
end

-- ── public API ───────────────────────────────────────────────────────────────

M.is_visible = ghost.is_visible
M.accept_word = ghost.accept_word
M.accept_all = ghost.accept_all
M.save = ngram.save
M.load = ngram.load
M.assess_style = style.assess

function M.dismiss()
  ghost.clear()
end

-- ── learning ─────────────────────────────────────────────────────────────────

local function harvest(buf)
  if not ghost.eligible(buf) then
    return
  end
  for _, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    ngram.learn(util.words_of(line))
  end
end

-- ── test hooks ───────────────────────────────────────────────────────────────
-- Exposed for driving the tiers headlessly; not part of the public API.

function M._learn_text(str)
  ngram.learn(util.words_of(str))
end

function M._predict(before)
  if before:match("[%w']$") then
    local partial = before:match("[%w']+$")
    local word = ngram.complete_prefix(partial)
    return word and word:sub(#partial + 1) or nil
  end
  return ngram.next_word(util.words_of(before))
end

function M._suggest_text(before)
  return ngram.build_text(before)
end

function M._save_style(tag, text)
  return style.save(style.sanitize_tag(tag), text)
end

function M._versions(tag)
  return style.versions(style.sanitize_tag(tag))
end

function M._buf_tag(buf, opts)
  return style.buf_tag(buf, opts)
end

function M._current_style()
  return style.current()
end

-- ── keymaps ──────────────────────────────────────────────────────────────────

local actions = {
  accept_word = ghost.accept_word,
  accept_all = ghost.accept_all,
  dismiss = function()
    if not ghost.is_visible() then
      return false
    end
    ghost.clear()
    return true
  end,
}

--- Map each configured key in insert mode. With no ghost showing, the key does
--- whatever it did unmapped, so a binding costs nothing when there's no suggestion.
local function map_keys()
  for name, lhs in pairs(cfg.keymaps or {}) do
    local act = actions[name]
    if act and lhs then
      vim.keymap.set("i", lhs, function()
        if not act() then
          api.nvim_feedkeys(vim.keycode(lhs), "n", false)
        end
      end, { desc = "cotyper: " .. name:gsub("_", " ") })
    end
  end
end

-- ── setup ────────────────────────────────────────────────────────────────────

function M.setup(opts)
  config.merge(opts)
  ghost.refresh_filetypes()
  ghost.set_hl()

  ngram.load()
  style.migrate_legacy()
  style.load_tag(cfg.default_tag) -- pre-warm the default guide

  local grp = api.nvim_create_augroup("cotyper", { clear = true })

  api.nvim_create_autocmd("ColorScheme", { group = grp, callback = ghost.set_hl })

  api.nvim_create_autocmd({ "TextChangedI", "CursorMovedI" }, {
    group = grp,
    callback = function()
      if ghost.squelch then
        return -- an accept just happened; keep the remaining ghost intact
      end
      ghost.schedule_trigger()
    end,
  })

  api.nvim_create_autocmd("InsertLeave", {
    group = grp,
    callback = function(ev)
      ghost.clear()
      harvest(ev.buf)
    end,
  })

  api.nvim_create_autocmd("BufWritePost", {
    group = grp,
    callback = function(ev)
      harvest(ev.buf)
    end,
  })

  api.nvim_create_autocmd("VimLeavePre", { group = grp, callback = ngram.save })

  -- Periodic background save.
  if save_timer then
    save_timer:stop()
    save_timer:close()
  end
  save_timer = uv.new_timer()
  save_timer:start(cfg.save_interval * 1000, cfg.save_interval * 1000, function()
    vim.schedule(ngram.save)
  end)

  commands.setup()
  map_keys()
end

return M
