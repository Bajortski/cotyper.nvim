-- The smart tier: a debounced async call to a local LLM that supersedes the
-- n-gram guess with a richer continuation when it arrives.

local api = vim.api

local config = require("cotyper.config")
local ghost = require("cotyper.ghost")
local ollama = require("cotyper.ollama")
local style = require("cotyper.style")
local util = require("cotyper.util")

local M = {}

local cfg = config.values
local seq = 0 -- request generation, to drop stale responses

--- General instruction, then the author's own style block, then the model's
--- learned style assessment — each kept as a separate section.
---@return string
function M.system_content()
  local parts = { cfg.system_prompt }
  if cfg.style and cfg.style ~= "" then
    parts[#parts + 1] = cfg.style
  end
  local learned = style.current()
  if learned and learned ~= "" then
    parts[#parts + 1] = "Observed style of this author — match it for voice, rhythm and "
      .. "diction, but where it conflicts with the author's stated preferences above, the "
      .. "stated preferences win:\n" .. learned
  end
  return table.concat(parts, "\n\n")
end

--- The full chat: system prompt, few-shot turns, then the document itself.
---@param ctx string
---@return table[]
function M.messages(ctx)
  local msgs = { { role = "system", content = M.system_content() } }
  for _, ex in ipairs(cfg.examples or config.default_examples) do
    msgs[#msgs + 1] = { role = "user", content = ex[1] }
    msgs[#msgs + 1] = { role = "assistant", content = ex[2] }
  end
  msgs[#msgs + 1] = { role = "user", content = ctx }
  return msgs
end

--- Turn raw model output into ghost text for `before`, or "" to show nothing.
---@param before string text left of the cursor
---@param ctx string document context the model was given
---@param content string
---@param truncated boolean|nil
---@return string
function M.finish(before, ctx, content, truncated)
  local text = util.clip_completion(content, truncated)
  text = util.strip_overlap(before, text)
  text = util.drop_double_determiner(before, text)
  if text == "" or util.echoes(ctx, text) then
    return ""
  end
  return before:match("%s$") and text or (" " .. text)
end

--- Fire a completion request for the current cursor position, if appropriate.
function M.request()
  if not cfg.llm then
    return
  end
  if not ollama.has_model("completion") then
    return
  end
  local buf, row, col, before = ghost.cursor_prefix()
  if not before then
    return
  end
  if before:match("[%w']$") then
    return -- don't ask the LLM to finish a half-typed word; that's the n-gram's job
  end

  local start = math.max(0, row - cfg.context_lines + 1)
  local ctx = table.concat(api.nvim_buf_get_lines(buf, start, row + 1, false), "\n")

  seq = seq + 1
  local mine = seq
  util.dbg("query start (" .. tostring(cfg.model) .. ")")

  ollama.chat({
    messages = M.messages(ctx),
    max_tokens = cfg.max_tokens,
    num_ctx = cfg.num_ctx,
    options = { temperature = cfg.temperature },
    timeout = 30,
  }, function(content, err, ms, truncated)
    if not content then
      util.dbg("query failed after " .. ms .. "ms (" .. err .. ")", vim.log.levels.WARN)
      return
    end
    util.dbg("query complete in " .. ms .. "ms: " .. content)
    vim.schedule(function()
      -- Only apply if nothing has moved since this request was issued.
      if mine ~= seq then
        return
      end
      local b, r, c, bf = ghost.cursor_prefix()
      if not bf or b ~= buf or r ~= row or c ~= col then
        return
      end
      local text = M.finish(bf, ctx, content, truncated)
      if text ~= "" then
        ghost.show(b, r, c, text)
      end
    end)
  end)
end

return M
