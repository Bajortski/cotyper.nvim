-- User commands. Registered once from setup().

local api = vim.api

local config = require("cotyper.config")
local ghost = require("cotyper.ghost")
local style = require("cotyper.style")
local util = require("cotyper.util")

local M = {}

local cfg = config.values

--- Resolve the active tag and its versions, notifying when the tag has no guide.
---@return string|nil tag, table|nil versions
local function tag_versions()
  local tag = style.buf_tag(api.nvim_get_current_buf())
  local v = style.versions(tag)
  if #v == 0 then
    vim.notify("cotyper: [" .. tag .. "] no style guide yet — run :CotyperAssessStyle.")
    return nil
  end
  return tag, v
end

function M.setup()
  api.nvim_create_user_command("CotyperToggle", function()
    vim.notify("cotyper " .. (ghost.toggle() and "enabled" or "disabled"))
  end, { desc = "Toggle cotyper suggestions" })

  api.nvim_create_user_command("CotyperDismiss", function()
    ghost.clear()
  end, { desc = "Dismiss the current suggestion" })

  api.nvim_create_user_command("CotyperDebug", function()
    cfg.debug = not cfg.debug
    vim.notify("cotyper debug " .. (cfg.debug and "on" or "off"))
  end, { desc = "Toggle cotyper debug notifications" })

  api.nvim_create_user_command("CotyperAssessStyle", style.assess, {
    desc = "Have the model assess this buffer's writing style and use it in completions",
  })

  api.nvim_create_user_command("CotyperStyle", function(a)
    local tag, v = tag_versions()
    if not tag then
      return
    end
    local n = tonumber(a.args) or 1
    local entry = v[n]
    if not entry then
      vim.notify(
        "cotyper: [" .. tag .. "] version " .. n .. " does not exist (1.." .. #v .. ").",
        vim.log.levels.WARN
      )
      return
    end
    local text = util.read_file(entry.path) or "(empty)"
    vim.notify("── [" .. tag .. "] style guide " .. n .. "/" .. #v .. " ──\n" .. text)
  end, { nargs = "?", desc = "Show the active tag's style guide (optional version number, 1=newest)" })

  api.nvim_create_user_command("CotyperStyleHistory", function()
    local tag, v = tag_versions()
    if not tag then
      return
    end
    local lines = { "── [" .. tag .. "] style history (" .. #v .. ") ──" }
    for i, entry in ipairs(v) do
      lines[#lines + 1] = string.format(
        "%d  %s%s",
        i,
        os.date("%Y-%m-%d %H:%M", entry.time),
        i == 1 and "  (current)" or ""
      )
    end
    vim.notify(table.concat(lines, "\n"))
  end, { desc = "List saved style-guide versions for the active tag (newest first)" })

  api.nvim_create_user_command("CotyperTag", function()
    local buf = api.nvim_get_current_buf()
    local tag = style.buf_tag(buf)
    local mode = cfg.style_by_tag and "from frontmatter" or "style_by_tag off"
    local lines = { "cotyper: active style tag = [" .. tag .. "] (" .. mode .. ")" }

    -- Show the runners-up and their vault counts, so a surprising pick can be
    -- traced to the numbers behind it rather than guessed at.
    local candidates, indexed = style.tag_candidates(buf)
    if cfg.style_by_tag and #candidates > 1 then
      local root = style.vault_root(api.nvim_buf_get_name(buf))
      lines[#lines + 1] = indexed and ("counted over " .. root)
        or (root and "vault index still warming — using document order" or "no vault found — using document order")
      for _, c in ipairs(candidates) do
        lines[#lines + 1] = string.format(
          "  %s %-24s %s",
          c.tag == tag and "→" or " ",
          c.tag,
          c.count and (c.count .. " notes") or ""
        )
      end
    end
    vim.notify(table.concat(lines, "\n"))
  end, { desc = "Show which style tag the current buffer resolves to, and why" })
end

return M
