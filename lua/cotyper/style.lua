-- Learned style guides.
--
-- Guides live under style_dir()/<tag>/<epoch>.md. The newest file in a tag dir is
-- that tag's active guide; :CotyperAssessStyle writes a fresh timestamped file
-- each time, so older versions are kept forever. The tag is `default` unless
-- `style_by_tag` is on, in which case it comes from the current note's
-- frontmatter (first `tags:` entry).

local api = vim.api
local uv = vim.uv or vim.loop

local config = require("cotyper.config")
local ollama = require("cotyper.ollama")
local util = require("cotyper.util")

local M = {}

local cfg = config.values
local cache = {} -- tag -> guide text, or false when the tag has none
local assessing = false -- guard against concurrent :CotyperAssessStyle runs

--- Make a tag safe as a directory name; empty/blank falls back to the default tag.
---@param s string|nil
---@return string
function M.sanitize_tag(s)
  s = (s or ""):lower():gsub("[%s/]+", "-"):gsub("[^%w%._-]", "")
  s = s:gsub("^-+", ""):gsub("-+$", "")
  if s == "" then
    return cfg.default_tag
  end
  return s
end

--- Resolve the active tag for a buffer. With style_by_tag off, always the default
--- tag. Otherwise read the leading YAML frontmatter and return the first
--- `tags:`/`tag:` value, supporting `[a, b]`, `a, b` and block-list forms.
---@param buf integer|nil
---@return string
function M.buf_tag(buf)
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
    local inline = line:match("^%s*tags?%s*:%s*(.+)$")
    if inline and inline:match("%S") then
      inline = inline:gsub("^%[", ""):gsub("%]$", "")
      local first = inline:match("[^,%s][^,]*")
      if first then
        return M.sanitize_tag((first:gsub("^['\"]", ""):gsub("['\"]$", "")))
      end
    elseif line:match("^%s*tags?%s*:%s*$") then
      in_tags = true -- block list follows
    elseif in_tags then
      local item = line:match("^%s*-%s*(.+)$")
      if item then
        return M.sanitize_tag((item:gsub("^['\"]", ""):gsub("['\"]$", "")))
      elseif line:match("%S") then
        break -- block list ended without an item
      end
    end
  end
  return cfg.default_tag
end

--- All saved versions for a tag, newest-first.
---@param tag string
---@return { path: string, time: integer, seq: integer }[]
function M.versions(tag)
  local dir = config.style_dir() .. "/" .. tag
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

--- Newest saved version for a tag, if any.
---@param tag string
function M.newest(tag)
  return M.versions(tag)[1]
end

--- Load (and memoise) the newest guide for a tag.
---@param tag string
---@return string|nil
function M.load_tag(tag)
  if cache[tag] == nil then
    local v = M.newest(tag)
    cache[tag] = (v and util.read_file(v.path)) or false
  end
  return cache[tag] or nil
end

--- The active guide for the current buffer (resolves tag, loads lazily).
---@return string|nil
function M.current()
  return M.load_tag(M.buf_tag(api.nvim_get_current_buf()))
end

--- Write a new timestamped version for `tag`; never overwrites an existing file.
---@param tag string
---@param text string
---@return string path
function M.save(tag, text)
  local dir = config.style_dir() .. "/" .. tag
  vim.fn.mkdir(dir, "p")
  local base = os.time()
  local path = dir .. "/" .. base .. ".md"
  local n = 2
  while uv.fs_stat(path) do
    path = dir .. "/" .. base .. "-" .. n .. ".md"
    n = n + 1
  end
  util.write_file(path, text)
  cache[tag] = text
  return path
end

--- One-time migration: fold a pre-versioning style.md into the default tag's history.
function M.migrate_legacy()
  local legacy = vim.fn.stdpath("data") .. "/cotyper/style.md"
  if not uv.fs_stat(legacy) then
    return
  end
  if #M.versions(cfg.default_tag) > 0 then
    return -- already have versioned guides; leave the legacy file alone
  end
  local content = util.read_file(legacy)
  if content then
    M.save(cfg.default_tag, content)
    cache[cfg.default_tag] = nil -- re-read from the new versioned file on demand
  end
end

local INSTRUCTION = "You are a writing coach building a concise style guide so another "
  .. "model can imitate this author. Read the writing sample and produce a short, "
  .. "prescriptive style guide (6-10 bullet points) covering: voice and tone; typical "
  .. "sentence length and rhythm; vocabulary and diction; punctuation habits; "
  .. "dialect/spelling; and any recurring quirks. Be specific and actionable. If a "
  .. "PREVIOUS STYLE GUIDE is given, revise and sharpen it using the new sample rather "
  .. "than starting over. Output only the style guide, no preamble."

--- Ask the model to write (or refine) a style guide from the current buffer's
--- writing, then persist it and fold it into future completion prompts.
function M.assess()
  if not ollama.has_model("assessment") then
    return
  end
  if assessing then
    vim.notify("cotyper: a style assessment is already running.")
    return
  end

  local buf = api.nvim_get_current_buf()
  local tag = M.buf_tag(buf)
  local sample = table.concat(api.nvim_buf_get_lines(buf, 0, cfg.assess_sample_lines, false), "\n")
  if not sample:match("%S") then
    vim.notify("cotyper: buffer is empty — nothing to assess.", vim.log.levels.WARN)
    return
  end

  local prev = M.load_tag(tag)
  local user = sample
  if prev and prev ~= "" then
    user = "PREVIOUS STYLE GUIDE:\n" .. prev .. "\n\nWRITING SAMPLE:\n" .. sample
  end

  assessing = true
  vim.notify("cotyper: assessing writing style…")

  ollama.chat({
    system = INSTRUCTION,
    user = user,
    max_tokens = cfg.assess_max_tokens,
    num_ctx = cfg.assess_num_ctx,
    timeout = 120,
  }, function(content, err, ms)
    vim.schedule(function()
      assessing = false
      if not content then
        -- A transport failure is an error; a model that simply said nothing is a warning.
        local transport = err:match("^curl") ~= nil
        vim.notify(
          "cotyper: style assessment " .. (transport and ("failed (" .. err .. ").") or "returned nothing."),
          transport and vim.log.levels.ERROR or vim.log.levels.WARN
        )
        return
      end
      local path = M.save(tag, content)
      vim.notify("cotyper: [" .. tag .. "] style guide updated in " .. ms .. "ms (" .. path .. ").")
    end)
  end)
end

return M
