-- necronomicon: the house palette, shared with the nvs.ide shell chrome.
local p = {
  void = "#05070a", crypt = "#0a0e14", crypt_hi = "#111823",
  stone = "#1a2430", stone_hi = "#26333f",
  bone = "#d8d4c4", bone_dim = "#8b8778", ash = "#5c6470",
  spectral = "#62e670", spectral_hi = "#c8ffd0",
  corpse = "#4fb8d6", necrotic = "#9d6bd8", viscera = "#b8453a", gold = "#d4a843",
}

vim.cmd("hi clear")
if vim.fn.exists("syntax_on") == 1 then
  vim.cmd("syntax reset")
end
vim.o.background = "dark"
vim.g.colors_name = "necronomicon"

local function hl(group, spec)
  vim.api.nvim_set_hl(0, group, spec)
end

-- Editor
hl("Normal", { fg = p.bone, bg = p.crypt })
hl("NormalNC", { fg = p.bone, bg = p.crypt })
hl("NormalFloat", { fg = p.bone, bg = p.crypt_hi })
hl("FloatBorder", { fg = p.stone_hi, bg = p.crypt_hi })
hl("FloatTitle", { fg = p.spectral, bg = p.crypt_hi })
hl("Cursor", { fg = p.void, bg = p.spectral })
hl("CursorLine", { bg = p.crypt_hi })
hl("CursorLineNr", { fg = p.gold, bold = true })
hl("LineNr", { fg = p.ash })
hl("SignColumn", { bg = p.crypt })
hl("ColorColumn", { bg = p.crypt_hi })
hl("WinSeparator", { fg = p.stone_hi })
hl("VertSplit", { link = "WinSeparator" })
hl("Visual", { bg = p.stone_hi })
hl("Search", { fg = p.void, bg = p.gold })
hl("IncSearch", { fg = p.void, bg = p.spectral })
hl("CurSearch", { link = "IncSearch" })
hl("MatchParen", { fg = p.spectral, bold = true, underline = true })
hl("NonText", { fg = p.stone_hi })
hl("Whitespace", { fg = p.stone_hi })
hl("EndOfBuffer", { fg = p.crypt })
hl("Folded", { fg = p.bone_dim, bg = p.stone })
hl("StatusLine", { fg = p.bone, bg = p.stone })
hl("StatusLineNC", { fg = p.ash, bg = p.crypt_hi })
hl("TabLine", { fg = p.bone_dim, bg = p.stone })
hl("TabLineSel", { fg = p.bone, bg = p.crypt, bold = true })
hl("TabLineFill", { bg = p.stone })
hl("Pmenu", { fg = p.bone, bg = p.stone })
hl("PmenuSel", { fg = p.spectral_hi, bg = p.stone_hi, bold = true })
hl("PmenuSbar", { bg = p.stone })
hl("PmenuThumb", { bg = p.stone_hi })
hl("Title", { fg = p.spectral, bold = true })
hl("Directory", { fg = p.corpse })
hl("Question", { fg = p.spectral })
hl("MoreMsg", { fg = p.spectral })
hl("ModeMsg", { fg = p.spectral, bold = true })
hl("ErrorMsg", { fg = p.viscera, bold = true })
hl("WarningMsg", { fg = p.gold })
hl("WildMenu", { link = "PmenuSel" })

-- Syntax
hl("Comment", { fg = p.ash, italic = true })
hl("Constant", { fg = p.gold })
hl("String", { fg = p.spectral_hi })
hl("Character", { link = "String" })
hl("Number", { fg = p.gold })
hl("Boolean", { fg = p.gold })
hl("Identifier", { fg = p.bone })
hl("Function", { fg = p.corpse })
hl("Statement", { fg = p.necrotic })
hl("Keyword", { fg = p.necrotic })
hl("Conditional", { fg = p.necrotic })
hl("Repeat", { fg = p.necrotic })
hl("Operator", { fg = p.bone_dim })
hl("PreProc", { fg = p.necrotic })
hl("Type", { fg = p.gold })
hl("Special", { fg = p.corpse })
hl("Delimiter", { fg = p.bone_dim })
hl("Underlined", { fg = p.corpse, underline = true })
hl("Todo", { fg = p.void, bg = p.gold, bold = true })
hl("@variable", { fg = p.bone })
hl("@variable.builtin", { fg = p.necrotic })
hl("@property", { fg = p.bone })
hl("@punctuation", { fg = p.bone_dim })

-- Diagnostics, diffs, git
hl("DiagnosticError", { fg = p.viscera })
hl("DiagnosticWarn", { fg = p.gold })
hl("DiagnosticInfo", { fg = p.corpse })
hl("DiagnosticHint", { fg = p.ash })
hl("DiagnosticOk", { fg = p.spectral })
hl("DiagnosticUnderlineError", { undercurl = true, sp = p.viscera })
hl("DiagnosticUnderlineWarn", { undercurl = true, sp = p.gold })
hl("DiffAdd", { bg = "#14301c" })
hl("DiffChange", { bg = "#1d2a36" })
hl("DiffDelete", { fg = p.viscera, bg = "#2a1414" })
hl("DiffText", { bg = "#2a4050" })
hl("Added", { fg = p.spectral })
hl("Changed", { fg = p.gold })
hl("Removed", { fg = p.viscera })
hl("GitSignsAdd", { link = "Added" })
hl("GitSignsChange", { link = "Changed" })
hl("GitSignsDelete", { link = "Removed" })
