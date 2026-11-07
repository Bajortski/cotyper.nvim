-- Configuration defaults and the live, shared settings table.
--
-- Every module holds a reference to `M.values`, so `merge()` mutates that table
-- in place rather than replacing it — a re-`setup()` is then visible everywhere
-- without re-requiring anything.

local M = {}

M.defaults = {
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
  max_tokens = 16, -- num_predict: tokens the LLM generates per completion
  -- Sampling temperature. Model defaults (gemma: 1.0) make ghost text wander; low values
  -- keep it on the obvious continuation, which is what autocomplete should offer.
  temperature = 0.2,
  num_ctx = 1024, -- context window; cap it (gemma4 defaults to 128K, which is slow)
  keep_alive = "10m", -- keep the model resident so it doesn't cold-reload after a pause
  llm = true, -- set false to run on the n-gram tier alone
  highlight = { fg = "#808080", italic = true },
  system_prompt = "You are an inline autocomplete engine. Each user message is a document "
    .. "that stops at the author's cursor. Reply with only the next few words the author is "
    .. "most likely to type, continuing their sentence exactly where it stops. Stay literal "
    .. "and plain: prefer the obvious, specific continuation that follows from the text over "
    .. "anything clever or new. Never repeat text that is already written, never comment, "
    .. "never start a new line.",
  -- Worked examples sent as prior chat turns before the real document. Small models
  -- learn the task far better from these than from instructions: without them they
  -- tend to reply to the document, echo it, or ramble. Each is { document, completion };
  -- nil uses the built-in set below, {} sends none.
  examples = nil,
  -- Insert-mode keys the plugin maps itself. When no ghost is showing, the key falls
  -- through to whatever it did before. false/nil = don't map (wire it yourself).
  keymaps = {
    accept_word = "<C-l>",
    accept_all = false,
    dismiss = false,
  },
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
  style_by_tag = false, -- true = pick the guide from the note's frontmatter tags
  default_tag = "default", -- guide used when style_by_tag=false, or a note has no tags
  -- A note carrying several tags is filed under whichever of them the most notes
  -- use, so a guide builds up against the largest body of writing. Counting needs
  -- a note collection: `tag_root` names one, or nil walks up from the note looking
  -- for an Obsidian `.obsidian` directory. With no collection to count (or a
  -- tie) the note's first tag wins, which is the old behaviour.
  tag_root = nil,
  tag_index_ttl = 300, -- seconds a tag count is reused before being recounted
  assess_sample_lines = 400, -- lines of the current buffer sampled when assessing
  assess_max_tokens = 512, -- num_predict for the assessment (a longer, one-off generation)
  assess_num_ctx = 8192, -- context window for the assessment (must fit the writing sample)
}

--- Default few-shot turns. Deliberately plain and short: the model copies their
--- length and register as much as their content.
M.default_examples = {
  {
    "# Groceries\n\nWe ran out of milk on Tuesday, and because nobody wanted to walk to the "
      .. "shop in the rain, we",
    "drank our tea black for two days",
  },
  {
    "The meeting overran by forty minutes. By the time anyone got to the actual agenda, "
      .. "half the room had",
    "already left for lunch",
  },
  {
    "## Setup\n\nInstall the dependencies first, then run the migration script. If the "
      .. "script fails with a permissions error,",
    "check that the database user owns the schema",
  },
  {
    "I liked the first season a lot. The second one is",
    "weaker, but it still has its moments",
  },
}

--- Live settings. Import this table once; it is never replaced, only updated.
M.values = vim.deepcopy(M.defaults)

--- Fold user options over the defaults, in place.
---@param opts table|nil
---@return table values
function M.merge(opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  for k in pairs(M.values) do
    M.values[k] = nil
  end
  for k, v in pairs(merged) do
    M.values[k] = v
  end
  return M.values
end

--- Where the n-gram model is persisted.
function M.data_path()
  return M.values.data_file or (vim.fn.stdpath("data") .. "/cotyper/model.json")
end

--- Root directory holding one subdirectory of style-guide versions per tag.
function M.style_dir()
  return M.values.style_dir or (vim.fn.stdpath("data") .. "/cotyper/styles")
end

return M
