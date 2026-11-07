-- Headless test suite. Run from the repo root:
--   nvim --headless -l tests/run.lua
--
-- Covers the pure/local tiers only — nothing here talks to Ollama.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local passed, failed = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write("  ok   " .. name .. "\n")
  else
    failed = failed + 1
    io.write("  FAIL " .. name .. "\n       " .. tostring(err) .. "\n")
  end
end

local function eq(got, want, what)
  if got ~= want then
    error((what or "value") .. ": got " .. vim.inspect(got) .. ", want " .. vim.inspect(want), 2)
  end
end

local function truthy(v, what)
  if not v then
    error((what or "value") .. " should be truthy, got " .. vim.inspect(v), 2)
  end
end

local cotyper = require("cotyper")
local config = require("cotyper.config")
local ngram = require("cotyper.ngram")
local style = require("cotyper.style")
local util = require("cotyper.util")

local tmp = vim.fn.tempname()
config.merge({
  filetypes = {},
  llm = false,
  style_dir = tmp .. "/styles",
  data_file = tmp .. "/model.json",
  style_by_tag = true,
})

io.write("config\n")
test("merge applies user options over defaults", function()
  eq(config.values.llm, false, "llm")
  eq(config.values.lookahead, config.defaults.lookahead, "untouched default")
end)
test("merge mutates the shared table in place", function()
  local ref = config.values
  config.merge({ debounce = 42 })
  eq(ref.debounce, 42, "held reference sees update")
  config.merge({ filetypes = {}, llm = false, style_dir = tmp .. "/styles", style_by_tag = true })
end)

io.write("util\n")
test("words_of lowercases and splits on non-word chars", function()
  eq(table.concat(util.words_of("Hello, World's end!"), "|"), "hello|world's|end")
end)
test("strip_overlap drops repeated tail words", function()
  eq(util.strip_overlap("the quick brown", "brown fox jumps"), "fox jumps")
end)
test("strip_overlap ignores punctuation and case", function()
  eq(util.strip_overlap("it was contextual", "Contextual, aware"), "aware")
end)
test("strip_overlap leaves non-overlapping text alone", function()
  eq(util.strip_overlap("the quick", "brown fox"), "brown fox")
end)
test("strip_thinking removes reasoning blocks", function()
  eq(util.strip_thinking("<think>hmm</think>  answer  "), "answer")
end)
test("clip_completion keeps the first line and first sentence", function()
  eq(util.clip_completion("busier than usual. Then it rained\nmore"), "busier than usual.")
end)
test("clip_completion strips wrapping quotes, curly ones included", function()
  eq(util.clip_completion('"already left"'), "already left")
  eq(util.clip_completion("“already left”"), "already left")
end)
test("clip_completion leaves a leading em dash intact", function()
  eq(util.clip_completion("— or so I thought"), "— or so I thought")
end)
test("clip_completion drops a half-generated last word when truncated", function()
  eq(util.clip_completion("drank our tea bla", true), "drank our tea")
  eq(util.clip_completion("drank our tea bla", false), "drank our tea bla")
end)
test("echoes catches a phrase copied from the context", function()
  eq(util.echoes("The park was busy.\nWe walked", "The park was busy"), true)
  eq(util.echoes("The park was busy.\nWe walked", "to the shops"), false)
end)
test("echoes ignores short phrases", function()
  eq(util.echoes("the park", "the park"), false)
end)
test("drop_double_determiner removes 'a the'", function()
  eq(util.drop_double_determiner("the point is that a", "the system wins"), "system wins")
  eq(util.drop_double_determiner("I think that", "the system wins"), "the system wins")
end)

io.write("llm\n")
local llm = require("cotyper.llm")
test("messages put few-shot turns between system and document", function()
  local m = llm.messages("doc")
  eq(m[1].role, "system")
  eq(m[2].role, "user")
  eq(m[3].role, "assistant")
  eq(m[#m].content, "doc")
  eq(#m, 2 + 2 * #config.default_examples)
end)
test("examples = {} sends no few-shot turns", function()
  config.values.examples = {}
  eq(#llm.messages("doc"), 2)
  config.values.examples = nil
end)
test("finish spaces, clips and dedupes a completion", function()
  eq(llm.finish("the park was", "the park was", "busier than usual. More", false), " busier than usual.")
  eq(llm.finish("the park was ", "the park was ", "was busier", false), "busier")
end)
test("finish rejects an echo of the document", function()
  local ctx = "We ran out of milk on Tuesday.\nThen"
  eq(llm.finish("Then", ctx, "we ran out of milk", false), "")
end)

io.write("ngram\n")
test("learns and predicts a bigram", function()
  cotyper._learn_text("the quick brown fox the quick brown fox")
  -- trailing space = at a word boundary, so this takes the next-word path
  eq(cotyper._predict("the quick "), "brown")
end)
test("a prefix with no trailing space takes the complete-word path", function()
  -- "quick" is already whole, so there is nothing to extend it to
  eq(cotyper._predict("the quick"), nil)
end)
test("completes a partial word from the vocabulary", function()
  cotyper._learn_text("elephant elephant elephant")
  eq(cotyper._predict("eleph"), "ant")
end)
test("build_text chains several words at a boundary", function()
  local got = cotyper._suggest_text("the quick ")
  truthy(got:match("^brown"), "chained text starts with brown, got " .. vim.inspect(got))
end)
test("build_text returns empty for unknown context", function()
  eq(cotyper._suggest_text("zzzzqqq "), "")
end)
test("chain stops instead of repeating one word forever", function()
  local got = cotyper._suggest_text("the quick ")
  local seen, n = {}, 0
  for w in got:gmatch("%S+") do
    n = n + 1
    seen[w] = (seen[w] or 0) + 1
    truthy(seen[w] <= 2, "word '" .. w .. "' repeated too often in " .. vim.inspect(got))
  end
  truthy(n <= config.values.lookahead, "no more words than lookahead")
end)
test("save then load round-trips the model", function()
  ngram.save()
  truthy(vim.uv.fs_stat(config.data_path()), "model file written")
  ngram.load()
  eq(cotyper._predict("the quick "), "brown", "prediction survives reload")
end)

io.write("style: tags\n")
test("sanitize_tag lowercases and slugifies", function()
  eq(style.sanitize_tag("My Notes/Sub"), "my-notes-sub")
end)
test("sanitize_tag falls back to the default tag", function()
  eq(style.sanitize_tag("   "), config.values.default_tag)
  eq(style.sanitize_tag(nil), config.values.default_tag)
end)

local function buf_with(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

test("buf_tag reads an inline list", function()
  eq(cotyper._buf_tag(buf_with({ "---", "tags: [wikipedia, draft]", "---", "text" })), "wikipedia")
end)
test("buf_tag reads a bare inline value", function()
  eq(cotyper._buf_tag(buf_with({ "---", "tags: journal", "---" })), "journal")
end)
test("buf_tag reads a block list", function()
  eq(cotyper._buf_tag(buf_with({ "---", "tags:", "  - essay", "  - draft", "---" })), "essay")
end)
test("buf_tag falls back with no frontmatter", function()
  eq(cotyper._buf_tag(buf_with({ "just text" })), config.values.default_tag)
end)
test("buf_tag falls back with frontmatter but no tags", function()
  eq(cotyper._buf_tag(buf_with({ "---", "title: x", "---" })), config.values.default_tag)
end)
test("buf_tag is always the default tag when style_by_tag is off", function()
  config.values.style_by_tag = false
  eq(cotyper._buf_tag(buf_with({ "---", "tags: [wikipedia]", "---" })), config.values.default_tag)
  config.values.style_by_tag = true
end)

test("parse_tags collects every tag in an inline list", function()
  local t = style.parse_tags({ "---", "tags: [wikipedia, draft, stub]", "---" })
  eq(table.concat(t, ","), "wikipedia,draft,stub")
end)
test("parse_tags collects every tag in a block list", function()
  local t = style.parse_tags({ "---", "tags:", "  - essay", "  - draft", "---" })
  eq(table.concat(t, ","), "essay,draft")
end)
test("parse_tags stops at the end of the block list", function()
  local t = style.parse_tags({ "---", "tags:", "  - essay", "title: x", "  - notatag", "---" })
  eq(table.concat(t, ","), "essay")
end)
test("parse_tags dedupes and slugifies", function()
  local t = style.parse_tags({ "---", "tags: [Journal, '#journal', todo/week]", "---" })
  eq(table.concat(t, ","), "journal,todo-week")
end)
test("parse_tags ignores a buffer with no frontmatter", function()
  eq(#style.parse_tags({ "tags: [a]" }), 0)
end)

io.write("style: most-common tag\n")

-- A miniature vault: `journal` on three notes, `dream` on one, plus a pair of
-- one-note tags to exercise ties.
local vault = tmp .. "/vault"
local function note(name, tags)
  util.write_file(vault .. "/" .. name .. ".md", "---\ntags: [" .. tags .. "]\n---\nbody\n")
end
vim.fn.mkdir(vault, "p")
note("a", "journal")
note("b", "journal")
note("c", "journal, dream")
note("d", "dream")
note("e", "alpha")
note("f", "beta")
config.values.tag_root = vault

test("counts notes per tag across the vault", function()
  local counts = style.tag_counts(vault, { build = true })
  eq(counts.journal, 3, "journal")
  eq(counts.dream, 2, "dream")
  eq(counts.alpha, 1, "alpha")
end)
test("the most-used tag wins over the first one", function()
  local buf = buf_with({ "---", "tags: [dream, journal]", "---", "body" })
  eq(cotyper._buf_tag(buf, { build = true }), "journal")
end)
test("document order is kept when the counts tie", function()
  local buf = buf_with({ "---", "tags: [alpha, beta]", "---", "body" })
  eq(cotyper._buf_tag(buf, { build = true }), "alpha")
end)
test("a tag no note carries loses to one that has notes", function()
  local buf = buf_with({ "---", "tags: [unseen, dream]", "---", "body" })
  eq(cotyper._buf_tag(buf, { build = true }), "dream")
end)
test("a single tag is used as-is, without consulting the index", function()
  local buf = buf_with({ "---", "tags: [unseen]", "---", "body" })
  eq(cotyper._buf_tag(buf, { build = true }), "unseen")
end)
test("with no vault to count, the first tag wins", function()
  config.values.tag_root = nil
  local buf = buf_with({ "---", "tags: [dream, journal]", "---", "body" })
  eq(cotyper._buf_tag(buf, { build = true }), "dream")
  config.values.tag_root = vault
end)
test("tag_candidates reports the counts behind the choice", function()
  local buf = buf_with({ "---", "tags: [dream, journal]", "---", "body" })
  local c, indexed = style.tag_candidates(buf)
  truthy(indexed, "index available")
  eq(c[1].tag .. "=" .. c[1].count, "dream=2")
  eq(c[2].tag .. "=" .. c[2].count, "journal=3")
end)
config.values.tag_root = nil

io.write("style: versions\n")
test("save writes a version and current() reads it back", function()
  cotyper._save_style("essay", "GUIDE ONE")
  eq(#cotyper._versions("essay"), 1, "one version")
end)
test("a second save never overwrites the first", function()
  cotyper._save_style("essay", "GUIDE TWO")
  eq(#cotyper._versions("essay"), 2, "two versions")
end)
test("versions are ordered newest first", function()
  local v = cotyper._versions("essay")
  truthy(v[1].time > v[2].time or v[1].seq > v[2].seq, "newest sorts first")
  eq(util.read_file(v[1].path), "GUIDE TWO", "newest content")
end)
test("current() resolves the buffer's tag", function()
  vim.api.nvim_set_current_buf(buf_with({ "---", "tags: [essay]", "---", "body" }))
  eq(cotyper._current_style(), "GUIDE TWO")
end)
test("an untagged buffer has no guide", function()
  vim.api.nvim_set_current_buf(buf_with({ "plain text" }))
  eq(cotyper._current_style(), nil)
end)

io.write("ghost: render and accept\n")

-- A real (buftype="") buffer, since scratch buffers are never eligible.
-- `virtualedit=onemore` lets the cursor sit one past the last character, which is
-- where it lives in insert mode — cotyper only suggests at end of line.
vim.o.virtualedit = "onemore"

local function normal_buf(line, ft)
  vim.cmd("enew!")
  vim.bo.filetype = ft or "markdown"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
  vim.api.nvim_win_set_cursor(0, { 1, #line })
  assert(vim.api.nvim_win_get_cursor(0)[2] == #line, "cursor must reach end of line")
  return vim.api.nvim_get_current_buf()
end

test("trigger renders a ghost at the cursor", function()
  config.merge({ filetypes = {}, llm = false, style_dir = tmp .. "/styles", data_file = tmp .. "/model.json" })
  require("cotyper.ghost").refresh_filetypes()
  normal_buf("the quick ")
  cotyper.trigger()
  truthy(cotyper.is_visible(), "ghost visible after trigger")
end)

test("accept_word inserts only the first word", function()
  normal_buf("the quick ")
  cotyper.trigger()
  truthy(cotyper.is_visible(), "ghost visible")
  cotyper.accept_word()
  eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "the quick brown", "first word accepted")
end)

test("accept_all inserts the whole remaining phrase", function()
  normal_buf("the quick ")
  cotyper.trigger()
  local before = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
  cotyper.accept_all()
  local after = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
  truthy(#after > #before, "text grew: " .. vim.inspect(after))
  eq(cotyper.is_visible(), false, "ghost cleared after accept_all")
end)

test("dismiss clears the ghost", function()
  normal_buf("the quick ")
  cotyper.trigger()
  cotyper.dismiss()
  eq(cotyper.is_visible(), false)
end)

test("ineligible filetypes get no ghost", function()
  config.merge({ filetypes = { "markdown" }, llm = false, data_file = tmp .. "/model.json" })
  require("cotyper.ghost").refresh_filetypes()
  normal_buf("the quick ", "python")
  cotyper.trigger()
  eq(cotyper.is_visible(), false, "no ghost in a non-markdown buffer")
  normal_buf("the quick ", "markdown")
  cotyper.trigger()
  truthy(cotyper.is_visible(), "ghost in a markdown buffer")
end)

test("toggle disables suggestions", function()
  local ghost = require("cotyper.ghost")
  normal_buf("the quick ")
  eq(ghost.toggle(), false, "toggled off")
  cotyper.trigger()
  eq(cotyper.is_visible(), false, "no ghost while disabled")
  eq(ghost.toggle(), true, "toggled back on")
  cotyper.trigger()
  truthy(cotyper.is_visible(), "ghost returns when re-enabled")
end)

io.write("public API\n")
test("exposes the documented surface", function()
  for _, fn in ipairs({
    "setup", "trigger", "is_visible", "accept_word", "accept_all",
    "dismiss", "save", "load", "assess_style",
  }) do
    eq(type(cotyper[fn]), "function", "M." .. fn)
  end
end)
test("setup registers the user commands", function()
  cotyper.setup({ llm = false, style_dir = tmp .. "/styles", data_file = tmp .. "/model.json" })
  local cmds = vim.api.nvim_get_commands({})
  for _, name in ipairs({
    "CotyperToggle", "CotyperDismiss", "CotyperDebug",
    "CotyperAssessStyle", "CotyperStyle", "CotyperStyleHistory", "CotyperTag",
  }) do
    truthy(cmds[name], name .. " registered")
  end
end)
test("setup maps the accept_word key in insert mode", function()
  local m = vim.fn.maparg("<C-l>", "i", false, true)
  eq(m.desc, "cotyper: accept word")
end)
test("keymaps = false maps nothing", function()
  pcall(vim.keymap.del, "i", "<C-l>")
  cotyper.setup({ llm = false, keymaps = false, style_dir = tmp .. "/styles", data_file = tmp .. "/model.json" })
  eq(vim.fn.maparg("<C-l>", "i"), "")
end)
test("is_visible is false once the ghost is dismissed", function()
  cotyper.dismiss()
  eq(cotyper.is_visible(), false)
end)

vim.fn.delete(tmp, "rf")
io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
