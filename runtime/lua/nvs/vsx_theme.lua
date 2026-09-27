-- vsx_theme: turns a VS Code colour theme into the source of a Neovim colour
-- scheme. Pure: it reads files and returns text; the caller writes the text to
-- stdpath("data")/vsx/colors/<scheme_name>.lua. The contract is
-- docs/extensions.md, "Theme conversion".
--
--   local src, report = require("nvs.vsx_theme").convert(theme_path, scheme_name)
--
-- src is nil when the theme cannot be read; report.error then says why. The
-- report always has colors_mapped, tokens_mapped, unknown_scopes and warnings.
--
-- How tokens are resolved. A VS Code theme colours a TextMate scope stack, not
-- a Neovim group, so every Neovim group here is given one or more realistic
-- scope paths ("source keyword.control.conditional"). Each scope of a path is
-- matched the way vscode-textmate's Theme.match does it (src/theme.ts): the
-- rules whose last selector segment is a dot prefix of the scope form that
-- scope's trie node; a rule without parent selectors merges into the node's
-- main rule, a rule with parent selectors inherits the fields the main rule
-- had when it was added (fontStyle "" is an explicit reset, a colour that is
-- not hex is no colour); the rule that applies is the most specific one
-- (deepest segment, then longer, then more parent selectors) whose parent
-- selectors appear further out in the path, and only its fields count. The
-- path is folded outermost first, so an inner scope overrides the fields it
-- sets, as VS Code's tokenizer does. The first path with a rule matching a
-- scope past the root decides the group; when a theme mentions none of a
-- group's paths the group takes a fallback derived from the theme's
-- workbench colours or from a related group, so a sparse theme still gives
-- every group a colour that belongs to it.
--
-- Alpha. VS Code paints "#rrggbbaa" translucently. Neovim cannot, so a
-- translucent background is blended over the editor background (fully
-- transparent means no background), a faint foreground (alpha below 50%) is
-- blended too because it is meant to look faded, and a nearly opaque
-- foreground just drops its alpha.
local jsonc = require("nvs.jsonc")

local M = {}

-- Colours ----------------------------------------------------------------

-- "#rgb", "#rgba", "#rrggbb", "#rrggbbaa" -> r, g, b, a (0..255; a is nil when absent).
local function parse_hex(s)
  if type(s) ~= "string" then
    return nil
  end
  local h = s:match("^%s*#(%x+)%s*$")
  if not h then
    return nil
  end
  if #h == 3 or #h == 4 then
    h = h:gsub(".", function(ch)
      return ch .. ch
    end)
  end
  if #h ~= 6 and #h ~= 8 then
    return nil
  end
  local r, g, b = tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16)
  local a = #h == 8 and tonumber(h:sub(7, 8), 16) or nil
  return r, g, b, a
end

local function to_hex(r, g, b)
  local function clamp(x)
    return math.max(0, math.min(255, math.floor(x + 0.5)))
  end
  return string.format("#%02x%02x%02x", clamp(r), clamp(g), clamp(b))
end

-- top (opaque hex) laid over base (opaque hex) with opacity t in 0..1.
local function blend(top, base, t)
  local r1, g1, b1 = parse_hex(top)
  local r2, g2, b2 = parse_hex(base)
  return to_hex(r1 * t + r2 * (1 - t), g1 * t + g2 * (1 - t), b1 * t + b2 * (1 - t))
end

local function luminance(hex)
  local r, g, b = parse_hex(hex)
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
end

-- A theme colour string -> opaque "#rrggbb" or nil (transparent background),
-- following the alpha rules in the header. kind is "fg", "bg" or "sp".
local function resolve(value, kind, base)
  local r, g, b, a = parse_hex(value)
  if not r then
    return nil, "not a hex colour: " .. tostring(value)
  end
  local hex = to_hex(r, g, b)
  if a == nil or a == 255 then
    return hex
  end
  if kind == "bg" then
    if a == 0 then
      return nil
    end
    return blend(hex, base, a / 255)
  end
  if a < 128 then
    return blend(hex, base, a / 255)
  end
  return hex
end

-- Theme files ------------------------------------------------------------

local function dirname(p)
  return p:match("^(.*)[/\\][^/\\]*$") or "."
end

local function basename(p)
  return p:match("([^/\\]+)$") or p
end

local function join(dir, rel)
  if rel:match("^%a:[/\\]") or rel:match("^[/\\]") then
    return rel
  end
  rel = rel:gsub("^%./", "")
  return dir .. "/" .. rel
end

local function warn(warnings, msg)
  for _, w in ipairs(warnings) do
    if w == msg then
      return
    end
  end
  warnings[#warnings + 1] = msg
end

-- Reads one theme file and, first, the chain of files it includes. The
-- including file wins for colours and settings; its token rules come after
-- the included ones so that ties resolve in its favour, as in VS Code.
local function load_theme(path, warnings, seen, depth)
  seen = seen or {}
  depth = depth or 0
  -- Normalised ("a/b/../c.json" -> "a/c.json", one kind of slash) so that
  -- the cycle check and report.files see one name per file.
  path = vim.fs.normalize(path, { expand_env = false })
  local key = path:lower()
  if seen[key] then
    return nil, "include cycle at " .. path
  end
  if depth > 8 then
    return nil, "include chain deeper than 8 at " .. path
  end
  seen[key] = true
  local ok, data = jsonc.read(path)
  if not ok then
    return nil, "cannot read theme " .. path .. ": " .. tostring(data)
  end
  -- A JSON array decodes to a table too; a theme is an object.
  if type(data) ~= "table" or vim.islist(data) then
    return nil, path .. " is not a JSON object"
  end
  local theme = { colors = {}, tokenColors = {}, semanticTokenColors = {}, files = {} }
  if type(data.include) == "string" and data.include ~= "" then
    local parent, err = load_theme(join(dirname(path), data.include), warnings, seen, depth + 1)
    if parent then
      theme = parent
    else
      warn(warnings, "include skipped: " .. err)
    end
  end
  theme.files[#theme.files + 1] = path
  if data.name ~= nil then
    theme.name = data.name
  end
  if data.type ~= nil then
    theme.type = data.type
  end
  if data.semanticHighlighting ~= nil then
    theme.semanticHighlighting = data.semanticHighlighting
  end
  if type(data.colors) == "table" then
    for k, v in pairs(data.colors) do
      theme.colors[k] = v
    end
  end
  if type(data.tokenColors) == "table" then
    for _, rule in ipairs(data.tokenColors) do
      theme.tokenColors[#theme.tokenColors + 1] = rule
    end
  elseif type(data.tokenColors) == "string" then
    warn(warnings, "tokenColors points at a .tmTheme file, which is not supported: " .. data.tokenColors)
  end
  if type(data.semanticTokenColors) == "table" then
    for k, v in pairs(data.semanticTokenColors) do
      theme.semanticTokenColors[k] = v
    end
  end
  return theme
end

-- Token rules ------------------------------------------------------------

local function parse_font_style(s)
  if type(s) ~= "string" then
    return nil
  end
  local st = {}
  for word in s:gmatch("%S+") do
    if word == "bold" or word == "italic" or word == "underline" or word == "strikethrough" then
      st[word] = true
    end
  end
  -- An empty table is an explicit "no styles", which is not the same as unset.
  return st
end

local function split_ws(s)
  local out = {}
  for word in s:gmatch("%S+") do
    out[#out + 1] = word
  end
  return out
end

-- Every selector of every rule becomes one entry: the innermost selector
-- segment (leaf), its depth in dots, the parent selectors innermost first,
-- and the settings. defaults collects the scope-less entry old themes use
-- for the editor colours.
local function compile_rules(theme, warnings)
  local rules, defaults = {}, {}
  for index, entry in ipairs(theme.tokenColors) do
    if type(entry) == "table" and type(entry.settings) == "table" then
      -- As in VS Code, a colour that is not hex is no colour at all: it
      -- neither paints nor hides the colour of a less specific rule.
      local fg, bg = entry.settings.foreground, entry.settings.background
      if fg ~= nil and not parse_hex(fg) then
        warn(warnings, ("token rule %d: foreground is not a hex colour: %s"):format(index, tostring(fg)))
        fg = nil
      end
      if bg ~= nil and not parse_hex(bg) then
        warn(warnings, ("token rule %d: background is not a hex colour: %s"):format(index, tostring(bg)))
        bg = nil
      end
      local style = parse_font_style(entry.settings.fontStyle)
      local scopes = entry.scope
      if scopes == nil then
        -- The scope-less entry old themes use for the editor colours; the
        -- last one wins each field, as in VS Code.
        if fg ~= nil then
          defaults.fg = fg
        end
        if bg ~= nil then
          defaults.bg = bg
        end
      else
        if type(scopes) == "string" then
          scopes = { scopes }
        end
        if type(scopes) == "table" then
          for _, item in ipairs(scopes) do
            if type(item) == "string" then
              for selector in item:gmatch("[^,]+") do
                local segments = split_ws(selector)
                if #segments > 0 then
                  local leaf = segments[#segments]
                  local parents = {}
                  for i = #segments - 1, 1, -1 do
                    parents[#parents + 1] = segments[i]
                  end
                  local _, dots = leaf:gsub("%.", "")
                  rules[#rules + 1] = {
                    index = index,
                    selector = table.concat(segments, " "),
                    leaf = leaf,
                    depth = dots + 1,
                    parents = parents,
                    fg = fg,
                    bg = bg,
                    style = style,
                  }
                end
              end
            end
          end
        end
      end
    end
  end
  return rules, defaults
end

local function matches_scope(name, pattern)
  return pattern == name or (name:sub(1, #pattern) == pattern and name:sub(#pattern + 1, #pattern + 1) == ".")
end

-- path[1..top] are the ancestors of the scope being matched, innermost at
-- top; parents are the rule's parent selectors, innermost first. A port of
-- vscode-textmate's _scopePathMatchesParentScopes, ">" included.
local function parents_match(path, top, parents)
  if #parents == 0 then
    return true
  end
  local pos = top
  local i = 1
  while i <= #parents do
    local pattern = parents[i]
    local must = false
    if pattern == ">" then
      if i == #parents then
        return false
      end
      i = i + 1
      pattern = parents[i]
      must = true
    end
    while pos >= 1 do
      if matches_scope(path[pos], pattern) then
        break
      end
      if must then
        return false
      end
      pos = pos - 1
    end
    if pos < 1 then
      return false
    end
    pos = pos - 1
    i = i + 1
  end
  return true
end

-- vscode-textmate's strArrCmp for parent selectors: none first, then fewer,
-- then in string order. It fixes the order rules enter a node, which decides
-- ties between rules of equal specificity.
local function cmp_parents(a, b)
  if #a ~= #b then
    return #a < #b and -1 or 1
  end
  for k = 1, #a do
    if a[k] ~= b[k] then
      return a[k] < b[k] and -1 or 1
    end
  end
  return 0
end

-- The order resolveParsedThemeRules inserts rules into the trie: scope name
-- (among the dot prefixes of one scope that is depth), then parent
-- selectors, then file order.
local function insertion_order(a, b)
  if a.depth ~= b.depth then
    return a.depth < b.depth
  end
  local c = cmp_parents(a.parents, b.parents)
  if c ~= 0 then
    return c < 0
  end
  return a.index < b.index
end

-- _cmpBySpecificity as a "comes first" test: deeper leaf, then longer parent
-- selectors compared innermost first (">" does not count), then more of
-- them, then the order the rules entered the node (JavaScript's sort keeps
-- it).
local function more_specific(a, b)
  if a.depth ~= b.depth then
    return a.depth > b.depth
  end
  local ai, bi = 1, 1
  while true do
    if a.parents[ai] == ">" then
      ai = ai + 1
    end
    if b.parents[bi] == ">" then
      bi = bi + 1
    end
    if ai > #a.parents or bi > #b.parents then
      break
    end
    if #a.parents[ai] ~= #b.parents[bi] then
      return #a.parents[ai] > #b.parents[bi]
    end
    ai = ai + 1
    bi = bi + 1
  end
  if #a.parents ~= #b.parents then
    return #a.parents > #b.parents
  end
  return a.order < b.order
end

-- acceptOverwrite: the fields a rule sets replace the node rule's.
local function overwrite(node_rule, r)
  node_rule.depth = r.depth
  if r.fg ~= nil then
    node_rule.fg = r.fg
  end
  if r.bg ~= nil then
    node_rule.bg = r.bg
  end
  if r.style ~= nil then
    node_rule.style = r.style
  end
  node_rule.sources[r.index] = true
end

-- The rule VS Code applies to path[i], or nil when no rule mentions that
-- scope. The scope's trie node is rebuilt from the rules whose leaf is a dot
-- prefix of it, taken in insertion order: a rule without parents merges into
-- the main rule; a rule with parents merges into the node rule with the same
-- parents, or starts one that inherits what the main rule holds so far (a
-- child node clones its parent's rules, and shallower rules come first, so
-- this is the same thing). The most specific node rule whose parents appear
-- in the path wins outright; the untouched main rule is the root's empty one.
local function match_scope(rules, path, i, used)
  local scope = path[i]
  local cands = {}
  for _, r in ipairs(rules) do
    if matches_scope(scope, r.leaf) then
      cands[#cands + 1] = r
    end
  end
  if #cands == 0 then
    return nil
  end
  table.sort(cands, insertion_order)
  local main = { depth = 0, parents = {}, sources = {} }
  local node, by_parents = {}, {}
  for _, r in ipairs(cands) do
    if #r.parents == 0 then
      overwrite(main, r)
    else
      local key = table.concat(r.parents, " ")
      local existing = by_parents[key]
      if existing then
        overwrite(existing, r)
      else
        local rule = { depth = r.depth, parents = r.parents, fg = r.fg, bg = r.bg, style = r.style, sources = {} }
        if rule.fg == nil then
          rule.fg = main.fg
        end
        if rule.bg == nil then
          rule.bg = main.bg
        end
        if rule.style == nil then
          rule.style = main.style
        end
        for index in pairs(main.sources) do
          rule.sources[index] = true
        end
        rule.sources[r.index] = true
        by_parents[key] = rule
        node[#node + 1] = rule
      end
    end
  end
  node[#node + 1] = main
  for k, rule in ipairs(node) do
    rule.order = k
  end
  table.sort(node, more_specific)
  for _, rule in ipairs(node) do
    if parents_match(path, i - 1, rule.parents) then
      if next(rule.sources) == nil then
        return nil
      end
      for index in pairs(rule.sources) do
        used[index] = true
      end
      return rule
    end
  end
  return nil
end

-- The style VS Code would give a token with this scope path: the path is
-- folded outermost first and each scope's rule overrides the fields it sets.
-- Returns the style and whether a rule matched a scope beyond the root (the
-- root, "source" or "text.html.markdown", is only context).
local function resolve_path(rules, path, used)
  local style, hit = {}, false
  for i = 1, #path do
    local rule = match_scope(rules, path, i, used)
    if rule then
      if rule.fg ~= nil then
        style.fg = rule.fg
      end
      if rule.bg ~= nil then
        style.bg = rule.bg
      end
      if rule.style ~= nil then
        style.style = rule.style
      end
      if i > 1 or #path == 1 then
        hit = true
      end
    end
  end
  return style, hit
end

-- Building the scheme ----------------------------------------------------

-- uiTheme ("vs", "vs-dark", "hc-black", "hc-light") lives in the extension's
-- package.json, in the contributes.themes entry that names the theme file,
-- not in the theme file. When the caller passes none, the nearest
-- package.json above the theme file is asked. theme_path is normalised.
local function find_ui_theme(theme_path)
  local dir = dirname(theme_path)
  for _ = 1, 4 do
    local pkg = dir .. "/package.json"
    if vim.fn.filereadable(pkg) == 1 then
      local ok, data = jsonc.read(pkg)
      local themes = ok and type(data) == "table" and type(data.contributes) == "table" and data.contributes.themes
      if type(themes) == "table" then
        for _, t in ipairs(themes) do
          if type(t) == "table" and type(t.path) == "string" then
            local p = vim.fs.normalize(join(dir, t.path), { expand_env = false })
            if p:lower() == theme_path:lower() then
              return t.uiTheme
            end
          end
        end
      end
      -- The nearest manifest is the extension's; a higher one is not.
      return nil
    end
    local up = dirname(dir)
    if up == dir or up == "." then
      return nil
    end
    dir = up
  end
  return nil
end

local function is_light(kind)
  return kind == "light"
end

-- "light" or "dark" for the values VS Code uses in uiTheme and themes use in type;
-- nil for anything else. Case does not matter.
local KINDS = {
  light = "light", vs = "light", hclight = "light", ["hc-light"] = "light",
  dark = "dark", ["vs-dark"] = "dark", ["hc-black"] = "dark", hcdark = "dark", ["hc-dark"] = "dark",
}
local function kind_of(v)
  return type(v) == "string" and KINDS[v:lower()] or nil
end

-- VS Code decides light or dark by the uiTheme its package.json gives the theme and never
-- reads the file's own "type" (colorThemeData.ts). So: uiTheme first, then a type we
-- recognise, then the brightness of editor.background. An unrecognised type is reported.
local function make_ctx(theme, warnings, ui_theme)
  local ctx = { colors = theme.colors, warnings = warnings, used_colors = {}, used_rules = {} }
  ctx.rules, ctx.defaults = compile_rules(theme, warnings)

  local kind = kind_of(ui_theme)
  if ui_theme ~= nil and kind == nil then
    warn(warnings, "uiTheme " .. tostring(ui_theme) .. " is not one VS Code knows; ignored")
  end
  if kind == nil then
    kind = kind_of(theme.type)
    if theme.type ~= nil and kind == nil then
      warn(warnings, "the theme's type " .. tostring(theme.type) .. " is not light or dark; judging from its colours")
    end
  end
  local bg_raw = theme.colors["editor.background"] or theme.colors["editorPane.background"] or ctx.defaults.bg
  local r, g, b = parse_hex(bg_raw)
  if not r then
    if bg_raw ~= nil then
      warn(warnings, "editor.background is not a hex colour: " .. tostring(bg_raw))
    else
      warn(warnings, "the theme has no editor.background; using a plain one")
    end
    if kind == nil then
      kind = "dark"
      warn(warnings, "the theme has no type, no uiTheme in a package.json above it and no editor.background; assuming dark")
    end
    ctx.base = is_light(kind) and "#ffffff" or "#1e1e1e"
  else
    ctx.base = to_hex(r, g, b)
    ctx.used_colors["editor.background"] = true
  end
  if kind == nil then
    kind = luminance(ctx.base) > 0.5 and "light" or "dark"
    warn(warnings, "the theme has no type; judged " .. kind .. " from editor.background")
  end
  ctx.light = is_light(kind)
  ctx.background = ctx.light and "light" or "dark"
  return ctx
end

-- The first of keys that the theme defines, resolved for kind, or nil.
local function pick(ctx, kind, keys)
  for _, key in ipairs(keys) do
    local v = ctx.colors[key]
    if v ~= nil then
      local hex, err = resolve(v, kind, ctx.base)
      if err then
        warn(ctx.warnings, "colour " .. key .. ": " .. err)
      else
        ctx.used_colors[key] = true
        if hex then
          return hex
        end
      end
    end
  end
  return nil
end

-- t > 0 moves hex towards the text side (lighter on a dark theme, darker on a
-- light one); t < 0 moves it deeper into the background side.
local function shade(ctx, hex, t)
  local towards_text = t > 0
  local target = ((towards_text and not ctx.light) or (not towards_text and ctx.light)) and "#ffffff" or "#000000"
  return blend(target, hex, math.abs(t))
end

-- Derived palette: every fallback comes from theme colours when the theme has
-- them, from the editor colours otherwise, and only then from a plain colour.
local function palette(ctx)
  local function fg(...)
    return pick(ctx, "fg", { ... })
  end
  local function bg(...)
    return pick(ctx, "bg", { ... })
  end
  local d = {}
  d.bg = ctx.base
  d.fg = fg("editor.foreground", "foreground") or ctx.defaults.fg and resolve(ctx.defaults.fg, "fg", ctx.base)
  if not d.fg then
    warn(ctx.warnings, "the theme has no editor.foreground; using a plain one")
    d.fg = ctx.light and "#333333" or "#d4d4d4"
  end
  d.dim = fg("editorLineNumber.foreground", "disabledForeground", "descriptionForeground") or blend(d.fg, d.bg, 0.55)
  d.line = bg("editor.lineHighlightBackground") or shade(ctx, d.bg, 0.06)
  d.sel = bg("editor.selectionBackground", "selection.background") or shade(ctx, d.bg, 0.2)
  d.float_bg = bg("editorWidget.background", "editorHoverWidget.background", "editorSuggestWidget.background", "sideBar.background")
    or shade(ctx, d.bg, -0.15)
  d.float_fg = fg("editorWidget.foreground", "editorHoverWidget.foreground", "editorSuggestWidget.foreground") or d.fg
  d.border = fg("editorWidget.border", "editorHoverWidget.border", "editorSuggestWidget.border", "editorGroup.border", "panel.border", "focusBorder")
    or shade(ctx, d.bg, 0.25)
  d.accent = fg("focusBorder", "textLink.foreground", "editorCursor.foreground", "button.background") or d.fg
  d.link = fg("textLink.foreground", "editorLink.activeForeground") or d.accent
  d.editor_link = fg("editorLink.activeForeground") or d.link
  d.sidebar_bg = bg("sideBar.background") or d.float_bg
  d.sidebar_fg = fg("sideBar.foreground") or d.fg
  d.list_sel = bg("list.activeSelectionBackground", "list.focusBackground") or d.sel
  d.guide_active = fg("editorIndentGuide.activeBackground", "editorIndentGuide.activeBackground1") or d.accent
  d.cursor = fg("editorCursor.foreground") or d.fg
  d.cursor_fg = bg("editorCursor.background") or d.bg
  d.gutter = bg("editorGutter.background") or d.bg
  d.ws = fg("editorWhitespace.foreground") or shade(ctx, d.bg, 0.25)
  d.guide = fg("editorIndentGuide.background", "editorIndentGuide.background1", "editorWhitespace.foreground") or d.ws
  d.error = fg("editorError.foreground", "errorForeground", "terminal.ansiRed", "list.errorForeground") or (ctx.light and "#d21f1f" or "#f14c4c")
  d.warn = fg("editorWarning.foreground", "list.warningForeground", "terminal.ansiYellow") or (ctx.light and "#9a6700" or "#cca700")
  d.info = fg("editorInfo.foreground", "terminal.ansiBlue") or d.link
  d.hint = fg("editorHint.foreground") or d.dim
  d.green = fg("editorGutter.addedBackground", "gitDecoration.addedResourceForeground", "terminal.ansiGreen", "testing.iconPassed")
    or (ctx.light and "#1a7f37" or "#81b88b")
  d.yellow = fg("editorGutter.modifiedBackground", "gitDecoration.modifiedResourceForeground", "terminal.ansiYellow")
    or d.warn
  d.red = fg("editorGutter.deletedBackground", "gitDecoration.deletedResourceForeground", "terminal.ansiRed") or d.error
  d.ok = fg("testing.iconPassed", "terminal.ansiGreen") or d.green
  d.search = bg("editor.findMatchHighlightBackground", "editor.findMatchBackground") or shade(ctx, d.yellow, -0.4)
  d.cursearch = bg("editor.findMatchBackground", "editor.findMatchHighlightBackground") or d.search
  d.status_bg = bg("statusBar.background") or d.float_bg
  d.status_fg = fg("statusBar.foreground") or d.fg
  d.status_nc_bg = bg("statusBar.noFolderBackground", "statusBar.background") or d.status_bg
  d.tab_bg = bg("tab.inactiveBackground", "editorGroupHeader.tabsBackground") or d.float_bg
  d.tab_fg = fg("tab.inactiveForeground") or d.dim
  d.tab_sel_bg = bg("tab.activeBackground") or d.bg
  d.tab_sel_fg = fg("tab.activeForeground") or d.fg
  d.tab_fill = bg("editorGroupHeader.tabsBackground", "tab.inactiveBackground") or d.tab_bg
  d.pmenu_bg = bg("editorSuggestWidget.background", "editorWidget.background") or d.float_bg
  d.pmenu_fg = fg("editorSuggestWidget.foreground", "editorWidget.foreground") or d.fg
  d.pmenu_sel_bg = bg("editorSuggestWidget.selectedBackground", "list.activeSelectionBackground", "quickInputList.focusBackground")
    or shade(ctx, d.pmenu_bg, 0.12)
  d.pmenu_sel_fg = fg("editorSuggestWidget.selectedForeground", "list.activeSelectionForeground") or d.fg
  d.pmenu_match = fg("editorSuggestWidget.highlightForeground", "list.highlightForeground") or d.accent
  d.pmenu_match_sel = fg("editorSuggestWidget.focusHighlightForeground", "list.focusHighlightForeground") or d.pmenu_match
  d.pmenu_border = fg("editorSuggestWidget.border") or d.border
  d.scroll = bg("scrollbarSlider.background") or shade(ctx, d.pmenu_bg, 0.1)
  d.thumb = bg("scrollbarSlider.activeBackground", "scrollbarSlider.hoverBackground") or shade(ctx, d.pmenu_bg, 0.25)
  d.shadow = bg("widget.shadow") or "#000000"
  d.paren_bg = bg("editorBracketMatch.background")
  d.paren_border = fg("editorBracketMatch.border") or d.accent
  d.fold_bg = bg("editor.foldBackground") or d.line
  d.fold_fg = fg("editorGutter.foldingControlForeground", "editorCodeLens.foreground") or d.dim
  d.diff_add = bg("diffEditor.insertedLineBackground", "diffEditor.insertedTextBackground") or blend(d.green, d.bg, 0.15)
  d.diff_del = bg("diffEditor.removedLineBackground", "diffEditor.removedTextBackground") or blend(d.red, d.bg, 0.15)
  d.diff_change = blend(d.yellow, d.bg, 0.15)
  d.diff_text = blend(d.yellow, d.bg, 0.35)
  d.diff_text_add = bg("diffEditor.insertedTextBackground") or blend(d.green, d.bg, 0.35)
  d.code_bg = bg("textCodeBlock.background", "editorWidget.background") or d.float_bg
  d.inlay_fg = fg("editorInlayHint.foreground") or d.dim
  d.inlay_bg = bg("editorInlayHint.background")
  d.codelens = fg("editorCodeLens.foreground") or d.dim
  d.word_bg = bg("editor.wordHighlightBackground", "editor.selectionHighlightBackground") or d.sel
  d.word_strong_bg = bg("editor.wordHighlightStrongBackground") or d.word_bg
  d.breadcrumb = fg("breadcrumb.foreground") or d.fg
  return d
end

-- A style from resolve_path -> a highlight spec (colours resolved, alpha
-- handled, styles carried over), with forced attributes laid on top.
local function style_spec(ctx, style, force)
  local spec = {}
  if style.fg then
    local hex, err = resolve(style.fg, "fg", ctx.base)
    if err then
      warn(ctx.warnings, "token colour " .. err)
    end
    spec.fg = hex
  end
  if style.bg then
    local hex, err = resolve(style.bg, "bg", ctx.base)
    if err then
      warn(ctx.warnings, "token colour " .. err)
    end
    spec.bg = hex
  end
  if style.style then
    for k in pairs(style.style) do
      spec[k] = true
    end
  end
  if force then
    for k, v in pairs(force) do
      spec[k] = v
    end
  end
  return spec
end

-- Group definitions, in output order.
local function build_groups(ctx, d)
  local defs = {}
  local function add(group, spec)
    defs[#defs + 1] = { group, spec }
  end
  local function link(group, to)
    add(group, { link = to })
  end

  -- A group driven by token rules: alts are scope paths tried in order and
  -- the first one a rule matches wins; a theme that mentions none of them
  -- gets fb, which chains groups (Conditional falls back to Keyword's spec)
  -- so that derived colours stay consistent with each other.
  local function tok(group, alts, fb, force)
    local chosen
    for _, alt in ipairs(alts) do
      local style, hit = resolve_path(ctx.rules, split_ws(alt), ctx.used_rules)
      if hit then
        chosen = style
        break
      end
    end
    local spec
    if chosen then
      spec = style_spec(ctx, chosen, force)
      -- A rule that sets only a font style paints the token in the editor's
      -- default foreground, as VS Code does.
      if spec.fg == nil and spec.bg == nil then
        spec.fg = d.fg
      end
    else
      spec = {}
      for k, v in pairs(fb or { fg = d.fg }) do
        spec[k] = v
      end
      for k, v in pairs(force or {}) do
        spec[k] = v
      end
    end
    add(group, spec)
    return spec
  end

  -- Editor chrome (workbench colours)
  add("Normal", { fg = d.fg, bg = d.bg })
  add("NormalNC", { fg = d.fg, bg = d.bg })
  add("NormalFloat", { fg = d.float_fg, bg = d.float_bg })
  add("FloatBorder", { fg = d.border, bg = d.float_bg })
  add("FloatTitle", { fg = d.accent, bg = d.float_bg, bold = true })
  link("FloatFooter", "FloatTitle")
  add("FloatShadow", { bg = d.shadow, blend = 80 })
  add("FloatShadowThrough", { bg = d.shadow, blend = 100 })
  add("Cursor", { fg = d.cursor_fg, bg = d.cursor })
  link("lCursor", "Cursor")
  link("CursorIM", "Cursor")
  add("TermCursor", { fg = d.cursor_fg, bg = pick(ctx, "fg", { "terminalCursor.foreground" }) or d.cursor })
  add("CursorLine", { bg = d.line })
  link("CursorColumn", "CursorLine")
  add("CursorLineNr", { fg = pick(ctx, "fg", { "editorLineNumber.activeForeground" }) or d.accent, bold = true })
  add("LineNr", { fg = d.dim })
  link("LineNrAbove", "LineNr")
  link("LineNrBelow", "LineNr")
  add("SignColumn", { bg = d.gutter })
  link("CursorLineSign", "SignColumn")
  add("FoldColumn", { fg = d.fold_fg, bg = d.gutter })
  link("CursorLineFold", "FoldColumn")
  add("ColorColumn", { bg = d.line })
  add("WinSeparator", { fg = pick(ctx, "fg", { "editorGroup.border", "panel.border", "sideBar.border" }) or d.border })
  link("VertSplit", "WinSeparator")
  add("Visual", { bg = d.sel })
  add("VisualNOS", { bg = pick(ctx, "bg", { "editor.inactiveSelectionBackground" }) or d.sel })
  add("Search", { bg = d.search })
  add("IncSearch", { bg = d.cursearch })
  link("CurSearch", "IncSearch")
  link("Substitute", "Search")
  -- The current quickfix item is a selected list row.
  add("QuickFixLine", { bg = d.list_sel })
  add("MatchParen", { bg = d.paren_bg, underline = true, sp = d.paren_border, bold = true })
  add("NonText", { fg = d.ws })
  add("Whitespace", { fg = d.ws })
  add("SpecialKey", { fg = d.ws })
  add("Conceal", { fg = d.dim })
  add("EndOfBuffer", { fg = d.bg })
  add("Folded", { fg = d.fold_fg, bg = d.fold_bg })
  add("StatusLine", { fg = d.status_fg, bg = d.status_bg })
  add("StatusLineNC", { fg = d.dim, bg = d.status_nc_bg })
  link("StatusLineTerm", "StatusLine")
  link("StatusLineTermNC", "StatusLineNC")
  link("MsgSeparator", "StatusLine")
  add("WinBar", { fg = d.breadcrumb, bg = d.bg, bold = true })
  add("WinBarNC", { fg = d.dim, bg = d.bg })
  add("TabLine", { fg = d.tab_fg, bg = d.tab_bg })
  add("TabLineSel", { fg = d.tab_sel_fg, bg = d.tab_sel_bg, bold = true })
  add("TabLineFill", { bg = d.tab_fill })
  add("Pmenu", { fg = d.pmenu_fg, bg = d.pmenu_bg })
  add("PmenuSel", { fg = d.pmenu_sel_fg, bg = d.pmenu_sel_bg, bold = true })
  add("PmenuKind", { fg = d.dim, bg = d.pmenu_bg })
  add("PmenuKindSel", { fg = d.dim, bg = d.pmenu_sel_bg })
  add("PmenuExtra", { fg = d.dim, bg = d.pmenu_bg })
  add("PmenuExtraSel", { fg = d.dim, bg = d.pmenu_sel_bg })
  add("PmenuMatch", { fg = d.pmenu_match, bg = d.pmenu_bg, bold = true })
  add("PmenuMatchSel", { fg = d.pmenu_match_sel, bg = d.pmenu_sel_bg, bold = true })
  add("PmenuSbar", { bg = d.scroll })
  add("PmenuThumb", { bg = d.thumb })
  add("PmenuBorder", { fg = d.pmenu_border, bg = d.pmenu_bg })
  link("WildMenu", "PmenuSel")
  add("Directory", { fg = pick(ctx, "fg", { "symbolIcon.folderForeground", "textLink.foreground" }) or d.link })
  add("Question", { fg = d.ok })
  add("MoreMsg", { fg = d.ok })
  add("OkMsg", { fg = d.ok })
  add("ModeMsg", { fg = d.ok, bold = true })
  add("ErrorMsg", { fg = d.error, bold = true })
  add("WarningMsg", { fg = d.warn })
  -- Sidebar windows: NormalSB/SignColumnSB is the convention colour schemes
  -- (tokyonight among them) use for explorer-like windows; snacks draws the
  -- indent guides LazyVim shows.
  add("NormalSB", { fg = d.sidebar_fg, bg = d.sidebar_bg })
  add("SignColumnSB", { bg = d.sidebar_bg })
  add("SnacksIndent", { fg = d.guide })
  add("SnacksIndentScope", { fg = d.guide_active })
  add("LspInlayHint", { fg = d.inlay_fg, bg = d.inlay_bg })
  add("LspCodeLens", { fg = d.codelens })
  add("LspReferenceText", { bg = d.word_bg })
  add("LspReferenceRead", { bg = d.word_bg })
  add("LspReferenceWrite", { bg = d.word_strong_bg })
  link("LspReferenceTarget", "LspReferenceText")
  link("SnippetTabstop", "Visual")

  -- Syntax and tree-sitter (token rules)
  local comment = tok("Comment", { "source comment.line", "source comment.block", "source comment" }, { fg = d.dim })
  add("@comment", comment)
  tok("SpecialComment", { "source comment.block.documentation", "source comment" }, { fg = d.dim })
  tok("@comment.documentation", { "source comment.block.documentation", "source comment" }, { fg = d.dim })
  add("@comment.error", { fg = d.bg, bg = d.error, bold = true })
  add("@comment.warning", { fg = d.bg, bg = d.warn, bold = true })
  add("@comment.note", { fg = d.bg, bg = d.info, bold = true })
  add("Todo", { fg = d.bg, bg = d.warn, bold = true })
  link("@comment.todo", "Todo")

  local keyword = tok("Keyword", { "source keyword", "source keyword.control", "source keyword.other", "source storage.type" }, { fg = d.accent })
  add("@keyword", keyword)
  add("Statement", keyword)
  tok("Conditional", { "source keyword.control.conditional", "source keyword.control", "source keyword" }, keyword)
  tok("@keyword.conditional", { "source keyword.control.conditional", "source keyword.control", "source keyword" }, keyword)
  tok("@keyword.conditional.ternary", { "source keyword.operator.ternary", "source keyword.operator", "source keyword" }, keyword)
  tok("Repeat", { "source keyword.control.loop", "source keyword.control.repeat", "source keyword.control", "source keyword" }, keyword)
  tok("@keyword.repeat", { "source keyword.control.loop", "source keyword.control.repeat", "source keyword.control", "source keyword" }, keyword)
  tok("@keyword.return", { "source keyword.control.flow.return", "source keyword.control.return", "source keyword.control.flow", "source keyword.control", "source keyword" }, keyword)
  tok("Include", { "source keyword.control.import", "source keyword.control.export", "source keyword.control", "source keyword" }, keyword)
  tok("@keyword.import", { "source keyword.control.import", "source keyword.control.export", "source keyword.control", "source keyword" }, keyword)
  tok("Exception", { "source keyword.control.exception", "source keyword.control.trycatch", "source keyword.control", "source keyword" }, keyword)
  tok("@keyword.exception", { "source keyword.control.exception", "source keyword.control.trycatch", "source keyword.control", "source keyword" }, keyword)
  tok("@keyword.coroutine", { "source keyword.control.flow.async", "source keyword.control.flow", "source keyword.control", "source keyword" }, keyword)
  tok("@keyword.debug", { "source keyword.control.debugger", "source keyword.control", "source keyword" }, keyword)
  tok("@keyword.function", { "source storage.type.function", "source keyword.declaration.function", "source keyword.other.fn", "source storage.type", "source keyword" }, keyword)
  tok("@keyword.operator", { "source keyword.operator.word", "source keyword.operator.logical", "source keyword.operator", "source keyword" }, keyword)
  tok("Operator", { "source keyword.operator", "source punctuation.separator.operator" }, { fg = d.fg })
  tok("@operator", { "source keyword.operator", "source punctuation.separator.operator" }, { fg = d.fg })
  local storage = tok("StorageClass", { "source storage.modifier", "source storage.type", "source keyword" }, keyword)
  tok("@keyword.modifier", { "source storage.modifier", "source storage.type", "source keyword" }, storage)
  tok("@keyword.type", { "source storage.type.class", "source storage.type.struct", "source storage.type.enum", "source storage.type", "source keyword" }, storage)
  tok("Structure", { "source storage.type.struct", "source storage.type.class", "source storage.type", "source keyword" }, storage)
  tok("Typedef", { "source storage.type.type", "source storage.type", "source keyword" }, storage)
  local preproc = tok("PreProc", { "source keyword.control.directive", "source meta.preprocessor keyword.control.directive", "source meta.preprocessor", "source keyword.other.directive", "source keyword.control", "source keyword" }, keyword)
  add("@keyword.directive", preproc)
  add("@keyword.directive.define", preproc)
  add("Define", preproc)
  add("Macro", preproc)
  add("PreCondit", preproc)
  tok("Label", { "source entity.name.label", "source entity.name.section", "source keyword.control" }, keyword)
  tok("@label", { "source entity.name.label", "source entity.name.section", "source keyword.control" }, keyword)

  local str = tok("String", { "source string.quoted.double", "source string.quoted", "source string" }, { fg = d.green })
  add("@string", str)
  tok("Character", { "source string.quoted.single", "source constant.character", "source string" }, str)
  tok("@character", { "source string.quoted.single", "source constant.character", "source string" }, str)
  local escape = tok("SpecialChar", { "source constant.character.escape", "source string.escape", "source constant.character", "source string" }, str)
  add("@string.escape", escape)
  add("@character.special", escape)
  tok("@string.regexp", { "source string.regexp", "source string" }, str)
  tok("@string.special", { "source string.other", "source constant.other.symbol", "source string" }, str)
  tok("@string.special.symbol", { "source constant.other.symbol", "source string.other.symbol", "source string" }, str)
  tok("@string.special.path", { "source string.unquoted.path", "source string.other.path", "source string" }, str)
  tok("@string.special.url", { "text.html.markdown markup.underline.link", "source string.other.link", "source markup.underline.link" }, { fg = d.editor_link }, { underline = true })
  tok("@string.documentation", { "source string.quoted.docstring", "source comment.block.documentation", "source string" }, str)

  local number = tok("Number", { "source constant.numeric.integer", "source constant.numeric", "source constant" }, { fg = d.yellow })
  add("@number", number)
  tok("Float", { "source constant.numeric.float", "source constant.numeric", "source constant" }, number)
  tok("@number.float", { "source constant.numeric.float", "source constant.numeric", "source constant" }, number)
  tok("Boolean", { "source constant.language.boolean", "source constant.language", "source constant" }, number)
  tok("@boolean", { "source constant.language.boolean", "source constant.language", "source constant" }, number)
  local const = tok("Constant", { "source variable.other.constant", "source constant.other", "source constant" }, number)
  add("@constant", const)
  tok("@constant.builtin", { "source constant.language", "source support.constant", "source constant" }, const)
  tok("@constant.macro", { "source entity.name.function.preprocessor", "source constant.other.macro", "source constant.other", "source constant" }, const)

  local func = tok("Function", { "source entity.name.function", "source support.function", "source variable.function" }, { fg = d.link })
  add("@function", func)
  tok("@function.call", { "source meta.function-call entity.name.function", "source entity.name.function", "source support.function" }, func)
  tok("@function.builtin", { "source support.function.builtin", "source support.function", "source entity.name.function" }, func)
  tok("@function.method", { "source entity.name.function.member", "source entity.name.function.method", "source entity.name.function" }, func)
  tok("@function.method.call", { "source meta.function-call entity.name.function.member", "source entity.name.function.member", "source entity.name.function" }, func)
  tok("@function.macro", { "source entity.name.function.macro", "source entity.name.function.preprocessor", "source support.function.macro", "source entity.name.function" }, func)
  tok("@constructor", { "source meta.function-call.constructor", "source entity.name.function.constructor", "source entity.name.class", "source entity.name.type", "source entity.name.function" }, func)

  local typ = tok("Type", { "source entity.name.type", "source entity.name.class", "source support.type", "source support.class", "source storage.type" }, { fg = d.yellow })
  add("@type", typ)
  tok("@type.builtin", { "source support.type.primitive", "source support.type.builtin", "source storage.type.primitive", "source support.type", "source entity.name.type" }, typ)
  tok("@type.definition", { "source entity.name.type.alias", "source entity.name.type", "source entity.name.class" }, typ)
  tok("@module", { "source entity.name.namespace", "source entity.name.type.namespace", "source entity.name.type.module", "source entity.name.module", "source support.module", "source entity.name.type" }, typ)
  tok("@module.builtin", { "source support.module", "source support.other.namespace", "source entity.name.namespace", "source entity.name.type" }, typ)
  local attr = tok("@attribute", { "source meta.decorator", "source entity.name.function.decorator", "source storage.type.annotation", "source punctuation.decorator", "source meta.annotation", "source entity.name.function" }, preproc)
  add("@attribute.builtin", attr)

  local ident = tok("Identifier", { "source variable.other.readwrite", "source variable.other", "source variable" }, { fg = d.fg })
  add("@variable", ident)
  tok("@variable.builtin", { "source variable.language.this", "source variable.language", "source support.variable", "source variable" }, keyword)
  local param = tok("@variable.parameter", { "source variable.parameter", "source meta.function.parameters variable", "source variable" }, ident)
  tok("@variable.parameter.builtin", { "source variable.parameter.function.language", "source variable.language", "source variable.parameter" }, param)
  tok("@variable.member", { "source variable.other.property", "source variable.other.member", "source variable.other.object.property", "source support.type.property-name", "source variable.other" }, ident)
  tok("@property", { "source.json support.type.property-name.json", "source.yaml entity.name.tag.yaml", "source.css support.type.property-name.css", "source support.type.property-name", "source variable.other.property", "source variable.other.member" }, ident)

  local tag = tok("Tag", { "text.html.basic entity.name.tag", "source entity.name.tag" }, { fg = d.link })
  add("@tag", tag)
  tok("@tag.builtin", { "text.html.basic entity.name.tag.html", "text.html.basic entity.name.tag", "source entity.name.tag" }, tag)
  tok("@tag.attribute", { "text.html.basic entity.other.attribute-name", "source entity.other.attribute-name" }, { fg = d.yellow })
  local punct = tok("Delimiter", { "source punctuation.separator", "source punctuation.terminator", "source punctuation" }, { fg = d.fg })
  add("@punctuation", punct)
  add("@punctuation.delimiter", punct)
  tok("@punctuation.bracket", { "source punctuation.section.brackets", "source punctuation.section", "source punctuation.definition.brackets", "source punctuation" }, punct)
  tok("@punctuation.special", { "source punctuation.section.embedded", "source punctuation.definition.template-expression", "source punctuation.definition.interpolation", "source punctuation" }, punct)
  tok("@tag.delimiter", { "text.html.basic punctuation.definition.tag", "source punctuation.definition.tag", "source punctuation" }, punct)
  tok("Special", { "source constant.character.escape", "source support.function", "source keyword.operator" }, escape)
  link("Debug", "Special")
  tok("Underlined", { "text.html.markdown markup.underline.link", "source markup.underline" }, { fg = d.editor_link }, { underline = true })
  tok("Error", { "source invalid.illegal", "source invalid" }, { fg = d.error, bold = true })
  link("Ignore", "Normal")

  -- Markup (markdown paths follow VS Code's markdown grammar)
  local md = "text.html.markdown"
  local h1 = tok("@markup.heading.1.markdown", {
    md .. " markup.heading.markdown heading.1.markdown entity.name.section.markdown",
    md .. " markup.heading.setext.1.markdown",
    md .. " markup.heading.markdown",
    md .. " markup.heading",
  }, { fg = d.accent }, { bold = true })
  local heading = tok("Title", {
    md .. " markup.heading.markdown",
    md .. " markup.heading",
    md .. " markup.heading.markdown heading.1.markdown entity.name.section.markdown",
  }, { fg = h1.fg }, { bold = true })
  add("@markup.heading", heading)
  add("@markup.heading.1", h1)
  for level = 2, 6 do
    local spec = tok("@markup.heading." .. level .. ".markdown", {
      md .. " markup.heading.markdown heading." .. level .. ".markdown entity.name.section.markdown",
      md .. " markup.heading.setext." .. level .. ".markdown",
      md .. " markup.heading.markdown",
      md .. " markup.heading",
    }, { fg = heading.fg }, { bold = true })
    add("@markup.heading." .. level, spec)
  end
  tok("@markup.strong", { md .. " markup.bold", "source markup.bold" }, { fg = d.fg }, { bold = true })
  tok("@markup.italic", { md .. " markup.italic", "source markup.italic" }, { fg = d.fg }, { italic = true })
  tok("@markup.strikethrough", { md .. " markup.strikethrough", "source markup.strikethrough" }, { fg = d.dim }, { strikethrough = true })
  tok("@markup.underline", { md .. " markup.underline", "source markup.underline" }, { fg = d.fg }, { underline = true })
  local raw = tok("@markup.raw", { md .. " markup.inline.raw.string.markdown", md .. " markup.inline.raw", md .. " markup.raw" }, str)
  tok("@markup.raw.block", { md .. " markup.raw.block.markdown", md .. " markup.raw.block", md .. " markup.raw" }, raw)
  local mlink = tok("@markup.link", { md .. " markup.link", md .. " string.other.link.title.markdown", md .. " markup.underline.link" }, { fg = d.link })
  tok("@markup.link.label", { md .. " string.other.link.title.markdown", md .. " string.other.link.description.markdown", md .. " markup.link" }, mlink)
  tok("@markup.link.url", { md .. " markup.underline.link", md .. " markup.link" }, { fg = d.link }, { underline = true })
  local list = tok("@markup.list", {
    md .. " markup.list.unnumbered.markdown punctuation.definition.list.begin.markdown",
    md .. " punctuation.definition.list.begin.markdown",
    md .. " markup.list.bullet",
    md .. " markup.list",
  }, { fg = d.accent })
  add("@markup.list.checked", { fg = d.green })
  add("@markup.list.unchecked", { fg = d.dim })
  tok("@markup.quote", { md .. " markup.quote", "source markup.quote" }, { fg = d.dim, italic = true })
  tok("@markup.math", { "text.tex markup.math", md .. " markup.math", "source markup.math" }, { fg = d.fg })

  -- Diffs and git
  add("DiffAdd", { bg = d.diff_add })
  add("DiffChange", { bg = d.diff_change })
  add("DiffDelete", { fg = d.red, bg = d.diff_del })
  add("DiffText", { bg = d.diff_text })
  add("DiffTextAdd", { bg = d.diff_text_add })
  local added = tok("Added", { "source.diff markup.inserted.diff", "source.diff markup.inserted", "source markup.inserted" }, { fg = d.green })
  local changed = tok("Changed", { "source.diff markup.changed.diff", "source.diff markup.changed", "source markup.changed" }, { fg = d.yellow })
  local removed = tok("Removed", { "source.diff markup.deleted.diff", "source.diff markup.deleted", "source markup.deleted" }, { fg = d.red })
  add("@diff.plus", added)
  add("@diff.delta", changed)
  add("@diff.minus", removed)
  tok("diffFile", { "source.diff meta.diff.header.from-file", "source.diff meta.diff.header", "source meta.diff.header" }, { fg = d.link })
  tok("diffOldFile", { "source.diff meta.diff.header.from-file", "source.diff meta.diff.header" }, { fg = d.link })
  tok("diffNewFile", { "source.diff meta.diff.header.to-file", "source.diff meta.diff.header" }, { fg = d.link })
  tok("diffLine", { "source.diff meta.diff.range", "source.diff meta.diff.header" }, { fg = d.dim })
  link("GitSignsAdd", "Added")
  link("GitSignsChange", "Changed")
  link("GitSignsDelete", "Removed")
  link("GrugFarResultsAddIndicator", "Added")
  link("GrugFarResultsChangeIndicator", "Changed")
  link("GrugFarResultsRemoveIndicator", "Removed")

  -- Diagnostics and spell
  add("DiagnosticError", { fg = d.error })
  add("DiagnosticWarn", { fg = d.warn })
  add("DiagnosticInfo", { fg = d.info })
  add("DiagnosticHint", { fg = d.hint })
  add("DiagnosticOk", { fg = d.ok })
  add("DiagnosticUnderlineError", { undercurl = true, sp = d.error })
  add("DiagnosticUnderlineWarn", { undercurl = true, sp = d.warn })
  add("DiagnosticUnderlineInfo", { undercurl = true, sp = d.info })
  add("DiagnosticUnderlineHint", { undercurl = true, sp = d.hint })
  add("DiagnosticUnderlineOk", { undercurl = true, sp = d.ok })
  add("DiagnosticDeprecated", { strikethrough = true, sp = d.warn })
  add("DiagnosticUnnecessary", { fg = d.dim })
  add("SpellBad", { undercurl = true, sp = d.error })
  add("SpellCap", { undercurl = true, sp = d.warn })
  add("SpellLocal", { undercurl = true, sp = d.info })
  add("SpellRare", { undercurl = true, sp = d.accent })

  -- render-markdown.nvim
  -- Each heading band is that heading's colour laid faintly over the editor background.
  for level = 1, 6 do
    local fg
    for _, def in ipairs(defs) do
      if def[1] == "@markup.heading." .. level .. ".markdown" then
        fg = def[2].fg
      end
    end
    add("RenderMarkdownH" .. level .. "Bg", { bg = blend(fg or heading.fg or d.accent, d.bg, 0.15) })
  end
  add("RenderMarkdownCode", { bg = d.code_bg })
  add("RenderMarkdownCodeInline", { fg = raw.fg or str.fg, bg = d.code_bg })
  add("RenderMarkdownBullet", { fg = list.fg or d.accent })
  add("RenderMarkdownTableHead", { fg = d.guide })
  add("RenderMarkdownTableRow", { fg = d.guide })
  add("RenderMarkdownChecked", { fg = d.green })
  add("RenderMarkdownUnchecked", { fg = d.dim })

  return defs
end

-- semanticTokenColors: "type.mod:lang" selectors -> @lsp.* groups.
local LANG_TO_FT = {
  shellscript = "sh",
  csharp = "cs",
  ["objective-c"] = "objc",
  ["objective-cpp"] = "objcpp",
  plaintext = "text",
  makefile = "make",
  perl6 = "raku",
  powershell = "ps1",
  bat = "dosbatch",
  coffeescript = "coffee",
  ["git-commit"] = "gitcommit",
  ["git-rebase"] = "gitrebase",
  jade = "pug",
  latex = "tex",
  ["c++"] = "cpp",
}

local function semantic_spec(ctx, value)
  local spec = {}
  if type(value) == "string" then
    value = { foreground = value }
  end
  if type(value) ~= "table" then
    return nil
  end
  if value.foreground then
    local hex, err = resolve(value.foreground, "fg", ctx.base)
    if err then
      warn(ctx.warnings, "semantic colour " .. err)
    end
    spec.fg = hex
  end
  if value.background then
    local hex = resolve(value.background, "bg", ctx.base)
    spec.bg = hex
  end
  local style = parse_font_style(value.fontStyle)
  if style then
    for k in pairs(style) do
      spec[k] = true
    end
  end
  for _, k in ipairs({ "bold", "italic", "underline", "strikethrough" }) do
    if value[k] == true then
      spec[k] = true
    end
  end
  return spec
end

local function semantic_groups(theme, ctx)
  local out = {}
  local keys = {}
  for k in pairs(theme.semanticTokenColors) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for _, sel in ipairs(keys) do
    local body, lang = sel:match("^([^:]+):(.+)$")
    body = body or sel
    local parts = {}
    for part in body:gmatch("[^%.]+") do
      parts[#parts + 1] = part
    end
    local typ = parts[1]
    local mods = { unpack(parts, 2) }
    local group
    if not typ or not (typ == "*" or typ:match("^[%w_]+$")) then
      warn(ctx.warnings, "semantic selector not understood: " .. sel)
    elseif #mods > 1 then
      warn(ctx.warnings, "semantic selector " .. sel .. " skipped: Neovim has no group for two modifiers")
    elseif typ == "*" then
      if #mods == 1 then
        group = "@lsp.mod." .. mods[1]
      else
        warn(ctx.warnings, "semantic selector * skipped: it would recolour every token")
      end
    elseif #mods == 0 then
      group = "@lsp.type." .. typ
    else
      group = "@lsp.typemod." .. typ .. "." .. mods[1]
    end
    if group then
      if lang then
        group = group .. "." .. (LANG_TO_FT[lang] or lang)
      end
      local spec = semantic_spec(ctx, theme.semanticTokenColors[sel])
      if spec then
        out[#out + 1] = { group, spec }
      end
    end
  end
  return out
end

-- Output ---------------------------------------------------------------

local SPEC_ORDER = { "fg", "bg", "sp", "bold", "italic", "underline", "undercurl", "strikethrough", "blend", "link" }

local function spec_source(spec)
  local parts = {}
  for _, k in ipairs(SPEC_ORDER) do
    local v = spec[k]
    if v ~= nil then
      if type(v) == "string" then
        parts[#parts + 1] = k .. " = " .. string.format("%q", v)
      else
        parts[#parts + 1] = k .. " = " .. tostring(v)
      end
    end
  end
  if #parts == 0 then
    return "{}"
  end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

local TERMINAL = {
  "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
  "BrightBlack", "BrightRed", "BrightGreen", "BrightYellow", "BrightBlue", "BrightMagenta", "BrightCyan", "BrightWhite",
}

-- The scheme name for a theme label is nvs.vsx's scheme_name (it names the
-- file); this module takes the name it is given.

-- The merged theme (include chain applied) as a table, or nil, err.
function M.load(theme_path)
  local warnings = {}
  local theme, err = load_theme(theme_path, warnings)
  if not theme then
    return nil, err
  end
  theme.warnings = warnings
  return theme
end

-- opts (optional): { ui_theme = "vs-dark" } from the extension's package.json,
-- used for 'background' when the theme file has no "type". Left out, the
-- package.json above the theme file is read for it (report.ui_theme says
-- what was found).
function M.convert(theme_path, scheme_name, opts)
  opts = opts or {}
  local report = { colors_mapped = 0, tokens_mapped = 0, unknown_scopes = {}, warnings = {} }
  if type(theme_path) ~= "string" or theme_path == "" then
    report.error = "no theme path"
    report.warnings[1] = report.error
    return nil, report
  end
  if type(scheme_name) ~= "string" or not scheme_name:match("^[^/\\%s]+$") then
    report.error = "scheme name must be one word without path separators: " .. tostring(scheme_name)
    report.warnings[1] = report.error
    return nil, report
  end
  local theme, err = load_theme(theme_path, report.warnings)
  if not theme then
    report.error = err
    warn(report.warnings, err)
    return nil, report
  end
  local ui_theme = opts.ui_theme
  if ui_theme == nil then
    ui_theme = find_ui_theme(theme.files[#theme.files])
  end
  report.ui_theme = ui_theme
  local ctx = make_ctx(theme, report.warnings, ui_theme)
  local d = palette(ctx)
  local defs = build_groups(ctx, d)
  local semantic = semantic_groups(theme, ctx)

  local terminal = {}
  for i, name in ipairs(TERMINAL) do
    local hex = pick(ctx, "fg", { "terminal.ansi" .. name })
    if hex then
      terminal[#terminal + 1] = { i - 1, hex }
    end
  end
  if #terminal < 16 then
    warn(report.warnings, ("only %d of 16 terminal.ansi* colours are defined; the rest stay Neovim's"):format(#terminal))
  end

  local out = {}
  local function line(s)
    out[#out + 1] = s
  end
  line(("-- %s: a Neovim colour scheme converted by nvs.ide from the VS Code theme %s (%s)."):format(
    scheme_name, string.format("%q", tostring(theme.name or scheme_name)), basename(theme_path)))
  line("-- Generated: it is rewritten when the extension is reinstalled, so edit the theme, not this file.")
  line('vim.cmd("hi clear")')
  line('if vim.fn.exists("syntax_on") == 1 then')
  line('  vim.cmd("syntax reset")')
  line("end")
  line(("vim.o.background = %q"):format(ctx.background))
  line(("vim.g.colors_name = %q"):format(scheme_name))
  line("")
  line("local function hl(group, spec)")
  line("  vim.api.nvim_set_hl(0, group, spec)")
  line("end")
  line("")
  for _, def in ipairs(defs) do
    line(("hl(%q, %s)"):format(def[1], spec_source(def[2])))
  end
  if #semantic > 0 then
    line("")
    line("-- semanticTokenColors")
    for _, def in ipairs(semantic) do
      line(("hl(%q, %s)"):format(def[1], spec_source(def[2])))
    end
  end
  if #terminal > 0 then
    line("")
    line("-- terminal.ansi*")
    for _, t in ipairs(terminal) do
      line(("vim.g.terminal_color_%d = %q"):format(t[1], t[2]))
    end
  end
  line("")

  -- Report
  local n = 0
  for _ in pairs(ctx.used_colors) do
    n = n + 1
  end
  report.colors_mapped = n
  local used_index = {}
  for index in pairs(ctx.used_rules) do
    used_index[#used_index + 1] = index
  end
  report.tokens_mapped = #used_index
  local seen = {}
  for _, r in ipairs(ctx.rules) do
    if not ctx.used_rules[r.index] and not seen[r.selector] then
      seen[r.selector] = true
      report.unknown_scopes[#report.unknown_scopes + 1] = r.selector
    end
  end
  table.sort(report.unknown_scopes)
  report.token_rules = #theme.tokenColors
  report.colors_total = vim.tbl_count(theme.colors)
  report.groups = #defs + #semantic
  report.semantic_mapped = #semantic
  report.name = theme.name
  report.background = ctx.background
  report.files = theme.files
  return table.concat(out, "\n"), report
end

return M
