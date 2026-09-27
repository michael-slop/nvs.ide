-- Headless checks for the VS Code theme converter (runtime/lua/nvs/vsx_theme.lua).
-- Run inside the test sandbox so nothing touches your own config (PowerShell,
-- from the repo root; tests/run.ps1 -Sandbox <dir> creates the sandbox):
--   $sb = "$env:TEMP\nvs-sb"
--   $env:XDG_CONFIG_HOME="$sb\config"; $env:XDG_DATA_HOME="$sb\data"; $env:XDG_STATE_HOME="$sb\state"; $env:XDG_CACHE_HOME="$sb\cache"
--   $env:NVIM_APPNAME = 'nvs-ide'; $env:NVS_TEST = '1'
--   nvim --headless -c 'luafile tests/verify_theme.lua'
-- Every result line starts with PASS or FAIL; the exit code is the FAIL count.
--
-- What it proves: both Catppuccin fixtures convert to files under
-- stdpath("data")/vsx/colors/, load with :colorscheme from that folder (not
-- from the catppuccin.nvim plugin that ships schemes of the same name), set the
-- theme's editor colours and token styles, define every group the house scheme
-- defines with nothing left at Neovim's stock values, switch to a light
-- background for Latte, and hand the house scheme back unchanged. A theme
-- written in JSONC with an "include" converts too.

-- A prompt left open would hang a headless Neovim forever.
vim.defer_fn(function()
  io.write("FAIL watchdog: the checks did not finish in 60 s\n")
  io.flush()
  os.exit(4)
end, 60000)

local out = {}
local fails = 0
local function check(name, ok, detail)
  if not ok then
    fails = fails + 1
  end
  out[#out + 1] = (ok and "PASS " or "FAIL ") .. name .. (detail and ("  (" .. tostring(detail) .. ")") or "")
end

local function finish(code)
  io.write(table.concat(out, "\n") .. "\n")
  io.flush()
  os.exit(code or fails)
end

local ok_all, err_all = pcall(function()
  vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy", modeline = false })
  vim.wait(300)

  local repo = vim.fn.getcwd()
  local fixtures = repo .. "/tests/fixtures/vsx/Catppuccin.catppuccin-vsc/themes"
  local necro_file = repo .. "/runtime/colors/necronomicon.lua"
  local data = vim.fn.stdpath("data")
  local vsx = data .. "/vsx"
  local colors_dir = vsx .. "/colors"
  vim.fn.mkdir(colors_dir, "p")

  local function hl(name)
    return vim.api.nvim_get_hl(0, { name = name, link = false })
  end
  local function hex(n)
    return n and string.format("#%06x", n) or "nil"
  end
  local function same(a, b)
    return vim.deep_equal(a, b)
  end

  -- The house scheme's group list, read from the file so it never goes stale.
  local necro_groups = {}
  for line in io.lines(necro_file) do
    local g = line:match('^%s*hl%("([^"]+)"')
    if g then
      necro_groups[#necro_groups + 1] = g
    end
  end
  check("necronomicon group list read", #necro_groups > 100, #necro_groups .. " groups")

  -- 1. Snapshot the house scheme as it is at startup, then Neovim's stock values.
  check("house scheme active at start", vim.g.colors_name == "necronomicon", vim.g.colors_name)
  local house = {}
  for _, g in ipairs(necro_groups) do
    house[g] = hl(g)
  end
  local house_bg = vim.o.background
  vim.cmd("hi clear")
  local stock = {}
  for _, g in ipairs(necro_groups) do
    stock[g] = hl(g)
  end
  vim.cmd.colorscheme("necronomicon")

  -- 2. Convert both fixtures.
  local theme = require("nvs.vsx_theme")
  -- One naming rule, owned by nvs.vsx (it names the file the converter's output goes to).
  local vsx_name = require("nvs.vsx").scheme_name
  check("scheme_name from label", vsx_name("Catppuccin Mocha") == "catppuccin-mocha", vsx_name("Catppuccin Mocha"))
  local function convert(file, name)
    local src, report = theme.convert(fixtures .. "/" .. file, name)
    check("convert " .. file, src ~= nil, report and report.error)
    if not src then
      return nil, report
    end
    local f = assert(io.open(colors_dir .. "/" .. name .. ".lua", "w"))
    f:write(src)
    f:close()
    return src, report
  end
  local mocha_src, mocha_report = convert("mocha.json", "catppuccin-mocha")
  local latte_src, latte_report = convert("latte.json", "catppuccin-latte")
  if not mocha_src or not latte_src then
    finish(1)
  end

  -- The generated file is a colour scheme on its own.
  local first_statement
  for line in mocha_src:gmatch("[^\n]+") do
    if not line:match("^%s*%-%-") then
      first_statement = line
      break
    end
  end
  check("generated file starts with hi clear", first_statement == 'vim.cmd("hi clear")', first_statement)
  check("generated file sets colors_name", mocha_src:find('vim.g.colors_name = "catppuccin-mocha"', 1, true) ~= nil)
  check("generated file sets background", mocha_src:find('vim.o.background = "dark"', 1, true) ~= nil)
  local chunk, load_err = loadstring(mocha_src)
  check("generated file is valid Lua", chunk ~= nil, load_err)
  -- Of Catppuccin's 564 colours, the ones with a Neovim home (editor, gutter,
  -- widgets, lists, diagnostics, diffs, terminal) number around 80; the rest
  -- paint VS Code chrome Neovim does not have (activity bar, debug icons, ...).
  check("report counts colours", type(mocha_report.colors_mapped) == "number" and mocha_report.colors_mapped >= 70, mocha_report.colors_mapped)
  check("report counts token rules", type(mocha_report.tokens_mapped) == "number" and mocha_report.tokens_mapped > 20, mocha_report.tokens_mapped)
  check("report lists unknown scopes", type(mocha_report.unknown_scopes) == "table" and #mocha_report.unknown_scopes > 0, #mocha_report.unknown_scopes)
  check("report has warnings table", type(mocha_report.warnings) == "table", table.concat(mocha_report.warnings, "; "))

  -- 3. Load Mocha from the vsx folder and prove it was THIS file that ran.
  vim.opt.runtimepath:append(vsx)
  vim.cmd.colorscheme("catppuccin-mocha")
  check("colors_name is catppuccin-mocha", vim.g.colors_name == "catppuccin-mocha", vim.g.colors_name)
  check("background is dark", vim.o.background == "dark", vim.o.background)
  -- getscriptinfo takes a Vim pattern; the dots stand for either slash.
  local sourced = vim.fn.getscriptinfo({ name = "vsx.colors.catppuccin-mocha" })
  check("the vsx file was the one sourced", #sourced == 1, #sourced)
  check("catppuccin.nvim did not load instead", package.loaded["catppuccin"] == nil)

  local function is_stock(g)
    return same(hl(g), stock[g])
  end
  local function defined(g)
    return next(hl(g)) ~= nil
  end
  check("Normal bg = editor.background", hl("Normal").bg == 0x1e1e2e, hex(hl("Normal").bg))
  check("Normal fg = editor.foreground", hl("Normal").fg == 0xcdd6f4, hex(hl("Normal").fg))
  local c = hl("Comment")
  check("Comment fg = comment token colour", c.fg == 0x9399b2, hex(c.fg))
  check("Comment italic as the theme says", c.italic == true)
  check("@keyword fg = keyword token colour", hl("@keyword").fg == 0xcba6f7, hex(hl("@keyword").fg))
  check("@keyword not italic (theme resets fontStyle)", hl("@keyword").italic == nil)
  check("@string fg = string token colour", hl("@string").fg == 0xa6e3a1, hex(hl("@string").fg))
  check("@function fg + italic", hl("@function").fg == 0x89b4fa and hl("@function").italic == true, hex(hl("@function").fg))
  check("@type fg + italic", hl("@type").fg == 0xf9e2af and hl("@type").italic == true, hex(hl("@type").fg))
  check("@variable fg = text colour", hl("@variable").fg == 0xcdd6f4, hex(hl("@variable").fg))
  check("@operator = keyword.operator over keyword", hl("@operator").fg == 0x94e2d5, hex(hl("@operator").fg))
  check("@keyword.operator = most specific rule wins", hl("@keyword.operator").fg == 0xcba6f7, hex(hl("@keyword.operator").fg))
  check("@number fg", hl("@number").fg == 0xfab387, hex(hl("@number").fg))
  check("@boolean = constant.language.boolean over constant.language", hl("@boolean").fg == 0xfab387, hex(hl("@boolean").fg))
  check("@constant.builtin = constant.language", hl("@constant.builtin").fg == 0xf38ba8, hex(hl("@constant.builtin").fg))
  check("@variable.parameter fg + italic", hl("@variable.parameter").fg == 0xeba0ac and hl("@variable.parameter").italic == true)
  check("@tag fg", hl("@tag").fg == 0x89b4fa, hex(hl("@tag").fg))
  check("@tag.attribute fg", hl("@tag.attribute").fg == 0xf9e2af, hex(hl("@tag.attribute").fg))
  check("@property = json property-name rule", hl("@property").fg == 0x89b4fa, hex(hl("@property").fg))
  check("@markup.heading.1.markdown from heading.1.markdown", hl("@markup.heading.1.markdown").fg == 0xf38ba8, hex(hl("@markup.heading.1.markdown").fg))
  check("@markup.heading.2.markdown", hl("@markup.heading.2.markdown").fg == 0xfab387, hex(hl("@markup.heading.2.markdown").fg))
  check("@markup.strong bold", hl("@markup.strong").bold == true and hl("@markup.strong").fg == 0xf38ba8)
  check("@markup.italic italic", hl("@markup.italic").italic == true)
  check("@markup.raw = markdown code span colour", hl("@markup.raw").fg == 0xa6e3a1, hex(hl("@markup.raw").fg))
  check("@markup.link.url underlined", hl("@markup.link.url").underline == true and hl("@markup.link.url").fg == 0x89b4fa)
  check("LineNr = editorLineNumber.foreground", hl("LineNr").fg == 0x7f849c, hex(hl("LineNr").fg))
  check("CursorLineNr = editorLineNumber.activeForeground", hl("CursorLineNr").fg == 0xcba6f7, hex(hl("CursorLineNr").fg))
  check("Cursor = editorCursor", hl("Cursor").bg == 0xf5e0dc and hl("Cursor").fg == 0x1e1e2e)
  -- editor.lineHighlightBackground is #cdd6f412: alpha 0x12 blended over the editor background.
  check("CursorLine bg = lineHighlight blended over editor bg", hl("CursorLine").bg == 0x2a2b3c, hex(hl("CursorLine").bg))
  -- editor.selectionBackground is #9399b240.
  check("Visual bg = selection blended over editor bg", hl("Visual").bg == 0x3b3d4f, hex(hl("Visual").bg))
  check("Pmenu = editorSuggestWidget", hl("Pmenu").bg == 0x181825 and hl("Pmenu").fg == 0xcdd6f4, hex(hl("Pmenu").bg))
  check("PmenuSel bg = editorSuggestWidget.selectedBackground", hl("PmenuSel").bg == 0x313244, hex(hl("PmenuSel").bg))
  check("StatusLine = statusBar", hl("StatusLine").bg == 0x11111b and hl("StatusLine").fg == 0xcdd6f4)
  check("NormalFloat = editorWidget", hl("NormalFloat").bg == 0x181825)
  check("DiagnosticError = editorError.foreground", hl("DiagnosticError").fg == 0xf38ba8, hex(hl("DiagnosticError").fg))
  check("DiagnosticWarn = editorWarning.foreground", hl("DiagnosticWarn").fg == 0xfab387, hex(hl("DiagnosticWarn").fg))
  check("DiagnosticInfo = editorInfo.foreground", hl("DiagnosticInfo").fg == 0x89b4fa, hex(hl("DiagnosticInfo").fg))
  check("DiagnosticUnderlineError undercurl", hl("DiagnosticUnderlineError").undercurl == true and hl("DiagnosticUnderlineError").sp == 0xf38ba8)
  -- diffEditor.insertedLineBackground is #a6e3a126 (alpha 0x26).
  check("DiffAdd bg = inserted line blended", hl("DiffAdd").bg == 0x323b3f, hex(hl("DiffAdd").bg))
  check("DiffDelete has a bg and the deleted colour", hl("DiffDelete").bg ~= nil and hl("DiffDelete").fg == 0xf38ba8)
  check("Added = markup.inserted.diff", hl("Added").fg == 0xa6e3a1, hex(hl("Added").fg))
  check("Removed = markup.deleted.diff", hl("Removed").fg == 0xf38ba8, hex(hl("Removed").fg))
  -- editorWhitespace.foreground is #9399b266: a faint foreground, blended at 0.4.
  check("Whitespace = editorWhitespace.foreground blended (alpha 0x66)", hl("Whitespace").fg == 0x4d4f63, hex(hl("Whitespace").fg))
  check("MatchParen bold with bracket border", hl("MatchParen").bold == true and hl("MatchParen").sp == 0x9399b2)
  check("Todo from theme colours", hl("Todo").bg == 0xfab387 and hl("Todo").fg == 0x1e1e2e)
  check("Error from editorError", hl("Error").fg == 0xf38ba8 and hl("Error").bold == true)
  check("Title bold", hl("Title").bold == true and hl("Title").fg ~= nil)
  check("terminal_color_0 = terminal.ansiBlack", vim.g.terminal_color_0 == "#45475a", vim.g.terminal_color_0)
  check("terminal_color_15 = terminal.ansiBrightWhite", vim.g.terminal_color_15 == "#bac2de", vim.g.terminal_color_15)
  check("@lsp.type.enumMember from semanticTokenColors", hl("@lsp.type.enumMember").fg == 0x94e2d5, hex(hl("@lsp.type.enumMember").fg))
  check("@lsp.type.class.python from class:python", hl("@lsp.type.class.python").fg == 0xf9e2af, hex(hl("@lsp.type.class.python").fg))
  check("@lsp.typemod.variable.defaultLibrary", hl("@lsp.typemod.variable.defaultLibrary").fg == 0xeba0ac)
  check("@lsp.typemod.variable.readonly.javascript", hl("@lsp.typemod.variable.readonly.javascript").fg == 0xcdd6f4)

  local required = { "@keyword", "@string", "@function", "@type", "@variable", "LineNr", "CursorLine", "Visual", "Pmenu", "DiagnosticError", "DiffAdd" }
  for _, g in ipairs(required) do
    check(g .. " defined and not stock", defined(g) and not is_stock(g), vim.inspect(hl(g)):gsub("%s+", " "))
  end

  local missing, at_stock = {}, {}
  for _, g in ipairs(necro_groups) do
    if not defined(g) then
      missing[#missing + 1] = g
    elseif is_stock(g) then
      at_stock[#at_stock + 1] = g
    end
  end
  check("every necronomicon group defined", #missing == 0, #missing > 0 and ("missing: " .. table.concat(missing, " ")) or (#necro_groups .. " groups"))
  check("no necronomicon group left at stock values", #at_stock == 0, #at_stock > 0 and ("stock: " .. table.concat(at_stock, " ")) or nil)

  -- 4. Latte: a light theme.
  vim.cmd.colorscheme("catppuccin-latte")
  check("latte: colors_name", vim.g.colors_name == "catppuccin-latte", vim.g.colors_name)
  check("latte: background=light", vim.o.background == "light", vim.o.background)
  check("latte: Normal bg = editor.background", hl("Normal").bg == 0xeff1f5, hex(hl("Normal").bg))
  local nb = hl("Normal").bg or 0
  local lum = (0.2126 * math.floor(nb / 65536) + 0.7152 * (math.floor(nb / 256) % 256) + 0.0722 * (nb % 256)) / 255
  check("latte: Normal bg is light", lum > 0.7, string.format("luminance %.2f", lum))
  check("latte: Normal fg = editor.foreground", hl("Normal").fg == 0x4c4f69, hex(hl("Normal").fg))
  check("latte: Comment = latte comment colour", hl("Comment").fg == 0x7c7f93 and hl("Comment").italic == true, hex(hl("Comment").fg))
  check("latte: source sets background light", latte_src:find('vim.o.background = "light"', 1, true) ~= nil)
  check("latte: report ok", latte_report.colors_mapped >= 70 and latte_report.tokens_mapped > 20, latte_report.colors_mapped .. " colours, " .. latte_report.tokens_mapped .. " rules")

  -- 5. The house scheme comes back unchanged.
  vim.cmd.colorscheme("necronomicon")
  check("house scheme restored", vim.g.colors_name == "necronomicon", vim.g.colors_name)
  check("house background restored", vim.o.background == house_bg, vim.o.background)
  local changed = {}
  for _, g in ipairs(necro_groups) do
    if not same(hl(g), house[g]) then
      changed[#changed + 1] = g
    end
  end
  check("house groups unchanged after the theme round trip", #changed == 0, #changed > 0 and table.concat(changed, " ") or nil)

  -- 6. JSONC with comments, a trailing comma and an include of another file.
  local tmp = vim.fn.stdpath("cache") .. "/vsx-theme-test"
  vim.fn.mkdir(tmp, "p")
  local function write(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
  end
  write(tmp .. "/base.json", [[
{
  "type": "dark",
  "colors": {
    "editor.background": "#101010",
    "editor.foreground": "#e0e0e0",
    "editorLineNumber.foreground": "#505050"
  },
  "tokenColors": [
    { "scope": "comment", "settings": { "foreground": "#777777", "fontStyle": "italic" } },
    { "scope": "keyword", "settings": { "foreground": "#ff0000" } },
    { "scope": "string", "settings": { "foreground": "#00ff00" } }
  ]
}
]])
  write(tmp .. "/child.json", [[
// A theme that builds on base.json, written the way VS Code allows.
{
  "name": "Include Test",
  "include": "./base.json",
  "colors": {
    /* the child only repaints the editor */
    "editor.background": "#202030", // trailing comment
  },
  "tokenColors": [
    { "scope": "keyword", "settings": { "foreground": "#0000ff", }, },
  ],
}
]])
  local src, report = theme.convert(tmp .. "/child.json", "include-test")
  check("jsonc+include: converts", src ~= nil, report and report.error)
  if src then
    write(colors_dir .. "/include-test.lua", src)
    vim.cmd.colorscheme("include-test")
    check("jsonc+include: child colour wins", hl("Normal").bg == 0x202030, hex(hl("Normal").bg))
    check("jsonc+include: included colour kept", hl("Normal").fg == 0xe0e0e0, hex(hl("Normal").fg))
    check("jsonc+include: included token rule kept", hl("String").fg == 0x00ff00, hex(hl("String").fg))
    check("jsonc+include: child token rule overrides", hl("Keyword").fg == 0x0000ff, hex(hl("Keyword").fg))
    check("jsonc+include: comment italic from include", hl("Comment").fg == 0x777777 and hl("Comment").italic == true)
    check("jsonc+include: LineNr from include", hl("LineNr").fg == 0x505050, hex(hl("LineNr").fg))
    check("jsonc+include: files in report", report.files and #report.files == 2, report.files and #report.files)
    local warned = false
    for _, w in ipairs(report.warnings) do
      if w:find("terminal.ansi", 1, true) then
        warned = true
      end
    end
    check("jsonc+include: missing terminal colours are a warning", warned, table.concat(report.warnings, "; "))
    vim.cmd.colorscheme("necronomicon")
  end

  -- Light or dark: uiTheme decides (VS Code never reads the file's type), then a type we
  -- recognise, then the brightness of editor.background; an unknown type is reported.
  local function background_of(json, opts)
    write(tmp .. "/kind.json", json)
    local src, rep = theme.convert(tmp .. "/kind.json", "kind-test", opts)
    local bg = src and src:match('vim%.o%.background = "(%a+)"')
    return bg, rep
  end
  local white = '"colors": { "editor.background": "#ffffff", "editor.foreground": "#000000" }'
  local bg1 = background_of('{ "type": "Light", ' .. white .. ' }')
  check("type 'Light' (any case) is light", bg1 == "light", bg1)
  local bg2, r2 = background_of('{ "type": "hc", ' .. white .. ' }')
  local told = false
  for _, w in ipairs(r2.warnings or {}) do
    if w:find("is not light or dark", 1, true) then
      told = true
    end
  end
  check("unknown type: judged from colours and reported", bg2 == "light" and told, tostring(bg2) .. " / " .. table.concat(r2.warnings or {}, "; "))
  local bg3 = background_of('{ "type": "light", "colors": { "editor.background": "#101010" } }', { ui_theme = "vs-dark" })
  check("uiTheme wins over the file's type", bg3 == "dark", bg3)
  local bg4 = background_of('{ "colors": { "editor.background": "#101010" } }', { ui_theme = "hc-light" })
  check("uiTheme hc-light is light", bg4 == "light", bg4)

  -- Errors are sentences, not crashes.
  local none, bad = theme.convert(tmp .. "/missing.json", "missing")
  check("missing theme: nil source and an error", none == nil and type(bad.error) == "string", bad.error)
  local none2, bad2 = theme.convert(tmp .. "/child.json", "bad name")
  check("bad scheme name refused", none2 == nil and bad2.error ~= nil, bad2.error)

  -- Leave nothing behind but the converted files the sandbox owns.
  vim.fn.delete(tmp, "rf")
  vim.fn.delete(colors_dir .. "/include-test.lua")
end)

if not ok_all then
  fails = fails + 1
  out[#out + 1] = "FAIL harness error: " .. tostring(err_all)
end
finish()
