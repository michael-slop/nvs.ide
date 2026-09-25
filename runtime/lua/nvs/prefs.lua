-- Settings for the nvs.ide Settings screen.
--
-- The screen is schema-driven: every setting here has a category, a control type, a
-- default, the Lua it maps to (shown next to the control and written to disk) and,
-- where possible, a way to apply it to the running session.
--
-- Values live in stdpath("data")/nvs-settings.json. Every change also regenerates
-- lua/nvs/settings.lua in the config folder, a plain Lua file that config/options.lua
-- loads after LazyVim's own options, so terminal Neovim sees the same settings.
-- Only values that differ from the default are written, so LazyVim's defaults keep
-- moving with LazyVim.
local M = {}

M.categories = { "Transition", "Keys", "Editor", "Completion", "Local AI", "Appearance", "Workbench", "Files", "Search", "Languages", "Git", "Terminal" }

local function B(v)
  return v and "true" or "false"
end
local function Q(v)
  return string.format("%q", tostring(v))
end
local function opt(name)
  return function(v)
    return ("vim.opt.%s = %s"):format(name, type(v) == "string" and Q(v) or tostring(v))
  end
end
local function apply_opt(name)
  return function(v)
    vim.opt[name] = v
  end
end
local function setting_g(key)
  -- Plugin options are read from vim.g.nvs_settings by lua/plugins/nvs.lua at startup.
  return function(v)
    return ("vim.g.nvs_settings.%s = %s"):format(key, type(v) == "string" and Q(v) or tostring(v))
  end
end

-- id, category, label, description, type (bool | number | select | text), options for
-- select as { { value, label } }, default, lua(v) -> line(s) for settings.lua, apply(v)
-- for the live session, restart = true when apply cannot do it live, search = extra
-- words (Vim option names) the search box should match.
M.schema = {
  -- Transition
  { id = "stage", c = "Transition", l = "Keybinding stage", d = "How much Vim you want. Each stage adds more of it. Your Neovim config is loaded at every stage.",
    t = "select", o = { { 1, "1 · VS Code keys" }, { 2, "2 · Hybrid" }, { 3, "3 · Modal with safety net" }, { 4, "4 · Pure Neovim" } }, def = 2,
    lua = function(v) return (":NvsStage %d  -- kept in nvs-ide.json"):format(v) end,
    get = function() return require("nvs.state").data.stage end,
    apply = function(v) require("nvs.stages").set(v) end, stored = false },
  { id = "coach", c = "Transition", l = "Coach hints", d = "When you do something the VS Code way, show the Vim way in a corner. How many times the same hint may appear.",
    t = "select", o = { { "always", "Every time" }, { "three", "First 3 times" }, { "once", "Once" }, { "off", "Never" } }, def = "three",
    lua = function(v) return (":NvsCoach %s  -- kept in nvs-ide.json"):format(v) end,
    get = function() return require("nvs.state").data.coach end,
    -- Through :NvsCoach's code path, so the hint counters reset and the window hears about it.
    apply = function(v) require("nvs.coach").command(v) end, stored = false },
  { id = "jk", c = "Transition", l = "jk leaves Insert mode", d = "Type j then k quickly to get back to Normal mode without reaching for Esc.", t = "bool", def = false,
    lua = function(v) return v and 'vim.keymap.set("i", "jk", "<Esc>", { desc = "Leave Insert mode" })' or nil end,
    apply = function(v)
      if v then
        vim.keymap.set("i", "jk", "<Esc>", { desc = "Leave Insert mode" })
      else
        pcall(vim.keymap.del, "i", "jk")
      end
    end },
  { id = "mouse", c = "Transition", l = "Mouse selection enters Visual mode", d = "Dragging with the mouse selects text the Vim way, so d, y and c act on it.", t = "bool", def = true,
    lua = function(v) return ('vim.opt.mouse = %s'):format(v and '"a"' or '""') end, apply = function(v) vim.opt.mouse = v and "a" or "" end, search = "mouse" },

  -- Keys
  { id = "leader", c = "Keys", l = "Leader key", d = "Opens the leader menu in Normal mode.", t = "select", o = { { " ", "Space" }, { "\\", "Backslash" }, { ",", "Comma" } }, def = " ",
    lua = function(v) return ("vim.g.mapleader = %s"):format(Q(v)) end, restart = true, search = "mapleader" },
  { id = "timeoutlen", c = "Keys", l = "Leader menu delay (ms)", d = "How long Neovim waits for the next key before which-key shows the menu.", t = "number", def = 300, min = 50, max = 2000,
    lua = opt("timeoutlen"), apply = apply_opt("timeoutlen"), search = "timeoutlen tm" },

  -- Editor
  { id = "number", c = "Editor", l = "Line numbers", d = "Show the line number column.", t = "bool", def = true, lua = opt("number"), apply = apply_opt("number"), search = "number nu" },
  { id = "relativenumber", c = "Editor", l = "Relative line numbers", d = "Number lines by distance from the cursor, so 7j is easy to read off.", t = "bool", def = true, lua = opt("relativenumber"), apply = apply_opt("relativenumber"), search = "relativenumber rnu" },
  { id = "cursorline", c = "Editor", l = "Highlight the cursor line", t = "bool", def = true, lua = opt("cursorline"), apply = apply_opt("cursorline"), search = "cursorline cul" },
  { id = "wrap", c = "Editor", l = "Wrap long lines", t = "bool", def = false, lua = opt("wrap"), apply = apply_opt("wrap"), search = "wrap" },
  { id = "tabstop", c = "Editor", l = "Tab size", d = "Also sets shiftwidth, the indent step.", t = "number", def = 2, min = 1, max = 16,
    lua = function(v) return ("vim.opt.tabstop = %d\nvim.opt.shiftwidth = %d"):format(v, v) end,
    apply = function(v) vim.opt.tabstop = v; vim.opt.shiftwidth = v end, search = "tabstop ts shiftwidth sw" },
  { id = "expandtab", c = "Editor", l = "Insert spaces for Tab", t = "bool", def = true, lua = opt("expandtab"), apply = apply_opt("expandtab"), search = "expandtab et" },
  { id = "scrolloff", c = "Editor", l = "Lines kept above and below the cursor", t = "number", def = 8, min = 0, max = 50, lua = opt("scrolloff"), apply = apply_opt("scrolloff"), search = "scrolloff so" },
  { id = "signcolumn", c = "Editor", l = "Sign column", d = "Where git changes and diagnostic signs appear.", t = "select", o = { { "yes", "Always" }, { "auto", "When there are signs" }, { "no", "Never" } }, def = "yes",
    lua = opt("signcolumn"), apply = apply_opt("signcolumn"), search = "signcolumn scl" },
  { id = "colorcolumn", c = "Editor", l = "Ruler column", d = "Draw a guide at this column, for example 80. Leave empty for none.", t = "text", def = "", lua = opt("colorcolumn"), apply = apply_opt("colorcolumn"), search = "colorcolumn cc" },
  { id = "list", c = "Editor", l = "Show whitespace", t = "bool", def = true, lua = opt("list"), apply = apply_opt("list"), search = "list listchars" },
  { id = "undofile", c = "Editor", l = "Keep undo history after closing", t = "bool", def = true, lua = opt("undofile"), apply = apply_opt("undofile"), search = "undofile" },
  { id = "spell", c = "Editor", l = "Spell checking", d = "Underlines misspelt words in comments and text files. ]s jumps to the next one, z= suggests.", t = "bool", def = false, lua = opt("spell"), apply = apply_opt("spell"), search = "spell" },

  -- Completion (blink.cmp; read at startup by lua/plugins/nvs.lua)
  { id = "cmp_auto", c = "Completion", l = "Show suggestions while typing", d = "The IntelliSense-style menu opens on its own as you type. Off means Ctrl+Space opens it.", t = "bool", def = true, lua = setting_g("cmp_auto"), restart = true, search = "blink auto_show" },
  { id = "cmp_docs", c = "Completion", l = "Show documentation beside the menu", t = "bool", def = true, lua = setting_g("cmp_docs"), restart = true, search = "blink documentation" },
  { id = "cmp_ghost", c = "Completion", l = "Preview the selected item inline", d = "Grey text shows what accepting would insert.", t = "bool", def = true, lua = setting_g("cmp_ghost"), restart = true, search = "blink ghost_text" },
  { id = "cmp_accept", c = "Completion", l = "Accept with", t = "select", o = { { "enter", "Enter" }, { "super-tab", "Tab" }, { "default", "Ctrl+Y (Vim default)" } }, def = "enter", lua = setting_g("cmp_accept"), restart = true, search = "blink keymap preset" },
  { id = "cmp_snippets", c = "Completion", l = "Include snippets", t = "bool", def = true, lua = setting_g("cmp_snippets"), restart = true, search = "blink snippets sources" },

  -- Local AI (kept in nvs-ide.json by nvs.ai; these call its commands)
  { id = "ai_on", c = "Local AI", l = "Use a local model", d = "Runs on your machine. Nothing leaves it unless you point the address somewhere else.", t = "bool", def = false,
    lua = function(v) return (":NvsAI %s  -- kept in nvs-ide.json"):format(v and "on" or "off") end,
    get = function() return require("nvs.state").data.ai.enabled end,
    apply = function(v) require("nvs.ai").command(v and "on" or "off") end, stored = false },
  { id = "ai_backend", c = "Local AI", l = "Backend", d = "Built in: nvs.ide runs llama.cpp and loads any GGUF model. Or an Ollama server, or any OpenAI-compatible one such as LM Studio.",
    t = "select", o = { { "llamacpp", "Built in (llama.cpp)" }, { "ollama", "Ollama" }, { "openai", "OpenAI-compatible server" } }, def = "llamacpp",
    lua = function(v) return (":NvsAI backend %s  -- kept in nvs-ide.json"):format(v) end,
    get = function() return require("nvs.state").data.ai.backend end,
    apply = function(v) require("nvs.ai").command("backend " .. v) end, stored = false },
  { id = "ai_server", c = "Local AI", l = "llama-server program", d = "Install llama.cpp with winget, scoop or brew, or give the full path.", t = "text", def = "llama-server",
    lua = function(v) return (":NvsAI server %s  -- kept in nvs-ide.json"):format(v) end,
    get = function() return require("nvs.state").data.ai.llamacpp.server end,
    apply = function(v) require("nvs.ai").command("server " .. v) end, stored = false },
  { id = "ai_models_dir", c = "Local AI", l = "Models folder", d = "Every .gguf file here shows up as a model. Empty means the nvs.ide data folder.", t = "text", def = "",
    lua = function(v) return ("-- llamacpp.models_dir = %s  (nvs-ide.json)"):format(Q(v)) end,
    get = function() return require("nvs.state").data.ai.llamacpp.models_dir end,
    apply = function(v) local s = require("nvs.state"); s.data.ai.llamacpp.models_dir = v; s.save(); pcall(function() require("nvs.ai").stop() end) end, stored = false },
  { id = "ai_models_max", c = "Local AI", l = "Models kept loaded", d = "The server loads a model on first use and keeps up to this many in memory.", t = "number", def = 2, min = 1, max = 8,
    lua = function(v) return ("-- llamacpp.models_max = %d  (nvs-ide.json)"):format(v) end,
    get = function() return require("nvs.state").data.ai.llamacpp.models_max end,
    apply = function(v) local s = require("nvs.state"); s.data.ai.llamacpp.models_max = v; s.save(); pcall(function() require("nvs.ai").stop() end) end, stored = false },
  { id = "ai_port", c = "Local AI", l = "llama-server port", t = "number", def = 8012, min = 1024, max = 65535,
    lua = function(v) return (":NvsAI port %d  -- kept in nvs-ide.json"):format(v) end,
    get = function() return require("nvs.state").data.ai.llamacpp.port end,
    apply = function(v) require("nvs.ai").command("port " .. v) end, stored = false },
  { id = "ai_url", c = "Local AI", l = "Server address", d = "For Ollama or an OpenAI-compatible server. A remote machine: forward its port over SSH and keep a local address.", t = "text", def = "http://localhost:11434",
    lua = function(v) return (":NvsAI url %s  -- kept in nvs-ide.json"):format(v) end,
    get = function()
      local a = require("nvs.state").data.ai
      return a.backend == "openai" and a.openai.url or a.ollama.url
    end,
    apply = function(v) require("nvs.ai").command("url " .. v) end, stored = false },
  { id = "ai_chat_model", c = "Local AI", l = "Model for Ask", d = "Empty uses the first model the server has. :NvsModel picks from a list.", t = "text", def = "",
    lua = function(v) return ("-- ai.chat_model = %s  (nvs-ide.json)"):format(Q(v)) end,
    get = function() return require("nvs.state").data.ai.chat_model end,
    apply = function(v) local s = require("nvs.state"); s.data.ai.chat_model = v; s.save() end, stored = false },
  { id = "ai_complete_model", c = "Local AI", l = "Model for ghost-text completion", d = "A small coder model keeps suggestions fast. Empty uses the Ask model.", t = "text", def = "",
    lua = function(v) return ("-- ai.complete_model = %s  (nvs-ide.json)"):format(Q(v)) end,
    get = function() return require("nvs.state").data.ai.complete_model end,
    apply = function(v) local s = require("nvs.state"); s.data.ai.complete_model = v; s.save() end, stored = false },
  { id = "ai_ghost", c = "Local AI", l = "Ghost-text suggestions", d = "Longer grey suggestions as you type, like Copilot. Alt+A accepts, Alt+L accepts one line, Alt+E dismisses. Takes effect after a restart.", t = "bool", def = true,
    lua = function(v) return ("-- ai.ghost_text = %s  (nvs-ide.json)"):format(B(v)) end,
    get = function() return require("nvs.state").data.ai.ghost_text end,
    apply = function(v) require("nvs.coach").command("ghost " .. (v and "on" or "off")) end, stored = false, restart = true },

  -- Appearance
  { id = "colorscheme", c = "Appearance", l = "Colour scheme", d = "More schemes install from Plugins.", t = "select", o = function()
      local out = {}
      for _, name in ipairs(vim.fn.getcompletion("", "color")) do
        table.insert(out, { name, name })
      end
      return out
    end, def = "necronomicon",
    lua = function(v) return ("vim.cmd.colorscheme(%s)"):format(Q(v)) end, apply = function(v) vim.cmd.colorscheme(v) end, search = "colorscheme theme" },
  { id = "font", c = "Appearance", l = "Font", d = "A monospace font installed on this machine. The house font is BigBlueTerm437 Nerd Font Mono.", t = "text", def = "BigBlueTerm437 Nerd Font Mono",
    lua = function(v) return ("vim.o.guifont = %s"):format(Q(v .. ":h" .. tostring(M.get("font_size")))) end,
    apply = function(v) vim.o.guifont = v .. ":h" .. tostring(M.get("font_size")) end, search = "guifont" },
  { id = "font_size", c = "Appearance", l = "Font size", d = "In points. The house font is a pixel font: 9 (12 px) and 18 (24 px) are crisp, the others are scaled.",
    t = "select", o = { { 9, "9 pt · 12 px, crisp" }, { 12, "12 pt · 16 px" }, { 13.5, "13.5 pt · 18 px" }, { 18, "18 pt · 24 px, crisp" } }, def = 9,
    lua = function(v) return ("vim.o.guifont = %s"):format(Q(M.get("font") .. ":h" .. tostring(v))) end,
    apply = function(v) vim.o.guifont = M.get("font") .. ":h" .. tostring(v) end, search = "guifont size" },
  { id = "blink", c = "Appearance", l = "Blinking cursor", t = "bool", def = false,
    lua = function(v) return v and 'vim.opt.guicursor:append("a:blinkwait700-blinkon400-blinkoff250")' or nil end,
    apply = function(v)
      if v then
        vim.opt.guicursor:append("a:blinkwait700-blinkon400-blinkoff250")
      else
        vim.opt.guicursor:append("a:blinkon0")
      end
    end, search = "guicursor blink" },

  -- Workbench (the shell reads these from the settings event)
  { id = "panel_on_start", c = "Workbench", l = "Open the bottom panel at startup", t = "bool", def = false, lua = setting_g("panel_on_start"), shell = true },
  { id = "sidebar_on_start", c = "Workbench", l = "Open the sidebar at startup", t = "bool", def = true, lua = setting_g("sidebar_on_start"), shell = true },
  { id = "confirm", c = "Workbench", l = "Ask before closing unsaved files", t = "bool", def = true, lua = opt("confirm"), apply = apply_opt("confirm"), search = "confirm" },

  -- Files
  { id = "autosave", c = "Files", l = "Auto save", t = "select", o = { { "off", "Off" }, { "delay", "After a pause in typing" }, { "focus", "When focus leaves the editor" } }, def = "off",
    lua = function(v)
      if v == "off" then return nil end
      return ('vim.api.nvim_create_autocmd(%s, { group = vim.api.nvim_create_augroup("nvs_autosave", { clear = true }), command = "silent! wall" })')
        :format(v == "delay" and '{ "CursorHold", "CursorHoldI" }' or '{ "FocusLost", "BufLeave" }')
    end,
    apply = function(v)
      local group = vim.api.nvim_create_augroup("nvs_autosave", { clear = true })
      if v ~= "off" then
        vim.api.nvim_create_autocmd(v == "delay" and { "CursorHold", "CursorHoldI" } or { "FocusLost", "BufLeave" }, { group = group, command = "silent! wall" })
      end
    end, search = "autosave autowrite" },
  { id = "trim", c = "Files", l = "Trim trailing whitespace on save", t = "bool", def = false,
    lua = function(v) return v and 'vim.api.nvim_create_autocmd("BufWritePre", { group = vim.api.nvim_create_augroup("nvs_trim", { clear = true }), command = [[%s/\\s\\+$//e]] })' or nil end,
    apply = function(v)
      local group = vim.api.nvim_create_augroup("nvs_trim", { clear = true })
      if v then
        vim.api.nvim_create_autocmd("BufWritePre", { group = group, command = [[%s/\s\+$//e]] })
      end
    end },
  { id = "fixendofline", c = "Files", l = "End files with a newline", t = "bool", def = true, lua = opt("fixendofline"), apply = apply_opt("fixendofline"), search = "fixendofline fixeol" },
  { id = "exclude", c = "Files", l = "Hide from the explorer and search", d = "Folder and file names, separated by commas.", t = "text", def = ".git,node_modules,target,.DS_Store", lua = setting_g("exclude"), shell = true },

  -- Search
  { id = "ignorecase", c = "Search", l = "Ignore case", t = "bool", def = true, lua = opt("ignorecase"), apply = apply_opt("ignorecase"), search = "ignorecase ic" },
  { id = "smartcase", c = "Search", l = "Match case when the search has capitals", t = "bool", def = true, lua = opt("smartcase"), apply = apply_opt("smartcase"), search = "smartcase scs" },
  { id = "hlsearch", c = "Search", l = "Highlight all matches", t = "bool", def = true, lua = opt("hlsearch"), apply = apply_opt("hlsearch"), search = "hlsearch hls" },
  { id = "rg_args", c = "Search", l = "Extra ripgrep arguments", d = "For the Search view and :grep, for example --hidden.", t = "text", def = "",
    lua = function(v) return ("vim.opt.grepprg = %s\nvim.g.nvs_settings.rg_args = %s"):format(Q(("rg --vimgrep " .. v):gsub("%s+$", "")), Q(v)) end,
    apply = function(v) vim.opt.grepprg = ("rg --vimgrep " .. v):gsub("%s+$", "") end, shell = true, search = "grepprg ripgrep" },

  -- Languages
  { id = "format_on_save", c = "Languages", l = "Format on save", d = "LazyVim's conform.nvim runs the formatter for the file type. Space c f formats by hand.", t = "bool", def = true,
    lua = function(v) return ("vim.g.autoformat = %s"):format(B(v)) end, apply = function(v) vim.g.autoformat = v end, search = "autoformat conform" },
  { id = "inlay_hints", c = "Languages", l = "Inlay hints", d = "Parameter names and types shown inline, when the language server provides them.", t = "bool", def = true,
    lua = setting_g("inlay_hints"), apply = function(v) pcall(vim.lsp.inlay_hint.enable, v) end, search = "inlay_hint" },
  { id = "virtual_text", c = "Languages", l = "Diagnostics at the end of the line", t = "bool", def = true, lua = setting_g("virtual_text"),
    apply = function(v)
      local cfg = vim.diagnostic.config()
      vim.diagnostic.config({ virtual_text = v and (type(cfg.virtual_text) == "table" and cfg.virtual_text or { spacing = 4, source = "if_many", prefix = "●" }) or false })
    end, search = "diagnostic virtual_text" },
  { id = "diag_signs", c = "Languages", l = "Diagnostic signs in the gutter", t = "bool", def = true, lua = setting_g("diag_signs"),
    apply = function(v)
      local cfg = vim.diagnostic.config()
      vim.diagnostic.config({ signs = v and (type(cfg.signs) == "table" and cfg.signs or true) or false })
    end, search = "diagnostic signs" },
  { id = "update_in_insert", c = "Languages", l = "Update diagnostics while typing", t = "bool", def = false, lua = setting_g("update_in_insert"),
    apply = function(v) vim.diagnostic.config({ update_in_insert = v }) end, search = "diagnostic update_in_insert" },

  -- Git (gitsigns; read at startup by lua/plugins/nvs.lua, toggled live here)
  { id = "git_signs", c = "Git", l = "Change markers in the gutter", t = "bool", def = true, lua = setting_g("git_signs"),
    apply = function(v) pcall(function() require("gitsigns").toggle_signs(v) end) end, search = "gitsigns signcolumn" },
  { id = "git_blame", c = "Git", l = "Blame on the current line", t = "bool", def = false, lua = setting_g("git_blame"),
    apply = function(v) pcall(function() require("gitsigns").toggle_current_line_blame(v) end) end, search = "gitsigns current_line_blame" },

  -- Terminal
  { id = "scrollback", c = "Terminal", l = "Scrollback lines", t = "number", def = 10000, min = 100, max = 100000, lua = opt("scrollback"), apply = apply_opt("scrollback"), search = "scrollback" },
}

local by_id = {}
for _, s in ipairs(M.schema) do
  by_id[s.id] = s
end

M.values = {} -- stored values (only settings with stored ~= false)
M.keybindings = {} -- imported VS Code keybindings: { { lhs=, command=, rhs=, desc= } }

local function path()
  return vim.fn.stdpath("data") .. "/nvs-settings.json"
end

function M.settings_file()
  return vim.fn.stdpath("config") .. "/lua/nvs/settings.lua"
end

local function options_of(s)
  if type(s.o) == "function" then
    return s.o()
  end
  return s.o or {}
end

-- Validate a value against its schema entry. Returns the clean value, or nil and why.
local function clean(s, v)
  if s.t == "bool" then
    if type(v) == "boolean" then return v end
    if v == "true" or v == 1 then return true end
    if v == "false" or v == 0 then return false end
    return nil, "expected true or false"
  elseif s.t == "number" then
    local n = tonumber(v)
    if not n then return nil, "expected a number" end
    if s.min and n < s.min then n = s.min end
    if s.max and n > s.max then n = s.max end
    if s.id ~= "font_size" then n = math.floor(n) end
    return n
  elseif s.t == "select" then
    for _, o in ipairs(options_of(s)) do
      if o[1] == v or tostring(o[1]) == tostring(v) then return o[1] end
    end
    return nil, "not one of the choices"
  else
    if type(v) ~= "string" then return nil, "expected text" end
    return v
  end
end

function M.load()
  M.values, M.keybindings = {}, {}
  local f = io.open(path(), "r")
  if not f then
    return
  end
  local ok, decoded = pcall(vim.json.decode, f:read("*a"))
  f:close()
  if not ok or type(decoded) ~= "table" then
    vim.schedule(function()
      vim.notify("Could not read " .. path() .. "; using default settings.", vim.log.levels.WARN, { title = "nvs.ide" })
    end)
    return
  end
  for id, v in pairs(decoded.values or {}) do
    local s = by_id[id]
    if s and s.stored ~= false then
      local c = clean(s, v)
      if c ~= nil then
        M.values[id] = c
      end
    end
  end
  if type(decoded.keybindings) == "table" then
    M.keybindings = decoded.keybindings
  end
end

local function save()
  vim.fn.mkdir(vim.fn.stdpath("data"), "p")
  local f = assert(io.open(path(), "w"))
  f:write(vim.json.encode({ values = M.values, keybindings = M.keybindings }))
  f:close()
end

function M.get(id)
  local s = by_id[id]
  if not s then
    return nil
  end
  if s.get then
    local ok, v = pcall(s.get)
    if ok and v ~= nil then
      return v
    end
    return s.def
  end
  local v = M.values[id]
  if v == nil then
    return s.def
  end
  return v
end

-- The generated file: only what differs from the defaults, plus imported keybindings.
function M.render()
  local out = {
    "-- settings.lua: written by the nvs.ide Settings screen (:NvsSettings). Do not edit:",
    "-- it is regenerated on every change. Your own options belong in lua/config/options.lua,",
    "-- which runs before this file, and keymaps in lua/config/keymaps.lua.",
    "vim.g.nvs_settings = vim.g.nvs_settings or {}",
    "",
  }
  for _, c in ipairs(M.categories) do
    local lines = {}
    for _, s in ipairs(M.schema) do
      if s.c == c and s.stored ~= false and s.lua then
        local v = M.get(s.id)
        if v ~= s.def then
          local l = s.lua(v)
          if l then
            for _, line in ipairs(vim.split(l, "\n")) do
              table.insert(lines, line)
            end
          end
        end
      end
    end
    if #lines > 0 then
      table.insert(out, "-- " .. c)
      vim.list_extend(out, lines)
      table.insert(out, "")
    end
  end
  if #M.keybindings > 0 then
    table.insert(out, "-- Imported from VS Code keybindings.json (Settings > Keys)")
    for _, k in ipairs(M.keybindings) do
      table.insert(out, ("vim.keymap.set(%s, %s, %s, { desc = %s%s })"):format(k.modes or '{ "n", "i" }', Q(k.lhs), k.rhs, Q(k.desc or k.command), k.remap and ", remap = true" or ""))
    end
    table.insert(out, "")
  end
  return out
end

function M.write()
  local file = M.settings_file()
  local text = table.concat(M.render(), "\n") .. "\n"
  local f, err = io.open(file, "w")
  if not f then
    vim.notify("Could not write " .. file .. ": " .. tostring(err), vim.log.levels.WARN, { title = "nvs.ide" })
    return false
  end
  f:write(text)
  f:close()
  return true
end

local function changed()
  M.write()
  vim.api.nvim_exec_autocmds("User", { pattern = "NvsSettingsChanged", modeline = false })
end

-- Set one setting: validate, store, apply to this session, regenerate the file.
-- Returns true, or false and a message.
function M.set(id, value)
  local s = by_id[id]
  if not s then
    return false, "unknown setting " .. tostring(id)
  end
  local v, why = clean(s, value)
  if v == nil then
    return false, why
  end
  if s.stored ~= false then
    if v == s.def then
      M.values[id] = nil
    else
      M.values[id] = v
    end
    save()
  end
  if s.apply then
    local ok, err = pcall(s.apply, v)
    if not ok then
      vim.notify(("%s: %s"):format(s.l, tostring(err)), vim.log.levels.WARN, { title = "nvs.ide" })
    end
  end
  changed()
  return true
end

function M.reset(id)
  local s = by_id[id]
  if s then
    return M.set(id, s.def)
  end
end

-- Everything the Settings screen needs, in one table.
function M.describe()
  local settings = {}
  for _, s in ipairs(M.schema) do
    local v = M.get(s.id)
    local options = {}
    for _, o in ipairs(options_of(s)) do
      table.insert(options, { value = o[1], label = o[2] })
    end
    local lua = s.lua and s.lua(v) or ""
    table.insert(settings, {
      id = s.id,
      category = s.c,
      label = s.l,
      desc = s.d or "",
      kind = s.t,
      options = options,
      value = v,
      default = s.def,
      lua = lua,
      restart = s.restart or false,
      shell = s.shell or false,
      search = s.search or "",
      min = s.min,
      max = s.max,
    })
  end
  return { categories = M.categories, settings = settings, keybindings = M.keybindings, file = M.settings_file() }
end

---------------------------------------------------------------------------
-- VS Code import
---------------------------------------------------------------------------

-- VS Code's settings.json allows comments and trailing commas.
local function decode_jsonc(text)
  text = text:gsub("/%*.-%*/", "")
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    -- Strip // comments outside strings.
    local out, in_str, i = {}, false, 1
    while i <= #line do
      local ch = line:sub(i, i)
      if in_str then
        table.insert(out, ch)
        if ch == "\\" then
          table.insert(out, line:sub(i + 1, i + 1))
          i = i + 1
        elseif ch == '"' then
          in_str = false
        end
      elseif ch == '"' then
        in_str = true
        table.insert(out, ch)
      elseif ch == "/" and line:sub(i + 1, i + 1) == "/" then
        break
      else
        table.insert(out, ch)
      end
      i = i + 1
    end
    table.insert(lines, table.concat(out))
  end
  text = table.concat(lines, "\n"):gsub(",(%s*[%]}])", "%1")
  return pcall(vim.json.decode, text)
end

function M.vscode_user_dir()
  if vim.fn.has("win32") == 1 then
    return (vim.env.APPDATA or "") .. "/Code/User"
  elseif vim.fn.has("mac") == 1 then
    return vim.env.HOME .. "/Library/Application Support/Code/User"
  end
  return (vim.env.XDG_CONFIG_HOME or (vim.env.HOME .. "/.config")) .. "/Code/User"
end

-- settings.json key -> { setting id, value mapper }. A mapper returns nil to skip.
local SETTINGS_MAP = {
  ["editor.fontFamily"] = { "font", function(v)
    local first = tostring(v):match("^%s*'?\"?([^,'\"]+)")
    return first and vim.trim(first) or nil
  end },
  ["editor.fontSize"] = { "font_size", function(v)
    local px = tonumber(v)
    if not px then return nil end
    local best, dist = 9, math.huge
    for _, o in ipairs({ { 9, 12 }, { 12, 16 }, { 13.5, 18 }, { 18, 24 } }) do
      if math.abs(o[2] - px) < dist then best, dist = o[1], math.abs(o[2] - px) end
    end
    return best
  end },
  ["editor.lineNumbers"] = { "relativenumber", function(v) return v == "relative" end },
  ["editor.tabSize"] = { "tabstop", function(v) return tonumber(v) end },
  ["editor.insertSpaces"] = { "expandtab", function(v) return v == true end },
  ["editor.wordWrap"] = { "wrap", function(v) return v ~= "off" end },
  ["editor.cursorBlinking"] = { "blink", function(v) return v ~= "solid" end },
  ["editor.cursorSurroundingLines"] = { "scrolloff", function(v) return tonumber(v) end },
  ["editor.renderWhitespace"] = { "list", function(v) return v == "all" or v == "boundary" or v == "trailing" end },
  ["editor.renderLineHighlight"] = { "cursorline", function(v) return v ~= "none" end },
  ["editor.rulers"] = { "colorcolumn", function(v)
    if type(v) ~= "table" then return nil end
    local cols = {}
    for _, r in ipairs(v) do
      table.insert(cols, tostring(type(r) == "table" and r.column or r))
    end
    return table.concat(cols, ",")
  end },
  ["editor.formatOnSave"] = { "format_on_save", function(v) return v == true end },
  ["editor.inlayHints.enabled"] = { "inlay_hints", function(v) return v == "on" or v == "onUnlessPressed" or v == true end },
  ["editor.quickSuggestions"] = { "cmp_auto", function(v)
    if type(v) == "boolean" then return v end
    if type(v) == "table" then return v.other ~= false and v.other ~= "off" end
    return nil
  end },
  ["editor.acceptSuggestionOnEnter"] = { "cmp_accept", function(v) return v == "off" and "super-tab" or "enter" end },
  ["editor.snippetSuggestions"] = { "cmp_snippets", function(v) return v ~= "none" end },
  ["files.autoSave"] = { "autosave", function(v)
    if v == "afterDelay" then return "delay" end
    if v == "onFocusChange" or v == "onWindowChange" then return "focus" end
    return "off"
  end },
  ["files.trimTrailingWhitespace"] = { "trim", function(v) return v == true end },
  ["files.insertFinalNewline"] = { "fixendofline", function(v) return v == true end },
  ["files.exclude"] = { "exclude", function(v)
    if type(v) ~= "table" then return nil end
    local names = {}
    for glob, on in pairs(v) do
      if on then
        table.insert(names, (glob:gsub("^%*%*/", ""):gsub("/%*%*$", "")))
      end
    end
    table.sort(names)
    return table.concat(names, ",")
  end },
  ["terminal.integrated.scrollback"] = { "scrollback", function(v) return tonumber(v) end },
  ["search.exclude"] = { "exclude", function(v)
    if type(v) ~= "table" then return nil end
    local names = {}
    for glob, on in pairs(v) do
      if on then
        table.insert(names, (glob:gsub("^%*%*/", ""):gsub("/%*%*$", "")))
      end
    end
    table.sort(names)
    return table.concat(names, ",")
  end },
}

-- Why a known VS Code key has no equivalent here.
local NO_EQUIVALENT = {
  ["editor.minimap.enabled"] = "nvs.ide has no minimap",
  ["workbench.colorTheme"] = "themes are Neovim colour schemes; pick one in Appearance",
  ["workbench.iconTheme"] = "icons are drawn by the shell",
  ["telemetry.telemetryLevel"] = "nvs.ide sends no telemetry",
  ["workbench.startupEditor"] = "the Welcome screen shows once",
}

-- keybindings.json command -> Lua rhs and a description. Missing commands are reported.
local COMMAND_MAP = {
  ["workbench.action.files.save"] = { rhs = "'<cmd>w<cr>'", desc = "Save file" },
  ["workbench.action.files.saveAll"] = { rhs = "'<cmd>wa<cr>'", desc = "Save all files" },
  ["workbench.action.quickOpen"] = { rhs = "function() Snacks.picker.files() end", desc = "Find file" },
  ["workbench.action.showCommands"] = { rhs = "function() Snacks.picker.commands() end", desc = "Command palette" },
  ["workbench.action.findInFiles"] = { rhs = "function() Snacks.picker.grep() end", desc = "Search project" },
  ["workbench.action.terminal.toggleTerminal"] = { rhs = "function() Snacks.terminal() end", desc = "Toggle terminal" },
  ["workbench.action.gotoLine"] = { rhs = "':'", desc = "Go to line", modes = '{ "n" }' },
  ["editor.action.formatDocument"] = { rhs = "function() LazyVim.format({ force = true }) end", desc = "Format document" },
  ["editor.action.rename"] = { rhs = "function() vim.lsp.buf.rename() end", desc = "Rename symbol" },
  ["editor.action.revealDefinition"] = { rhs = "function() vim.lsp.buf.definition() end", desc = "Go to definition" },
  ["editor.action.goToReferences"] = { rhs = "function() vim.lsp.buf.references() end", desc = "Find references" },
  ["editor.action.quickFix"] = { rhs = "function() vim.lsp.buf.code_action() end", desc = "Code action" },
  ["editor.action.commentLine"] = { rhs = "'gcc'", desc = "Toggle comment", modes = '{ "n" }', remap = true },
  ["editor.action.deleteLines"] = { rhs = "'dd'", desc = "Delete line", modes = '{ "n" }' },
  ["editor.action.moveLinesDownAction"] = { rhs = "'<cmd>m .+1<cr>=='", desc = "Move line down", modes = '{ "n" }' },
  ["editor.action.moveLinesUpAction"] = { rhs = "'<cmd>m .-2<cr>=='", desc = "Move line up", modes = '{ "n" }' },
  ["workbench.action.closeActiveEditor"] = { rhs = "function() Snacks.bufdelete() end", desc = "Close file" },
  ["workbench.action.nextEditor"] = { rhs = "'<cmd>bnext<cr>'", desc = "Next file" },
  ["workbench.action.previousEditor"] = { rhs = "'<cmd>bprevious<cr>'", desc = "Previous file" },
  ["editor.action.selectAll"] = { rhs = "'ggVG'", desc = "Select all", modes = '{ "n" }' },
}

-- "ctrl+shift+p" -> "<C-S-p>", "ctrl+k ctrl+s" -> "<C-k><C-s>", "f5" -> "<F5>"
local function vs_key_to_vim(key)
  local named = { escape = "Esc", enter = "CR", tab = "Tab", space = "Space", backspace = "BS", delete = "Del",
    up = "Up", down = "Down", left = "Left", right = "Right", home = "Home", ["end"] = "End", pageup = "PageUp", pagedown = "PageDown" }
  local out = {}
  for chord in key:lower():gmatch("%S+") do
    local mods, base = "", chord
    for _, m in ipairs({ { "ctrl%+", "C-" }, { "shift%+", "S-" }, { "alt%+", "A-" }, { "cmd%+", "D-" }, { "win%+", "D-" }, { "meta%+", "M-" } }) do
      if base:find(m[1]) then
        mods = mods .. m[2]
        base = base:gsub(m[1], "")
      end
    end
    if base:match("^f%d+$") then
      base = base:upper()
    elseif named[base] then
      base = named[base]
    elseif #base ~= 1 then
      return nil -- a key name we do not know
    end
    if mods == "" and #base == 1 then
      table.insert(out, base)
    else
      table.insert(out, "<" .. mods .. base .. ">")
    end
  end
  return table.concat(out)
end

-- Import settings.json (and keybindings.json when present). Returns a report table.
function M.import_vscode(dir)
  dir = dir or M.vscode_user_dir()
  local report = { dir = dir, applied = {}, skipped = {}, keys = {}, keys_skipped = {}, error = nil }
  local f = io.open(dir .. "/settings.json", "r")
  if not f then
    report.error = "No settings.json in " .. dir
    return report
  end
  local ok, data = decode_jsonc(f:read("*a"))
  f:close()
  if not ok or type(data) ~= "table" then
    report.error = "Could not parse " .. dir .. "/settings.json"
    return report
  end
  local keys = vim.tbl_keys(data)
  table.sort(keys)
  for _, key in ipairs(keys) do
    local m = SETTINGS_MAP[key]
    if m then
      local v = m[2](data[key])
      if v ~= nil then
        local s = by_id[m[1]]
        local c = clean(s, v)
        if c ~= nil then
          M.set(m[1], c)
          table.insert(report.applied, { key = key, from = tostring(data[key]), setting = s.l, value = tostring(c) })
        else
          table.insert(report.skipped, { key = key, why = "value not usable" })
        end
      else
        table.insert(report.skipped, { key = key, why = "value not usable" })
      end
    else
      table.insert(report.skipped, { key = key, why = NO_EQUIVALENT[key] or "no equivalent" })
    end
  end
  if data["editor.lineNumbers"] == "off" then
    M.set("number", false)
    table.insert(report.applied, { key = "editor.lineNumbers", from = "off", setting = "Line numbers", value = "false" })
  end

  local kf = io.open(dir .. "/keybindings.json", "r")
  if kf then
    local kok, list = decode_jsonc(kf:read("*a"))
    kf:close()
    if kok and type(list) == "table" then
      for _, b in ipairs(list) do
        if type(b) == "table" and type(b.key) == "string" and type(b.command) == "string" and not b.command:match("^%-") then
          local cmd = COMMAND_MAP[b.command]
          local lhs = vs_key_to_vim(b.key)
          if cmd and lhs then
            M.keybindings = vim.tbl_filter(function(k) return k.lhs ~= lhs end, M.keybindings)
            table.insert(M.keybindings, { lhs = lhs, command = b.command, rhs = cmd.rhs, desc = cmd.desc, modes = cmd.modes, remap = cmd.remap })
            table.insert(report.keys, { key = b.key, lhs = lhs, command = b.command, desc = cmd.desc })
          else
            table.insert(report.keys_skipped, { key = b.key, command = b.command, why = cmd and "key not understood" or "no equivalent command" })
          end
        end
      end
      save()
      changed()
    end
  end
  return report
end

function M.clear_keybindings()
  M.keybindings = {}
  save()
  changed()
end

M.load()

return M
