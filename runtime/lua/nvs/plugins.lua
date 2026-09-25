-- The Plugins screen's data: lazy.nvim's plugin list and LazyVim's extras, with a few
-- plain-English notes for the plugins everyone gets, and the actions the screen offers.
local M = {}

-- What a plugin is for, and what it replaces from VS Code. Keyed by lazy.nvim's name.
M.notes = {
  ["LazyVim"] = { desc = "The Neovim distribution nvs.ide is built on: defaults, keymaps and plugin setup for everything else.", eq = { "VS Code's out-of-the-box setup" } },
  ["lazy.nvim"] = { desc = "The plugin manager. :Lazy shows it.", eq = { "The Extensions view" } },
  ["snacks.nvim"] = { desc = "Fuzzy finder, file explorer, terminal, notifications and the dashboard in one plugin.", eq = { "Quick Open (Ctrl+P)", "Explorer", "Integrated terminal", "Notifications" } },
  ["blink.cmp"] = { desc = "The completion menu: suggestions from language servers, snippets, paths and the buffer, with documentation beside it.", eq = { "IntelliSense" } },
  ["which-key.nvim"] = { desc = "Shows what your next key can do. Powers the leader (Space) menu.", eq = { "Keyboard shortcut hints" } },
  ["gitsigns.nvim"] = { desc = "Git change markers in the gutter, hunk staging and line blame.", eq = { "GitLens", "Git gutter indicators" } },
  ["flash.nvim"] = { desc = "Jump anywhere on screen by typing two characters (s).", eq = {} },
  ["trouble.nvim"] = { desc = "A list for diagnostics, references and quickfix results (Space x x).", eq = { "Problems panel", "Error Lens" } },
  ["conform.nvim"] = { desc = "Runs formatters such as prettier, stylua and rustfmt, and formats on save.", eq = { "Prettier", "Format on save" } },
  ["nvim-lint"] = { desc = "Runs linters in the background and reports through diagnostics.", eq = { "ESLint" } },
  ["grug-far.nvim"] = { desc = "Search and replace across the whole project, with a live preview (Space s r).", eq = { "Replace in files (Ctrl+Shift+H)" } },
  ["mason.nvim"] = { desc = "Installs language servers, formatters, linters and debug adapters (:Mason).", eq = { "Language extensions that bundle a server" } },
  ["mason-lspconfig.nvim"] = { desc = "Connects mason's servers to Neovim's LSP client.", eq = {} },
  ["nvim-lspconfig"] = { desc = "Ready-made settings for every language server.", eq = { "Language extensions" } },
  ["nvim-treesitter"] = { desc = "Syntax parsing for highlighting, folding and text objects.", eq = { "Syntax highlighting grammars" } },
  ["nvim-treesitter-textobjects"] = { desc = "Select and move by function, class or argument (af, if, ]f).", eq = {} },
  ["bufferline.nvim"] = { desc = "The tab bar of open files in terminal Neovim. The nvs.ide window draws its own.", eq = { "Editor tabs" } },
  ["lualine.nvim"] = { desc = "The status line in terminal Neovim. The nvs.ide window draws its own.", eq = { "Status bar" } },
  ["noice.nvim"] = { desc = "Messages, the command line and notifications as popups.", eq = { "Notifications" } },
  ["nui.nvim"] = { desc = "UI building blocks used by noice.nvim.", eq = {} },
  ["mini.ai"] = { desc = "More text objects: arguments, quotes, brackets, function calls.", eq = {} },
  ["mini.pairs"] = { desc = "Closes brackets and quotes as you type.", eq = { "Auto closing brackets" } },
  ["mini.icons"] = { desc = "File and symbol icons for pickers and menus.", eq = { "Icon theme" } },
  ["mini.surround"] = { desc = "Add, change and delete brackets, quotes and tags around text (gsa, gsd, gsr).", eq = { "Bracket and quote wrapping" } },
  ["harpoon"] = { desc = "Pin the handful of files you work in and jump to each with one key (Space h).", eq = { "Pinned tabs" } },
  ["persistence.nvim"] = { desc = "Restores the last session for a folder (Space q s).", eq = { "Restore windows on startup" } },
  ["plenary.nvim"] = { desc = "Lua helpers other plugins depend on.", eq = {} },
  ["friendly-snippets"] = { desc = "Snippets for most languages, offered by the completion menu.", eq = { "Built-in snippets" } },
  ["lazydev.nvim"] = { desc = "Makes the Lua language server understand Neovim's API when editing your config.", eq = {} },
  ["todo-comments.nvim"] = { desc = "Highlights TODO, FIX and NOTE comments and lists them (Space s t).", eq = { "Todo Tree" } },
  ["ts-comments.nvim"] = { desc = "Comment strings for every language, so gcc always knows the syntax.", eq = {} },
  ["render-markdown.nvim"] = { desc = "Renders Markdown headings, lists, tables and code blocks in the editor (Space u m).", eq = { "Markdown preview, in place" } },
  ["markdown-preview.nvim"] = { desc = "A live Markdown preview in the browser (Space c p).", eq = { "Markdown preview (Ctrl+Shift+V)" } },
  ["minuet-ai.nvim"] = { desc = "Ghost-text code suggestions from your local model. Loads only when Local AI is on.", eq = { "GitHub Copilot, on your own machine" } },
  ["nvim-dap"] = { desc = "The debugger client (the Debug Adapter Protocol).", eq = { "Run and Debug" } },
  ["telescope.nvim"] = { desc = "The classic fuzzy finder. snacks.nvim covers the same jobs by default.", eq = { "Quick Open (Ctrl+P)" } },
}

local function plugin_state(p)
  local st = p._ or {}
  local enabled = p.enabled
  if type(enabled) == "function" then
    local ok, v = pcall(enabled)
    enabled = ok and v ~= false
  else
    enabled = enabled ~= false
  end
  local loads = {}
  if not p.lazy then
    table.insert(loads, "at startup")
  else
    for _, kind in ipairs({ "event", "ft", "cmd", "keys" }) do
      local v = p[kind]
      if type(v) == "table" and #v > 0 then
        local names = {}
        for _, item in ipairs(v) do
          if type(item) == "string" then
            table.insert(names, item)
          elseif type(item) == "table" then
            table.insert(names, item[1] or item.event or "")
          end
        end
        table.insert(loads, kind .. " " .. table.concat(names, ", "))
      elseif type(v) == "string" then
        table.insert(loads, kind .. " " .. v)
      end
    end
    if #loads == 0 then
      table.insert(loads, "when another plugin needs it")
    end
  end
  return {
    name = p.name,
    url = p.url or "",
    dir = p.dir or "",
    installed = st.installed == true,
    loaded = st.loaded ~= nil,
    lazy = p.lazy == true,
    enabled = enabled,
    dep = st.dep == true,
    updates = st.updates ~= nil,
    loads = loads,
    version = p.version and tostring(p.version) or (p.branch or ""),
    desc = M.notes[p.name] and M.notes[p.name].desc or "",
    eq = M.notes[p.name] and M.notes[p.name].eq or {},
  }
end

function M.list()
  local ok, lazy = pcall(require, "lazy")
  if not ok then
    return {}
  end
  local out = {}
  for _, p in ipairs(lazy.plugins()) do
    table.insert(out, plugin_state(p))
  end
  table.sort(out, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  return out
end

function M.extras()
  if not LazyVim or not LazyVim.extras then
    return {}
  end
  local ok, list = pcall(LazyVim.extras.get)
  if not ok then
    return {}
  end
  local out = {}
  for _, x in ipairs(list) do
    table.insert(out, {
      name = x.name,
      module = x.module,
      enabled = x.enabled == true,
      managed = x.managed == true,
      recommended = x.recommended == true,
      desc = x.desc or "",
      plugins = x.plugins or {},
    })
  end
  return out
end

function M.describe()
  local has_updates = false
  pcall(function()
    has_updates = require("lazy.status").has_updates()
  end)
  return { plugins = M.list(), extras = M.extras(), has_updates = has_updates }
end

-- Turn a LazyVim extra on or off in lazyvim.json, the way :LazyExtras does. A restart applies it.
function M.toggle_extra(module)
  if not LazyVim then
    return false, "LazyVim is not loaded"
  end
  local json = LazyVim.config.json
  local extras = json.data.extras or {}
  local on = vim.tbl_contains(extras, module)
  local extra
  for _, x in ipairs(LazyVim.extras.get()) do
    if x.module == module then
      extra = x
    end
  end
  if not extra then
    return false, "no extra called " .. module
  end
  if not extra.managed then
    return false, extra.name .. " is enabled from the config files, not from lazyvim.json; remove the import there to turn it off"
  end
  extras = vim.tbl_filter(function(name)
    return name ~= module
  end, extras)
  if not on then
    table.insert(extras, module)
  end
  table.sort(extras)
  json.data.extras = extras
  LazyVim.json.save()
  LazyVim.extras.state = nil
  vim.notify(("%s %s. Restart nvs.ide to apply it."):format(extra.name, on and "disabled" or "enabled"), vim.log.levels.INFO, { title = "nvs.ide · plugins" })
  return true
end

-- Actions the Plugins screen offers.
function M.action(what, name)
  if what == "update" and name and name ~= "" then
    vim.cmd("Lazy update " .. name)
  elseif what == "update_all" then
    vim.cmd("Lazy update")
  elseif what == "sync" then
    vim.cmd("Lazy sync")
  elseif what == "check" then
    vim.cmd("Lazy check")
  elseif what == "open" then
    vim.cmd("Lazy")
  elseif what == "extras" then
    vim.cmd("LazyExtras")
  elseif what == "toggle_extra" and name then
    local ok, err = M.toggle_extra(name)
    if not ok then
      vim.notify(err, vim.log.levels.WARN, { title = "nvs.ide · plugins" })
    end
  end
end

return M
