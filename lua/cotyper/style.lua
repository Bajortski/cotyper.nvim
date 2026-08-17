-- Learned style guides.
--
-- Guides live under style_dir()/<tag>/<epoch>.md. The newest file in a tag dir is
-- that tag's active guide; :CotyperAssessStyle writes a fresh timestamped file
-- each time, so older versions are kept forever. The tag is `default` unless
-- `style_by_tag` is on, in which case it comes from the current note's
-- frontmatter.
--
-- A note with several tags is filed under whichever of them the most notes in
-- the vault carry, so a guide accumulates against the largest body of writing
-- rather than under whatever happened to be typed first. That needs a count of
-- tags across the vault; see the index section below for how it's kept cheap.

local api = vim.api
local uv = vim.uv or vim.loop

local config = require("cotyper.config")
local ollama = require("cotyper.ollama")
local util = require("cotyper.util")

local M = {}

local cfg = config.values
local cache = {} -- tag -> guide text, or false when the tag has none
local assessing = false -- guard against concurrent :CotyperAssessStyle runs

--- Slugify a tag into something usable as a directory name. Returns "" when
--- nothing survives, so callers can tell a blank tag from a real one.
---@param s string|nil
---@return string
local function normalize(s)
  s = (s or ""):lower():gsub("[%s/]+", "-"):gsub("[^%w%._-]", "")
  return (s:gsub("^-+", ""):gsub("-+$", ""))
end

--- Make a tag safe as a directory name; empty/blank falls back to the default tag.
---@param s string|nil
---@return string
function M.sanitize_tag(s)
  local t = normalize(s)
  if t == "" then
    return cfg.default_tag
  end
  return t
end

--- Every tag in a leading YAML frontmatter block, in document order, deduped.
--- Supports `tags: [a, b]`, `tags: a, b` and block-list forms, for either
--- `tags:` or `tag:`. Shared by the buffer parse and the vault index so a note
--- is counted under exactly the tags it would be filed under.
---@param lines string[]
---@return string[]
function M.parse_tags(lines)
  if not lines[1] or lines[1] ~= "---" then
    return {}
  end
  local out, seen = {}, {}
  local function add(raw)
    raw = raw:gsub("^%s*(.-)%s*$", "%1"):gsub("^['\"]", ""):gsub("['\"]$", ""):gsub("^#", "")
    local t = normalize(raw)
    if t ~= "" and not seen[t] then
      seen[t] = true
      out[#out + 1] = t
    end
  end

  local in_tags = false
  for i = 2, #lines do
    local line = lines[i]
    if line == "---" or line == "..." then
      break
    end
    local inline = line:match("^%s*tags?%s*:%s*(.+)$")
    if inline and inline:match("%S") then
      in_tags = false
      inline = inline:gsub("^%[", ""):gsub("%]$", "")
      for item in inline:gmatch("[^,]+") do
        add(item)
      end
    elseif line:match("^%s*tags?%s*:%s*$") then
      in_tags = true -- block list follows
    elseif in_tags then
      local item = line:match("^%s*-%s*(.+)$")
      if item then
        add(item)
      elseif line:match("%S") then
        in_tags = false -- block list ended
      end
    end
  end
  return out
end

--- The frontmatter tags of a buffer, in document order.
---@param buf integer|nil
---@return string[]
function M.buf_tags(buf)
  buf = buf or api.nvim_get_current_buf()
  return M.parse_tags(api.nvim_buf_get_lines(buf, 0, 40, false))
end

-- ── vault tag index ──────────────────────────────────────────────────────────
-- "Most common" only means something measured against a body of notes, so this
-- counts how many notes carry each tag. That's a walk of the vault (~0.5s cold,
-- ~50ms warm on a few thousand notes), which is far too slow to sit in the
-- completion path, so it is:
--
--   * skipped entirely unless a note has more than one tag to choose between —
--     most notes have zero or one, and those need no counting;
--   * memoised for `tag_index_ttl` seconds;
--   * built synchronously only for :CotyperAssessStyle, a deliberate one-off.
--     Completions never block: they use the index if it happens to be warm,
--     otherwise they take the note's first tag and warm the index in the
--     background for next time.

local SKIP_DIRS = { [".obsidian"] = true, [".trash"] = true, [".git"] = true, ["node_modules"] = true }
local HEAD_BYTES = 2048 -- enough for any frontmatter block worth indexing
local CHUNK = 250 -- files per slice of a background build

local index = { counts = nil, built = 0, root = nil, building = false }

--- The note collection to count over: `tag_root` when set, else the nearest
--- ancestor of `path` holding a `.obsidian` directory. nil when neither applies
--- — with nothing to count, tag choice falls back to document order.
---@param path string|nil
---@return string|nil
function M.vault_root(path)
  if cfg.tag_root then
    return vim.fn.expand(cfg.tag_root)
  end
  path = path or api.nvim_buf_get_name(0)
  if path == "" then
    return nil
  end
  local marker = vim.fs.find(".obsidian", {
    path = vim.fs.dirname(path),
    upward = true,
    type = "directory",
  })[1]
  return marker and vim.fs.dirname(marker) or nil
end

--- Every markdown file under `root`, skipping dot- and vendor directories.
---@param root string
---@return string[]
local function md_files(root)
  local out, stack = {}, { root }
  while #stack > 0 do
    local dir = table.remove(stack)
    local it = vim.fs.dir(dir)
    if it then
      for name, typ in it do
        if typ == "directory" then
          if name:sub(1, 1) ~= "." and not SKIP_DIRS[name] then
            stack[#stack + 1] = dir .. "/" .. name
          end
        elseif typ == "file" and name:sub(-3) == ".md" then
          out[#out + 1] = dir .. "/" .. name
        end
      end
    end
  end
  return out
end

--- Count one file's tags into `counts`. Reads only the head of the file, since
--- frontmatter is by definition at the top.
---@param counts table<string, integer>
---@param path string
local function count_file(counts, path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return
  end
  local head = uv.fs_read(fd, HEAD_BYTES, 0)
  uv.fs_close(fd)
  if not head or head:sub(1, 3) ~= "---" then
    return
  end
  for _, tag in ipairs(M.parse_tags(vim.split(head, "\n", { plain = true }))) do
    counts[tag] = (counts[tag] or 0) + 1
  end
end

local function index_fresh(root)
  return index.counts ~= nil
    and index.root == root
    and (os.time() - index.built) < cfg.tag_index_ttl
end

--- Count every note under `root`, blocking until done.
---@param root string
---@return table<string, integer>
local function build_now(root)
  local counts = {}
  for _, path in ipairs(md_files(root)) do
    count_file(counts, path)
  end
  index.counts, index.built, index.root = counts, os.time(), root
  return counts
end

--- Same, in slices, so a cold index never stalls typing.
---@param root string
local function build_soon(root)
  if index.building then
    return
  end
  index.building = true
  local files = md_files(root)
  local counts, i = {}, 1
  local function slice()
    local stop = math.min(i + CHUNK - 1, #files)
    for k = i, stop do
      count_file(counts, files[k])
    end
    i = stop + 1
    if i > #files then
      index.counts, index.built, index.root, index.building = counts, os.time(), root, false
    else
      vim.schedule(slice)
    end
  end
  vim.schedule(slice)
end

--- Notes per tag under `root`. Returns nil when there is nothing to count, or
--- when the index is cold and `opts.build` wasn't asked for.
---@param root string|nil
---@param opts? { build?: boolean }
---@return table<string, integer>|nil
function M.tag_counts(root, opts)
  if not root then
    return nil
  end
  if index_fresh(root) then
    return index.counts
  end
  if opts and opts.build then
    vim.notify("cotyper: counting vault tags…")
    return build_now(root)
  end
  build_soon(root)
  return nil
end

-- ── tag resolution ───────────────────────────────────────────────────────────

--- Resolve the active tag for a buffer. With style_by_tag off, always the
--- default tag. Otherwise the note's frontmatter tags, narrowed to whichever is
--- carried by the most notes in the vault; ties keep the earlier tag, and an
--- unavailable index means document order.
---@param buf integer|nil
---@param opts? { build?: boolean } build the vault index synchronously if stale
---@return string
function M.buf_tag(buf, opts)
  if not cfg.style_by_tag then
    return cfg.default_tag
  end
  buf = buf or api.nvim_get_current_buf()
  local tags = M.buf_tags(buf)
  if #tags == 0 then
    return cfg.default_tag
  end
  if #tags == 1 then
    return tags[1] -- nothing to choose between; never touch the index
  end

  local counts = M.tag_counts(M.vault_root(api.nvim_buf_get_name(buf)), opts)
  if not counts then
    return tags[1]
  end

  local best, best_n = tags[1], counts[tags[1]] or 0
  for i = 2, #tags do
    local n = counts[tags[i]] or 0
    if n > best_n then -- strict, so a tie leaves the earlier tag in place
      best, best_n = tags[i], n
    end
  end
  return best
end

--- The candidate tags for a buffer paired with their vault counts, ordered as
--- they appear in the note. For :CotyperTag, so the choice can be checked.
---@param buf integer|nil
---@return { tag: string, count: integer|nil }[], boolean indexed
function M.tag_candidates(buf)
  buf = buf or api.nvim_get_current_buf()
  local tags = M.buf_tags(buf)
  local counts = #tags > 1 and M.tag_counts(M.vault_root(api.nvim_buf_get_name(buf))) or nil
  local out = {}
  for i, tag in ipairs(tags) do
    out[i] = { tag = tag, count = counts and (counts[tag] or 0) or nil }
  end
  return out, counts ~= nil
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
  -- Worth blocking on a cold vault index here: this is an explicit, one-off
  -- command, and filing the assessment under the wrong tag is worse than a
  -- pause. Completions never take this path.
  local tag = M.buf_tag(buf, { build = true })
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
