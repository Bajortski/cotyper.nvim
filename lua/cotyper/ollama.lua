-- Thin wrapper over Ollama's native /api/chat.
--
-- The native endpoint honours `think`; the OpenAI-compatible /v1 one does not,
-- so a thinking model would waste time reasoning before every completion.

local uv = vim.uv or vim.loop

local config = require("cotyper.config")
local util = require("cotyper.util")

local M = {}

local cfg = config.values

--- POST a two-message chat and hand the assistant's text back.
---
--- The callback runs on the libuv thread; schedule anything touching the editor.
---@param opts { system: string, user: string, max_tokens: integer, num_ctx: integer, timeout: integer }
---@param cb fun(content: string|nil, err: string|nil, ms: integer)
function M.chat(opts, cb)
  local body = vim.json.encode({
    model = cfg.model,
    stream = false,
    think = cfg.think, -- false = skip reasoning entirely (fast); reasoning models only
    messages = {
      { role = "system", content = opts.system },
      { role = "user", content = opts.user },
    },
    keep_alive = cfg.keep_alive,
    options = { num_predict = opts.max_tokens, num_ctx = opts.num_ctx },
  })

  local t0 = uv.hrtime()
  vim.system({
    "curl", "-s", "-m", tostring(opts.timeout), cfg.endpoint,
    "-H", "Content-Type: application/json",
    "-d", body,
  }, { text = true }, function(res)
    local ms = math.floor((uv.hrtime() - t0) / 1e6)
    if res.code ~= 0 or not res.stdout or res.stdout == "" then
      return cb(nil, "curl code " .. res.code, ms)
    end
    local ok, parsed = pcall(vim.json.decode, res.stdout)
    if not ok or type(parsed) ~= "table" then
      return cb(nil, "unparseable response", ms)
    end
    -- Native /api/chat returns { message = { content, thinking } }; reasoning is kept out
    -- of content. Strip any inline <think>…</think> too, in case a template emits it.
    local content = parsed.message and parsed.message.content
    if type(content) ~= "string" then
      return cb(nil, "no content", ms)
    end
    content = util.strip_thinking(content)
    if content == "" then
      return cb(nil, "empty content", ms)
    end
    cb(content, nil, ms)
  end)
end

--- True when a model is configured; warns once otherwise.
---@param context string
---@return boolean
local warned = false
function M.has_model(context)
  if cfg.model and cfg.model ~= "" then
    return true
  end
  if context == "completion" then
    if not warned then
      warned = true
      vim.schedule(function()
        vim.notify(
          "cotyper: set `model` (an Ollama model you've pulled, e.g. 'gemma4:e2b-mlx') "
            .. "to enable LLM completions, or set `llm = false` to silence this. "
            .. "The n-gram tier works regardless.",
          vim.log.levels.WARN
        )
      end)
    end
  else
    vim.notify("cotyper: set `model` before assessing style.", vim.log.levels.WARN)
  end
  return false
end

return M
