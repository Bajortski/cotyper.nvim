# cotyper.nvim
Inline autocomplete for Neovim, inspired by [Cotypist](https://cotypist.app/). Ghost text appears ahead of your cursor as you type; pressing Tab accepts it one word at a time; keep typing to clear the ghost. Built by Claude Fable.

Two prediction tiers work together:
1. **Instant** — a local n-gram model that **learns from your own writing** and persists to disk. Zero latency, gives the "snaps to the word you meant" feel.
2. **Smart** — a debounced async call to a local model that supersedes the n-gram guess with a richer continuation when it arrives.

Everything runs locally.

## Usage

| Key      | When                | Does                                             |
|----------|---------------------|--------------------------------------------------|
| *(type)* | insert mode         | Grey ghost text is suggested inline as you write |
| `Tab`    | a ghost is showing  | Accept the **next word** (press again to walk it)|
| *(type)* | a ghost is showing  | Ignore it — the ghost re-snaps to what you meant |

Tab is wired in your own keymap (see Installation). Also:
- `require("cotyper").accept_all()` — accept the whole suggestion at once.
- `:CotyperToggle` — turn suggestions on/off.
- `:CotyperDismiss` — clear the current ghost.
- `:CotyperDebug` — toggle debug notifications: when the debounce fires, when a query
  starts, and when it completes (with elapsed ms). Handy for diagnosing LLM latency.
- `:CotyperAssessStyle` — have the model read the current buffer and write a concise style
  guide (voice, rhythm, diction, quirks). It's saved to disk and folded into every
  completion prompt, so suggestions track your voice. Re-run it to refine the guide from
  new writing (it revises the previous one rather than starting over). **Every assessment
  is kept** as a timestamped version — nothing is overwritten. Your explicit `style`
  preferences always take precedence over the learned guide.
- `:CotyperStyle [n]` — print the active tag's current style guide, or version `n`
  (`1` = newest; see `:CotyperStyleHistory` for the numbering).
- `:CotyperStyleHistory` — list the saved versions for the active tag, newest first, with
  timestamps.
- `:CotyperTag` — show which style tag the current buffer resolves to (see *Per-tag style
  guides* below).

## Requirements
- Neovim 0.10+ (`vim.system`, `vim.uv`).
- `curl` on `PATH`.
- For the smart tier: [Ollama](https://ollama.com) running locally, plus a model of your
  choice pulled and named in `opts.model` — cotyper doesn't assume one. For example:
  ```sh
  ollama pull gemma4:e2b-mlx   # then: opts = { model = "gemma4:e2b-mlx" }
  ```
  The n-gram tier works fine on its own; leave `model` unset (or `llm = false`) to skip
  the LLM entirely.

## Installation (lazy.nvim)
```lua

{
  "Bajortski/cotyper.nvim",
  event = "InsertEnter",
  opts = {
    model = "gemma4:e2b-mlx", -- any Ollama model you've pulled; required for the LLM tier
  },
  config = function(_, opts)
    require("cotyper").setup(opts)
  end,
}
```

cotyper only accepts the ghost when you tell it to. Wire `Tab` wherever your completion `Tab` lives so it takes priority when a ghost is visible, e.g. in a blink.cmp keymap:
```lua
["<Tab>"] = {
  function(cmp)
    local ok, ct = pcall(require, "cotyper")
    if ok and ct.is_visible() then ct.accept_word(); return true end
    return cmp.accept()
  end,
  "fallback",
},
```

## Configuration
`opts` is passed to `require("cotyper").setup()`. Defaults:

```lua
opts = {
  model      = nil,            -- REQUIRED for the LLM tier: any Ollama model you've pulled
  endpoint   = "http://localhost:11434/api/chat", -- Ollama native API (honours `think`)
  think      = false,          -- false = no reasoning tokens (fast); thinking models only
  filetypes  = { "markdown" }, -- nil/empty = every normal buffer
  debounce   = 150,            -- ms of idle after typing before a suggestion appears (0 = instant)
  order      = 3,              -- n-gram order
  min_count  = 2,              -- prune threshold once the model passes prune_cap
  prune_cap  = 15000,          -- unique words before pruning kicks in
  save_interval = 60,          -- seconds between background model saves
  context_lines = 8,           -- buffer lines sent to the LLM (smaller = faster eval)
  max_tokens = 20,             -- num_predict: tokens generated per completion
  num_ctx    = 1024,           -- context window cap (gemma4 defaults to 128K, slow)
  keep_alive = "10m",          -- keep the model resident so it doesn't cold-reload
  llm        = true,           -- false = n-gram tier only
  highlight  = { fg = "#808080", italic = true }, -- attrs, or a group name to link
  system_prompt = "...",       -- general autocomplete instruction; see source for default
  style      = nil,            -- your personal voice/dialect, appended after system_prompt
  debug      = false,          -- notify on debounce fire / query start / query complete
  data_file  = nil,            -- default: stdpath("data").."/cotyper/model.json"
  style_dir    = nil,          -- default: stdpath("data").."/cotyper/styles"
  style_by_tag = false,        -- true = pick the guide from the note's frontmatter first tag
  default_tag  = "default",    -- guide used when style_by_tag=false, or a note has no tags
}
```

`system_prompt` holds the general "act like ghost-text autocomplete" instruction; keep your own preferences (name, dialect, tone) in `style` instead, so they stay separate and easy to edit. `style` is appended after `system_prompt` at request time. For example:
```lua
opts = {
  style = "Write in British English (-ise spellings), in a clear, sardonic voice. "
    .. "Keep sentences short and concise.",
}
```

Prose-only, ghost linked to your `Comment` colour, no LLM:
```lua
opts = {
  filetypes = { "markdown", "text", "tex" },
  highlight = "Comment",
  llm = false,
}
```

## Style guides, versioned & tagged
`:CotyperAssessStyle` writes a style guide under `style_dir` and folds it into every
completion prompt. Guides are **versioned** — each assessment is saved as its own
timestamped file (`styles/<tag>/<epoch>.md`) and older versions are kept forever. Browse
them with `:CotyperStyleHistory` and print any one with `:CotyperStyle <n>`; to roll back,
just delete newer files on disk.

By default there's a single guide (tag `default`). Turn on `style_by_tag = true` to keep
**separate guides per tag**, chosen automatically from the current note's Obsidian
frontmatter — the first entry of `tags:` (or `tag:`) picks the guide:

```markdown
---
tags: [wikipedia]
---
```
…routes assessments and completions through `styles/wikipedia/`. Notes without a tag fall
back to `default_tag`. `:CotyperTag` shows which tag the current buffer resolves to. A
pre-existing `style.md` from before versioning is migrated into `styles/default/` on first
run.

## How the model learns
Words from your markdown buffers are folded into unigram/bigram/trigram counts on
`InsertLeave` and `BufWritePost`. The model is saved every `save_interval` seconds (and on
exit) to `data_file`, and reloaded on startup — so predictions improve the more you write
and survive restarts. Rare entries are pruned once the vocabulary grows past `prune_cap`.

## License
I do not care what you do with this.
