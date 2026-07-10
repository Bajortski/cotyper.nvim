# cotyper.nvim

Always-on inline autocomplete for Neovim, inspired by the [Cotypist](https://cotypist.app/)
macOS app. Ghost text appears as you type; **Tab accepts it one word at a time**; keep
typing to reject. Built by Bajortski (with Claude).

Two prediction tiers work together:

1. **Instant** — a local n-gram model that **learns from your own writing** and persists
   to disk. Zero latency, gives the "snaps to the word you meant" feel.
2. **Smart** — a debounced async call to a local LLM (`gemma4` via Ollama) that
   supersedes the n-gram guess with a richer continuation when it arrives.

Everything runs locally. No prose leaves your machine.

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

cotyper only accepts the ghost when you tell it to. Wire `Tab` wherever your completion
`Tab` lives so it takes priority when a ghost is visible, e.g. in a blink.cmp keymap:

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
  context_lines = 20,          -- buffer lines sent to the LLM
  max_tokens = 48,
  llm        = true,           -- false = n-gram tier only
  highlight  = { fg = "#808080", italic = true }, -- attrs, or a group name to link
  system_prompt = "...",       -- see source for the default
  data_file  = nil,            -- default: stdpath("data").."/cotyper/model.json"
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

## How the model learns

Words from your markdown buffers are folded into unigram/bigram/trigram counts on
`InsertLeave` and `BufWritePost`. The model is saved every `save_interval` seconds (and on
exit) to `data_file`, and reloaded on startup — so predictions improve the more you write
and survive restarts. Rare entries are pruned once the vocabulary grows past `prune_cap`.

## License

I do not care what you do with this.
