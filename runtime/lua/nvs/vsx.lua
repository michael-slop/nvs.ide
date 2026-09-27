-- vsx.lua: VS Code extensions from Open VSX, the registry client and installer.
--
-- The contract is docs/extensions.md. Every extension lands in a tier at install time:
--   t1   declarative (themes, snippets, language ids): converted, nothing runs afterwards
--   lsp  ships a language server: Neovim's own LSP client runs `node <server> --stdio`
--   t2   code against the vscode API: runs in the extension host (runtime/exthost/host.js)
--   t3   webviews, tree views, notebooks: not supported, listed with the reason
--
-- Nothing here blocks the editor: curl, the unzip tool and the hashing tool run through vim.system
-- with callbacks, and every callback is rescheduled onto the main loop before it touches
-- Neovim. State lives in stdpath("data")/vsx/:
--   vsx.json                 the installed registry (M.list())
--   extensions/<ns>.<name>/  the unpacked vsix `extension/` folder, as shipped
--   colors/<scheme>.lua      converted themes; the vsx folder is on 'runtimepath'
--   logs/<ns>.<name>.log     the extension host's log for that extension
--   downloads/               .vsix files and unpack staging while installing
--
-- The bridge (bridge.lua) calls list, status, search, install, uninstall, set_enabled and
-- sets on_progress; prefs.lua calls apply_host_mode when the exthost setting changes;
-- nvs.setup() calls setup(). classify(pkg, files, main_text) is pure so tests can run
-- it on fixtures; install_file(vsix, cb, opts) is the offline half of install.
local jsonc = require("nvs.jsonc")

local M = {}
local uv = vim.uv or vim.loop
local is_win = vim.fn.has("win32") == 1
local TITLE = "nvs.ide · extensions"

-- Set by bridge.lua: on_progress(id, stage, message) for the stages download, verify,
-- unpack, convert, done and error.
M.on_progress = nil

---------------------------------------------------------------------------
-- Tables
---------------------------------------------------------------------------

-- Bundled servers we recognise by file name. `file` matches the base name (lower-cased),
-- `match` is a Lua pattern over it, `id` restricts a rule to one extension. `lspconfig`
-- is the nvim-lspconfig name whose settings, filetypes and root detection are reused when
-- that config exists in the running Neovim. `native` marks a binary run as is (no node).
M.KNOWN_SERVERS = {
  { file = "eslintserver.js", lspconfig = "eslint" },
  { file = "languageserver.js", id = "redhat.vscode-yaml", lspconfig = "yamlls" },
  { file = "jsonservermain.js", lspconfig = "jsonls" },
  { file = "htmlservermain.js", lspconfig = "html" },
  { file = "cssservermain.js", lspconfig = "cssls" },
  { match = "^pyright%-langserver", lspconfig = "pyright" },
  { file = "server.bundle.js", id = "ms-pyright.pyright", lspconfig = "pyright" },
  { file = "tailwindserver.js", lspconfig = "tailwindcss" },
  { match = "^astro%-ls", lspconfig = "astro" },
  { match = "^svelte%-language%-server", lspconfig = "svelte" },
  { match = "^lua%-language%-server", lspconfig = "lua_ls", native = true },
}

-- What to use when nvim-lspconfig is not installed at all. Only filetypes and root
-- markers; nvim-lspconfig's own lsp/<name>.lua is preferred whenever it is present.
local FALLBACK_LSP = {
  eslint = { filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact", "vue", "svelte", "astro" }, root_markers = { "package.json", ".git" } },
  yamlls = { filetypes = { "yaml", "yaml.docker-compose", "yaml.gitlab", "yaml.helm-values" }, root_markers = { ".git" } },
  jsonls = { filetypes = { "json", "jsonc" }, root_markers = { ".git" } },
  html = { filetypes = { "html", "templ" }, root_markers = { "package.json", ".git" } },
  cssls = { filetypes = { "css", "scss", "less" }, root_markers = { "package.json", ".git" } },
  pyright = { filetypes = { "python" }, root_markers = { "pyproject.toml", "setup.py", "requirements.txt", ".git" } },
  tailwindcss = { filetypes = { "html", "css", "scss", "javascriptreact", "typescriptreact", "vue", "svelte", "astro" }, root_markers = { "tailwind.config.js", "tailwind.config.ts", "package.json", ".git" } },
  astro = { filetypes = { "astro" }, root_markers = { "package.json", ".git" } },
  svelte = { filetypes = { "svelte" }, root_markers = { "package.json", ".git" } },
  lua_ls = { filetypes = { "lua" }, root_markers = { ".luarc.json", ".git" } },
}

-- VS Code language ids that are not the Neovim filetype of the same name.
M.LANGUAGE_IDS = {
  shellscript = "sh",
  plaintext = "text",
  csharp = "cs",
  ["objective-c"] = "objc",
  ["objective-cpp"] = "objcpp",
  dockercompose = "yaml.docker-compose",
  ["github-actions-workflow"] = "yaml",
  makefile = "make",
  bat = "dosbatch",
  powershell = "ps1",
  ["git-commit"] = "gitcommit",
  ["git-rebase"] = "gitrebase",
  ignore = "gitignore",
  properties = "jproperties",
  jade = "pug",
  coffeescript = "coffee",
  latex = "tex",
  bibtex = "bib",
  perl6 = "raku",
  ini = "dosini",
  restructuredtext = "rst",
  xsl = "xslt",
  ["vue-html"] = "html",
  ["cuda-cpp"] = "cuda",
  jsonl = "json",
}

-- Extension id (lower-cased) -> the Neovim-native way to get the same thing.
M.ALTERNATIVES = {
  ["esbenp.prettier-vscode"] = "stevearc/conform.nvim (installed; Space c f formats, LazyVim's formatting.prettier extra adds prettier)",
  ["dbaeumer.vscode-eslint"] = "mfussenegger/nvim-lint (installed) or LazyVim's linting.eslint extra",
  ["eamodio.gitlens"] = "lewis6991/gitsigns.nvim (installed)",
  ["usernamehw.errorlens"] = "folke/trouble.nvim (installed)",
  ["christian-kohler.path-intellisense"] = "blink.cmp's path source (installed)",
  ["christian-kohler.npm-intellisense"] = "blink.cmp with LazyVim's lang.json extra",
  ["vscodevim.vim"] = "not needed: this is Neovim (Stage 4 is the real thing)",
  ["asvetliakov.vscode-neovim"] = "not needed: this is Neovim",
  ["github.copilot"] = "local AI ghost text (Settings > Local AI)",
  ["github.copilot-chat"] = "Ask (Space ?) with a local model",
  ["editorconfig.editorconfig"] = "built into Neovim (.editorconfig is read by default)",
  ["streetsidesoftware.code-spell-checker"] = "Neovim's spell checking (Settings > Editor > Spell checking)",
  ["formulahendry.auto-rename-tag"] = "windwp/nvim-ts-autotag (installed)",
  ["formulahendry.auto-close-tag"] = "windwp/nvim-ts-autotag (installed)",
  ["coenraads.bracket-pair-colorizer-2"] = "HiPhish/rainbow-delimiters.nvim",
  ["aaron-bond.better-comments"] = "folke/todo-comments.nvim (installed)",
  ["gruntfuggly.todo-tree"] = "folke/todo-comments.nvim (installed)",
  ["wayou.vscode-todo-highlight"] = "folke/todo-comments.nvim (installed)",
  ["alefragnani.bookmarks"] = "ThePrimeagen/harpoon (installed through LazyVim's editor.harpoon2 extra)",
  ["mhutchie.git-graph"] = "lazygit in the terminal (Space g g)",
  ["donjayamanne.githistory"] = "gitsigns.nvim and snacks' git_log picker (installed)",
  ["shardulm94.trailing-spaces"] = "Settings > Files > Trim trailing whitespace on save",
  ["oderwat.indent-rainbow"] = "snacks.nvim indent guides (installed)",
  ["pkief.material-icon-theme"] = "mini.icons (installed)",
  ["vscode-icons-team.vscode-icons"] = "mini.icons (installed)",
  ["yzhang.markdown-all-in-one"] = "render-markdown.nvim (installed) and Space c p for a preview",
  ["shd101wyy.markdown-preview-enhanced"] = "markdown-preview.nvim (installed; Space c p)",
  ["davidanson.vscode-markdownlint"] = "nvim-lint with markdownlint",
  ["naumovs.color-highlight"] = "brenoprata10/nvim-highlight-colors",
  ["humao.rest-client"] = "mistweaverco/kulala.nvim",
  ["rangav.vscode-thunder-client"] = "mistweaverco/kulala.nvim",
  ["ms-toolsai.jupyter"] = "benlubas/molten-nvim",
  ["ms-python.python"] = "LazyVim's lang.python extra (Plugins > Extras)",
  ["ms-pyright.pyright"] = "LazyVim's lang.python extra (Plugins > Extras)",
  ["rust-lang.rust-analyzer"] = "LazyVim's lang.rust extra (Plugins > Extras)",
  ["golang.go"] = "LazyVim's lang.go extra (Plugins > Extras)",
  ["ms-vscode.cpptools"] = "LazyVim's lang.clangd extra (Plugins > Extras)",
  ["llvm-vs-code-extensions.vscode-clangd"] = "LazyVim's lang.clangd extra (Plugins > Extras)",
  ["redhat.java"] = "LazyVim's lang.java extra (Plugins > Extras)",
  ["redhat.vscode-yaml"] = "LazyVim's lang.yaml extra (Plugins > Extras)",
  ["ms-dotnettools.csharp"] = "LazyVim's lang.dotnet extra (Plugins > Extras)",
  ["vue.volar"] = "LazyVim's lang.vue extra (Plugins > Extras)",
  ["svelte.svelte-vscode"] = "LazyVim's lang.svelte extra (Plugins > Extras)",
  ["astro-build.astro-vscode"] = "LazyVim's lang.astro extra (Plugins > Extras)",
  ["bradlc.vscode-tailwindcss"] = "LazyVim's lang.tailwind extra (Plugins > Extras)",
  ["tamasfe.even-better-toml"] = "LazyVim's lang.toml extra (Plugins > Extras)",
  ["ms-azuretools.vscode-docker"] = "LazyVim's lang.docker extra (Plugins > Extras)",
  ["ms-vscode.vscode-typescript-next"] = "LazyVim's lang.typescript extra (Plugins > Extras)",
  ["dart-code.dart-code"] = "LazyVim's lang.dart extra (Plugins > Extras)",
  ["dart-code.flutter"] = "akinsho/flutter-tools.nvim",
  ["ritwickdey.liveserver"] = "a live-reload server in the terminal, for example npx live-server",
  ["ms-vscode.live-server"] = "a live-reload server in the terminal, for example npx live-server",
  ["ms-vscode-remote.remote-ssh"] = "run nvs.ide on the remote machine, or edit scp:// paths",
}

local T3_KEYS = {
  { key = "viewsContainers", what = "view containers" },
  { key = "views", what = "tree views" },
  { key = "customEditors", what = "custom editors" },
  { key = "notebooks", what = "notebooks" },
  { key = "notebookRenderer", what = "notebook renderers" },
  { key = "walkthroughs", what = "walkthroughs" },
}
local T1_KEYS = { "themes", "iconThemes", "snippets", "grammars", "languages" }
local T1_ONLY = {
  themes = true, iconThemes = true, snippets = true, grammars = true, languages = true,
  configuration = true, configurationDefaults = true, jsonValidation = true, keybindings = true,
  colors = true, semanticTokenScopes = true,
}
local SERVER_DIRS = { server = true, dist = true, out = true, lib = true, bin = true }
-- A file is a server candidate when one of the WORDS of its name is one of these (the
-- contract's "whose name matches"): "language-server" is the words language + server. A
-- substring test took lib/observer.js and out/serverless-helpers.js for servers.
local SERVER_WORDS = { server = true, languageserver = true, langserver = true, lsp = true }

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function list(v)
  return type(v) == "table" and vim.islist(v) and v or {}
end

local function strings(v)
  local out = {}
  for _, s in ipairs(list(v)) do
    if type(s) == "string" then
      out[#out + 1] = s
    end
  end
  return out
end

-- jsonc.decode leaves JSON null as vim.NIL; package.json is easier to walk without it.
local function nilify(v)
  if v == vim.NIL then
    return nil
  end
  if type(v) == "table" then
    for k, x in pairs(v) do
      v[k] = nilify(x)
    end
  end
  return v
end

local function first_line(s)
  return (tostring(s or ""):match("[^\r\n]+") or "")
end

local function notify(msg, level)
  vim.schedule(function()
    vim.notify(msg, level or vim.log.levels.INFO, { title = TITLE })
  end)
end

local function progress(id, stage, message)
  if M.on_progress then
    pcall(M.on_progress, id, stage, message or "")
  end
end

local function changed()
  vim.api.nvim_exec_autocmds("User", { pattern = "NvsVsxChanged", modeline = false })
end

local function pref(id, default)
  local ok, prefs = pcall(require, "nvs.prefs")
  local v = ok and prefs.get(id) or nil
  if v == nil or v == "" then
    return default
  end
  return v
end

local function registry_url()
  return (tostring(pref("openvsx", "https://open-vsx.org")):gsub("/+$", ""))
end

local function host_mode()
  local m = pref("exthost", "demand")
  if m ~= "always" and m ~= "never" then
    m = "demand"
  end
  return m
end

local function node_bin()
  return tostring(pref("vsx_node", "node"))
end

function M.dir()
  return vim.fn.stdpath("data") .. "/vsx"
end
local function ext_dir(id)
  return M.dir() .. "/extensions/" .. id
end
local function colors_dir()
  return M.dir() .. "/colors"
end
local function log_file(id)
  return M.dir() .. "/logs/" .. id .. ".log"
end
local function downloads_dir()
  return M.dir() .. "/downloads"
end
local function host_js()
  return vim.fn.stdpath("config") .. "/exthost/host.js"
end

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

local function write_file(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f, err = io.open(path, "wb")
  if not f then
    return false, err
  end
  f:write(text)
  f:close()
  return true
end

local function remove(path)
  if not exists(path) then
    return true
  end
  return vim.fn.delete(path, "rf") == 0
end

-- A .vsix is a zip archive. bsdtar reads zip: it is Windows' tar.exe (the System32 one,
-- so a GNU tar earlier on PATH, such as Git's, cannot be picked up) and macOS's tar. Linux's
-- tar is GNU tar, which cannot, so there bsdtar (libarchive) or unzip does it.
-- unzip_argv(archive, dest) is the command, or nil when nothing here can.
local function unzip_argv(archive, dest)
  local function bsdtar(bin)
    return { bin, "-xf", archive, "-C", dest }
  end
  if is_win then
    local sys = (vim.env.SystemRoot or "C:\\Windows") .. "\\System32\\tar.exe"
    if vim.fn.executable(sys) == 1 then
      return bsdtar(sys)
    end
  end
  if vim.fn.executable("bsdtar") == 1 then
    return bsdtar("bsdtar")
  end
  if vim.fn.executable("unzip") == 1 then
    return { "unzip", "-q", "-o", archive, "-d", dest }
  end
  if (is_win or vim.fn.has("mac") == 1) and vim.fn.executable("tar") == 1 then
    return bsdtar("tar")
  end
  return nil
end

local UNZIP_MISSING = "Nothing here can unpack a .vsix (a zip file). Windows 10 and newer ship tar.exe in C:\\Windows\\System32 and macOS has it built in; on Linux install unzip (sudo apt install unzip, or sudo pacman -S unzip)."

local function node_missing()
  return ("node was not found (setting vsx_node = %q). Install Node 18 or newer; on Windows: winget install OpenJS.NodeJS.LTS"):format(node_bin())
end

---------------------------------------------------------------------------
-- The registry file
---------------------------------------------------------------------------

local registry = nil
local registry_warned = false

local function registry_path()
  return M.dir() .. "/vsx.json"
end

local function load_registry()
  registry = { version = 1, extensions = {} }
  local text = read_file(registry_path())
  if not text then
    return
  end
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if ok and type(data) == "table" and type(data.extensions) == "table" then
    registry.extensions = list(data.extensions)
  elseif not registry_warned then
    registry_warned = true
    notify(("Could not read %s; no extensions were loaded."):format(registry_path()), vim.log.levels.WARN)
  end
end

local function ensure_loaded()
  if not registry then
    load_registry()
  end
end

local function save_registry()
  local out = { version = 1, extensions = {} }
  for i, e in ipairs(registry.extensions) do
    local copy = vim.deepcopy(e)
    if copy.server == nil then
      copy.server = vim.NIL
    end
    if copy.alt == nil then
      copy.alt = vim.NIL
    end
    out.extensions[i] = copy
  end
  local ok, err = write_file(registry_path(), vim.json.encode(out))
  if not ok then
    notify(("Could not write %s: %s"):format(registry_path(), tostring(err)), vim.log.levels.WARN)
  end
  return ok
end

local function find(id)
  if type(id) ~= "string" then
    return nil
  end
  for i, e in ipairs(registry.extensions) do
    if e.id == id then
      return e, i
    end
  end
  local lower = id:lower()
  for i, e in ipairs(registry.extensions) do
    if type(e.id) == "string" and e.id:lower() == lower then
      return e, i
    end
  end
  return nil
end

local function read_pkg(id)
  local ok, pkg = jsonc.read(ext_dir(id) .. "/package.json")
  if ok and type(pkg) == "table" then
    return nilify(pkg)
  end
  return nil
end

---------------------------------------------------------------------------
-- Classification (pure)
---------------------------------------------------------------------------

function M.filetype_of(lang)
  return M.LANGUAGE_IDS[lang] or lang
end

function M.alternative(id)
  return M.ALTERNATIVES[tostring(id):lower()]
end

-- "Catppuccin Mocha" -> "catppuccin-mocha": lower-cased, runs of spaces and punctuation
-- become one dash. Letters outside ASCII are kept (Neovim accepts them in a scheme name).
function M.scheme_name(label)
  local s = vim.fn.tolower(tostring(label or ""))
  s = s:gsub("[%s%p]+", "-")
  s = s:gsub("^%-+", ""):gsub("%-+$", "")
  if s == "" then
    s = "theme"
  end
  return s
end

local function present(c, key)
  local v = c[key]
  if type(v) == "table" then
    return next(v) ~= nil
  end
  return v ~= nil and v ~= false
end

-- The declared main bundle, with the extension VS Code would add when it is missing.
local function resolve_main(pkg, files)
  local main = pkg.main
  if type(main) ~= "string" or main == "" then
    return nil
  end
  main = main:gsub("\\", "/"):gsub("^%./", "")
  local set = {}
  for _, f in ipairs(files) do
    set[(f:gsub("\\", "/"):gsub("^%./", ""))] = true
  end
  if set[main] then
    return main
  end
  for _, suffix in ipairs({ ".js", ".cjs", ".mjs", "/index.js" }) do
    if set[main .. suffix] then
      return main .. suffix
    end
  end
  return main
end

-- The words of a file name: "eslintServer.js" -> eslint, server, js; "yaml-language-server.js"
-- -> yaml, language, server, js; "LSPServer.js" -> lsp, server, js; "observer.js" -> observer,
-- js. Word breaks are non-alphanumerics and camelCase steps.
local function name_words(name)
  local s = name:gsub("(%l)(%u)", "%1 %2"):gsub("(%d)(%u)", "%1 %2"):gsub("(%u)(%u%l)", "%1 %2")
  local words = {}
  for w in s:lower():gmatch("%w+") do
    words[#words + 1] = w
  end
  return words
end

-- The bundled server, if any: docs/extensions.md, classification step 2.
local function find_server(files, id)
  local known, generic = nil, nil
  for _, raw in ipairs(files) do
    if type(raw) == "string" then
      local path = raw:gsub("\\", "/"):gsub("^%./", "")
      local parts = vim.split(path, "/", { plain = true })
      local name = parts[#parts]
      local base = name:lower()
      local dirs = #parts - 1
      local ok = dirs >= 1 and dirs <= 4 and SERVER_DIRS[parts[1]:lower()] == true
      for _, p in ipairs(parts) do
        if p == "node_modules" then
          ok = false
        end
      end
      if ok then
        for _, rule in ipairs(M.KNOWN_SERVERS) do
          local hit = (rule.file and base == rule.file) or (rule.match and base:find(rule.match) ~= nil)
          if hit and (rule.id == nil or rule.id == id) and (rule.native or base:match("%.m?js$")) then
            if not known or #path < #known.path then
              known = { path = path, lspconfig = rule.lspconfig, native = rule.native or nil }
            end
          end
        end
        local js = base:match("%.m?js$") ~= nil
        local skipped = base:match("%-web%.js$") or base:find("browser", 1, true) or base:match("%.worker%.js$")
        if js and not skipped then
          -- A name with the word "client" (out/lspClient.js) is the extension's own LSP
          -- client, which never runs here; it must not be taken for the server.
          local named, client = false, false
          for _, w in ipairs(name_words(name)) do
            if SERVER_WORDS[w] then
              named = true
            elseif w == "client" then
              client = true
            end
          end
          if named and not client then
            local better = generic == nil
              or #path < #generic.path
              or (#path == #generic.path and base:find("server", 1, true) ~= nil and generic.base:find("server", 1, true) == nil)
            if better then
              generic = { path = path, base = base }
            end
          end
        end
      end
    end
  end
  if known then
    return { path = known.path, lspconfig = known.lspconfig, native = known.native, args = known.native and {} or { "--stdio" } }
  end
  if generic then
    return { path = generic.path, lspconfig = nil, args = { "--stdio" } }
  end
  return nil
end

-- classify(pkg, files, main_text) -> { tier, why, server, main }
-- pkg is the parsed extension/package.json, files the paths inside extension/ (forward
-- slashes, relative), main_text the main bundle's source when the caller has it (the
-- webview check needs it; without it that check is skipped). Pure: no file access.
function M.classify(pkg, files, main_text)
  pkg = type(pkg) == "table" and pkg or {}
  files = list(files)
  local c = type(pkg.contributes) == "table" and pkg.contributes or {}
  local id = tostring(pkg.publisher or "?") .. "." .. tostring(pkg.name or "?")
  local main = resolve_main(pkg, files)

  -- 1. Needs a UI Neovim does not have.
  for _, k in ipairs(T3_KEYS) do
    if present(c, k.key) then
      return { tier = "t3", why = ("needs %s, which Neovim has no equivalent for"):format(k.what), main = main }
    end
  end
  if type(main_text) == "string" and (main_text:find("createWebviewPanel", 1, true) or main_text:find("registerWebviewViewProvider", 1, true)) then
    return { tier = "t3", why = "opens webviews, which Neovim has no equivalent for", main = main }
  end

  -- 2. Ships a language server.
  local server = find_server(files, id)
  if server then
    local why = ("ships a language server (%s); Neovim's own LSP client runs it"):format(server.path)
    if server.lspconfig then
      why = why .. (" with the %s settings from nvim-lspconfig"):format(server.lspconfig)
    end
    return { tier = "lsp", why = why, server = server, main = main }
  end

  -- 3. Declarative.
  local declared = {}
  for _, k in ipairs(T1_KEYS) do
    if present(c, k) then
      declared[#declared + 1] = k
    end
  end
  if #declared > 0 then
    local themed = false
    for _, cat in ipairs(strings(pkg.categories)) do
      if cat == "Themes" or cat == "Snippets" then
        themed = true
      end
    end
    local only_declarative = true
    for k in pairs(c) do
      if not T1_ONLY[k] then
        only_declarative = false
      end
    end
    if main == nil or themed or only_declarative then
      return {
        tier = "t1",
        why = ("declarative (%s); converted at install, nothing runs afterwards"):format(table.concat(declared, ", ")),
        main = main,
      }
    end
  end

  -- 4. Code against the vscode API.
  if main or type(pkg.browser) == "string" then
    return { tier = "t2", why = "registers providers or commands through the vscode API; runs in the extension host", main = main }
  end
  if present(pkg, "extensionPack") then
    return { tier = "t1", why = "an extension pack: install the extensions it lists one by one", main = nil }
  end
  return { tier = "t1", why = "declares nothing Neovim needs to run or convert", main = nil }
end

---------------------------------------------------------------------------
-- Converters: languages, themes, snippets
---------------------------------------------------------------------------

-- Rules added this session, so a re-install counts them as its own again.
local our_rules = {}

-- contributes.languages -> vim.filetype.add rules, for extensions and file names Neovim
-- does not already detect (its own rules are kept: a VS Code id would otherwise clobber,
-- say, .json). Returns the filetypes that gained a rule and how many Neovim already had.
local function register_filetypes(pkg)
  local ext_rules, name_rules, added, seen, known = {}, {}, {}, {}, 0
  local function note(ft)
    if not seen[ft] then
      seen[ft] = true
      added[#added + 1] = ft
    end
  end
  local function fresh(key, probe)
    if our_rules[key] then
      return true
    end
    local ok, ft = pcall(function()
      return (vim.filetype.match({ filename = probe }))
    end)
    return not ok or ft == nil
  end
  for _, lang in ipairs(list(vim.tbl_get(pkg, "contributes", "languages"))) do
    if type(lang) == "table" and type(lang.id) == "string" then
      local ft = M.filetype_of(lang.id)
      for _, ext in ipairs(strings(lang.extensions)) do
        local e = ext:gsub("^%.", "")
        -- Neovim keys its extension table by the text after the last dot; "d.ts"-style
        -- extensions and globs cannot be expressed there and are left to the defaults.
        if e ~= "" and not e:find("[%./%*%s]") then
          if fresh("ext:" .. e, "x." .. e) then
            ext_rules[e] = ft
            our_rules["ext:" .. e] = true
            note(ft)
          else
            known = known + 1
          end
        end
      end
      for _, name in ipairs(strings(lang.filenames)) do
        if name ~= "" and not name:find("[/%*]") then
          if fresh("name:" .. name, name) then
            name_rules[name] = ft
            our_rules["name:" .. name] = true
            note(ft)
          else
            known = known + 1
          end
        end
      end
    end
  end
  if next(ext_rules) or next(name_rules) then
    vim.filetype.add({ extension = ext_rules, filename = name_rules })
  end
  table.sort(added)
  return added, known
end

-- contributes.themes -> colors/<scheme>.lua through nvs.vsx_theme (written by another
-- part of the project; missing means "not converted yet", not an error).
local function convert_themes(entry, c, dir)
  local themes = list(c.themes)
  if #themes == 0 then
    return
  end
  local ok, conv = pcall(require, "nvs.vsx_theme")
  if not ok or type(conv) ~= "table" or type(conv.convert) ~= "function" then
    table.insert(entry.converted.skipped, "themes: not converted yet (the theme converter nvs.vsx_theme is missing)")
    return
  end
  for _, t in ipairs(themes) do
    if type(t) == "table" and type(t.path) == "string" then
      local label = tostring(t.label or t.id or vim.fn.fnamemodify(t.path, ":t:r"))
      local scheme = M.scheme_name(label)
      local path = dir .. "/" .. (t.path:gsub("^%./", ""))
      local cok, src, report = pcall(conv.convert, path, scheme, { ui_theme = t.uiTheme })
      if cok and type(src) == "string" and src ~= "" then
        local wok, werr = write_file(colors_dir() .. "/" .. scheme .. ".lua", src)
        if wok then
          table.insert(entry.converted.colors, scheme)
          if type(report) == "table" then
            -- The counts the Plugins screen can show; the full report stays with the converter.
            entry.converted.reports = entry.converted.reports or {}
            entry.converted.reports[scheme] = {
              colors = tonumber(report.colors_mapped) or 0,
              tokens = tonumber(report.tokens_mapped) or 0,
              unknown = #list(report.unknown_scopes),
              warnings = #list(report.warnings),
            }
          end
        else
          table.insert(entry.converted.skipped, ("theme %s: could not write the colour scheme: %s"):format(label, tostring(werr)))
        end
      else
        -- convert() returns nil, report with report.error when the theme cannot be read.
        local why
        if not cok then
          why = tostring(src)
        elseif type(report) == "table" and report.error then
          why = tostring(report.error)
        else
          why = type(src) == "string" and src or tostring(report or "the converter returned nothing")
        end
        table.insert(entry.converted.skipped, ("theme %s: %s"):format(label, why))
      end
    end
  end
end

local function convert_all(entry, pkg, dir)
  local c = type(pkg.contributes) == "table" and pkg.contributes or {}
  local conv = entry.converted
  local added, known = register_filetypes(pkg)
  conv.filetypes = added
  if known > 0 then
    table.insert(conv.skipped, ("languages: %d rule%s Neovim already had"):format(known, known == 1 and "" or "s"))
  end
  convert_themes(entry, c, dir)
  local n = entry.contributes
  if n.snippets > 0 then
    -- blink reads them straight from this folder (contributes.snippets), once, at start.
    conv.snippets = true
    entry.restart = true
    table.insert(conv.skipped, "snippets: available after a restart (blink.cmp reads its paths once)")
  end
  if n.grammars > 0 then
    table.insert(conv.skipped, "grammars: Neovim highlights with tree-sitter")
  end
  if n.iconThemes > 0 then
    table.insert(conv.skipped, "iconThemes: icons are drawn by the window")
  end
  if n.commands > 0 and (entry.tier == "t1" or entry.tier == "lsp") then
    table.insert(conv.skipped, ("commands: %d not available; the extension's own code does not run in the %s tier"):format(n.commands, entry.tier))
  end
  if entry.tier == "t3" then
    table.insert(conv.skipped, "code: not run (" .. entry.why .. ")")
  end
end

---------------------------------------------------------------------------
-- Applying an extension to the running session
---------------------------------------------------------------------------

local function lsp_name(entry)
  return "vsx_" .. tostring(entry.name)
end

-- Filetypes from onLanguage activation events and contributed languages; nil when the
-- extension names none.
local function language_filetypes(entry)
  local fts, seen = {}, {}
  local function add(lang)
    local ft = M.filetype_of(lang)
    if not seen[ft] then
      seen[ft] = true
      fts[#fts + 1] = ft
    end
  end
  for _, ev in ipairs(entry.activation or {}) do
    local lang = ev:match("^onLanguage:(.+)$")
    if lang then
      add(lang)
    end
  end
  for _, lang in ipairs(entry.languages or {}) do
    add(lang)
  end
  if #fts == 0 then
    return nil
  end
  table.sort(fts)
  return fts
end

-- The extension host's filetypes (t2 tier): nil means every filetype, which is what
-- onStartupFinished, * and an empty activation list mean to VS Code.
local function declared_filetypes(entry)
  for _, ev in ipairs(entry.activation or {}) do
    if ev == "*" or ev == "onStartupFinished" or ev == "onLanguage" then
      return nil
    end
  end
  return language_filetypes(entry)
end

local function lspconfig_base(name)
  local ok, cfg = pcall(function()
    return vim.lsp.config[name]
  end)
  if ok and type(cfg) == "table" then
    return cfg
  end
  return nil
end

-- LazyVim loads nvim-lspconfig on the first file; until then its lsp/*.lua files are not
-- on the runtimepath and vim.lsp.config["eslint"] is nil.
local function lspconfig_pending()
  local ok, lazy = pcall(require, "lazy.core.config")
  local plugin = ok and type(lazy.plugins) == "table" and lazy.plugins["nvim-lspconfig"] or nil
  return plugin ~= nil and plugin._ ~= nil and plugin._.loaded == nil
end

-- vim.lsp.enable() attaches its config to buffers that are already open only once
-- VimEnter has happened; before that (a headless probe, an install during startup) the
-- open buffers would be missed. Run Neovim's own enable callback for the matching ones.
local function attach_open_buffers(name)
  if vim.v.vim_did_enter == 1 or not vim.lsp.is_enabled(name) then
    return
  end
  local cfg = vim.lsp.config[name]
  if not cfg then
    return
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local ft = vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype or ""
    if ft ~= "" and vim.bo[buf].buftype == "" and (cfg.filetypes == nil or vim.tbl_contains(cfg.filetypes, ft)) then
      pcall(vim.api.nvim_exec_autocmds, "FileType", { group = "nvim.lsp.enable", buffer = buf, modeline = false })
    end
  end
end

local waiting = {}
local register_lsp

-- lsp tier: vim.lsp.config("vsx_<name>", { cmd = { node, <server>, --stdio }, ... })
-- merged over nvim-lspconfig's config for that server when it exists, then enabled.
register_lsp = function(entry)
  local server = entry.server
  if type(server) ~= "table" or type(server.path) ~= "string" then
    return
  end
  local name = lsp_name(entry)
  local server_path = ext_dir(entry.id) .. "/" .. server.path
  local cmd
  if server.native then
    cmd = { server_path }
  else
    cmd = vim.list_extend({ node_bin(), server_path }, strings(server.args))
  end
  local base
  if server.lspconfig then
    base = lspconfig_base(server.lspconfig)
    if not base and lspconfig_pending() then
      if not waiting[entry.id] then
        waiting[entry.id] = true
        vim.api.nvim_create_autocmd("User", {
          pattern = "LazyLoad",
          callback = function(ev)
            if ev.data ~= "nvim-lspconfig" then
              return
            end
            waiting[entry.id] = nil
            local e = find(entry.id)
            if e and e.enabled and e.tier == "lsp" then
              pcall(register_lsp, e)
            end
            return true
          end,
        })
      end
      return
    end
    base = base or FALLBACK_LSP[server.lspconfig]
  end
  local mine = { cmd = cmd }
  if type(entry.l10n) == "string" then
    -- What VS Code's client does for a Node server: vscode-languageclient exports the
    -- bundle's location, and vscode-yaml also passes it as initializationOptions.l10nPath;
    -- without either the server looks for dist/../../../l10n and fails to initialize.
    local l10n_dir = ext_dir(entry.id) .. "/" .. entry.l10n
    local bundle = l10n_dir .. "/bundle.l10n.json"
    if exists(bundle) then
      mine.init_options = { l10nPath = l10n_dir }
      mine.cmd_env = { VSCODE_L10N_BUNDLE_LOCATION = vim.uri_from_fname(bundle) }
    end
  end
  local cfg = vim.tbl_deep_extend("force", base or {}, mine)
  cfg.name = nil
  if cfg.filetypes == nil then
    -- A server nvim-lspconfig does not know: the languages the extension declares say
    -- which files it is for. "Every filetype" is the host's rule, never a bundled
    -- server's, or it would attach to every buffer.
    cfg.filetypes = language_filetypes(entry)
  end
  vim.lsp.config[name] = cfg
  if cfg.filetypes == nil then
    entry.error = ("%s declares no languages (no contributes.languages and no onLanguage activation event), so Neovim cannot tell which files its server %s is for; it is installed but not enabled."):format(entry.id, server.path)
    return
  end
  vim.lsp.enable(name)
  attach_open_buffers(name)
end

-- t2 tier: the extension host is one more language server to Neovim. The config is always
-- registered (so its shape can be inspected); it is enabled only when node and host.js
-- are there, otherwise every buffer would report a failed spawn.
local function register_host(entry, mode)
  local name = lsp_name(entry)
  local node = node_bin()
  vim.fn.mkdir(M.dir() .. "/logs", "p")
  vim.lsp.config[name] = {
    cmd = { node, host_js(), "--extension", ext_dir(entry.id), "--data", M.dir(), "--log", log_file(entry.id), "--stdio" },
    filetypes = declared_filetypes(entry),
  }
  if vim.fn.executable(node) ~= 1 then
    entry.error = node_missing()
    return
  end
  if not exists(host_js()) then
    entry.error = ("The extension host is missing from this runtime (%s); the extension is installed but cannot run."):format(host_js())
    return
  end
  vim.lsp.enable(name)
  attach_open_buffers(name)
  if mode == "always" then
    -- Always: start the host now, unattached; buffers that match reuse it.
    pcall(vim.lsp.start, vim.lsp.config[name], { attach = false, silent = true })
  end
end

-- Disable the config (which asks its clients to shut down, force-stopping only after
-- their exit timeout) and stop any client that was started outside the config.
local function stop_entry(entry)
  local name = lsp_name(entry)
  if vim.lsp.is_enabled(name) then
    pcall(vim.lsp.enable, name, false)
  else
    for _, client in ipairs(vim.lsp.get_clients({ name = name })) do
      pcall(client.stop, client)
    end
  end
end

local function apply_entry(entry)
  entry.error = nil
  if not entry.enabled then
    return
  end
  if entry.tier == "lsp" then
    if not (entry.server and entry.server.native) and vim.fn.executable(node_bin()) ~= 1 then
      entry.error = node_missing()
    end
    register_lsp(entry)
  elseif entry.tier == "t2" then
    local mode = host_mode()
    if mode ~= "never" then
      register_host(entry, mode)
    end
  end
end

-- Every enabled extension folder that contributes snippets, for blink (plugins/nvs.lua).
local function refresh_snippet_paths()
  local paths = {}
  for _, e in ipairs(registry.extensions) do
    if e.enabled and type(e.contributes) == "table" and (tonumber(e.contributes.snippets) or 0) > 0 then
      paths[#paths + 1] = vim.fs.normalize(ext_dir(e.id))
    end
  end
  vim.g.nvs_vsx_snippet_paths = paths
end

-- PREPEND the vsx folder to 'runtimepath' (docs/extensions.md, setup): :colorscheme sources
-- the first colors/<name>.lua it finds, and LazyVim ships catppuccin.nvim, whose
-- colors/catppuccin-mocha.lua would otherwise shadow the theme the person installed once
-- that plugin is loaded. lazy.nvim keeps the order when it rebuilds the option, so first
-- stays first; a folder found further down is moved to the front.
local function add_rtp()
  local dir = M.dir()
  local want = vim.fs.normalize(dir)
  for i, p in ipairs(vim.opt.runtimepath:get()) do
    local have = vim.fs.normalize(p)
    if have == want or (is_win and have:lower() == want:lower()) then
      if i == 1 then
        return
      end
      vim.opt.runtimepath:remove(p)
      break
    end
  end
  vim.opt.runtimepath:prepend(dir)
end

local node_version = nil
local function probe_node()
  local node = node_bin()
  if vim.fn.executable(node) ~= 1 then
    node_version = nil
    return
  end
  pcall(vim.system, { node, "--version" }, { text = true }, function(o)
    vim.schedule(function()
      node_version = (o.code == 0 and o.stdout and o.stdout ~= "") and vim.trim(o.stdout) or nil
    end)
  end)
end

---------------------------------------------------------------------------
-- Public state
---------------------------------------------------------------------------

function M.list()
  ensure_loaded()
  return registry.extensions
end

function M.status()
  ensure_loaded()
  local node = node_bin()
  local running, count = false, 0
  for _, e in ipairs(registry.extensions) do
    if e.tier == "t2" and e.enabled then
      count = count + 1
      if #vim.lsp.get_clients({ name = lsp_name(e) }) > 0 then
        running = true
      end
    end
  end
  return {
    host = { running = running, mode = host_mode(), node = vim.fn.executable(node) == 1 and node or nil, extensions = count },
    registry = registry_url(),
    node_version = node_version,
  }
end

function M.setup()
  load_registry()
  -- Only an existing folder goes on 'runtimepath': lazy.nvim rebuilds the option from the
  -- directories that exist whenever it loads a plugin, and would drop a missing one.
  if exists(M.dir()) then
    add_rtp()
  end
  for _, entry in ipairs(registry.extensions) do
    local ok, err = pcall(function()
      local pkg = read_pkg(entry.id)
      if pkg then
        register_filetypes(pkg)
      end
      apply_entry(entry)
    end)
    if not ok then
      notify(("Extension %s did not load: %s"):format(tostring(entry.id), tostring(err)), vim.log.levels.WARN)
    end
  end
  refresh_snippet_paths()
  probe_node()
end

-- The exthost setting changed (prefs.lua): demand | always | never.
function M.apply_host_mode(mode)
  ensure_loaded()
  if mode ~= "always" and mode ~= "never" then
    mode = "demand"
  end
  for _, e in ipairs(registry.extensions) do
    if e.tier == "t2" then
      if mode == "never" or not e.enabled then
        stop_entry(e)
      else
        register_host(e, mode)
      end
    end
  end
  changed()
end

function M.set_enabled(id, on)
  ensure_loaded()
  local entry = find(id)
  if not entry then
    return false, ("%s is not installed."):format(tostring(id))
  end
  entry.enabled = on == true
  save_registry()
  if entry.enabled then
    apply_entry(entry)
  else
    stop_entry(entry)
  end
  refresh_snippet_paths()
  changed()
  return true
end

function M.uninstall(id)
  ensure_loaded()
  local entry, index = find(id)
  if not entry then
    return false, ("%s is not installed."):format(tostring(id))
  end
  stop_entry(entry)
  table.remove(registry.extensions, index)
  save_registry()
  refresh_snippet_paths()
  for _, scheme in ipairs(list(type(entry.converted) == "table" and entry.converted.colors or nil)) do
    remove(colors_dir() .. "/" .. scheme .. ".lua")
  end
  remove(log_file(entry.id))
  -- A server started from the folder may need a moment to exit before Windows lets go.
  local dir = ext_dir(entry.id)
  local function try(n)
    if remove(dir) then
      return
    end
    if n < 4 then
      vim.defer_fn(function()
        try(n + 1)
      end, 400)
    else
      notify(("Uninstalled %s, but its folder could not be removed: %s"):format(entry.id, dir), vim.log.levels.WARN)
    end
  end
  try(1)
  notify(("Uninstalled %s."):format(entry.displayName or entry.id))
  changed()
  return true
end

---------------------------------------------------------------------------
-- Checksums
---------------------------------------------------------------------------

local function hex_digest(text)
  for line in (tostring(text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local token = line:match("^%s*(%S+)")
    if token and #token == 64 and token:match("^%x+$") then
      return token:lower()
    end
    -- Older certutil prints the bytes separated by spaces.
    if line:match("^[%x%s]+$") then
      local compact = line:gsub("%s", "")
      if #compact == 64 then
        return compact:lower()
      end
    end
  end
  return nil
end

-- sha256_file(path, cb): cb(err, hex). certutil on Windows, sha256sum or shasum
-- elsewhere, both off the main loop; Neovim's own sha256 over the bytes as a last resort.
function M.sha256_file(path, cb)
  local cmd
  if is_win and vim.fn.executable("certutil") == 1 then
    cmd = { "certutil", "-hashfile", path, "SHA256" }
  elseif vim.fn.executable("sha256sum") == 1 then
    cmd = { "sha256sum", path }
  elseif vim.fn.executable("shasum") == 1 then
    cmd = { "shasum", "-a", "256", path }
  end
  local function fallback()
    local data = read_file(path)
    if not data then
      return cb(("Could not read %s to check it."):format(path))
    end
    cb(nil, vim.fn.sha256(data))
  end
  if not cmd then
    return fallback()
  end
  local ok = pcall(vim.system, cmd, { text = true }, function(o)
    vim.schedule(function()
      local hex = o.code == 0 and hex_digest(o.stdout) or nil
      if hex then
        cb(nil, hex)
      else
        fallback()
      end
    end)
  end)
  if not ok then
    fallback()
  end
end

-- verify_file(path, expected_hex, cb): cb(err, hex). The file is left in place; the
-- caller removes it on a mismatch.
function M.verify_file(path, expected, cb)
  expected = tostring(expected or ""):lower()
  M.sha256_file(path, function(err, hex)
    if err then
      return cb(err)
    end
    if hex ~= expected then
      return cb(("The download's checksum did not match the registry's (expected %s…, got %s…); the file was removed."):format(expected:sub(1, 12), tostring(hex):sub(1, 12)))
    end
    cb(nil, hex)
  end)
end

---------------------------------------------------------------------------
-- The registry client
---------------------------------------------------------------------------

local function url_encode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(ch)
    return ("%%%02X"):format(ch:byte())
  end))
end

local function curl_message(stderr)
  local line = first_line(stderr):gsub("^curl: %(%d+%) ", "")
  if line == "" then
    line = "no response"
  end
  return line
end

-- GET a URL as text: cb(err, body).
local function http_get(url, cb)
  if vim.fn.executable("curl") == 0 then
    return cb("curl was not found. Windows 10 and newer ship it in C:\\Windows\\System32; on Linux install it with your package manager (for example: sudo apt install curl).")
  end
  local ok, err = pcall(vim.system, { "curl", "-sSL", "--fail", "--max-time", "60", url }, { text = true }, function(o)
    vim.schedule(function()
      if o.code ~= 0 then
        local msg = curl_message(o.stderr)
        if msg:find("404", 1, true) then
          return cb(("Not found on the registry: %s"):format(url), nil, 404)
        end
        return cb(("The registry at %s could not be reached: %s"):format(registry_url(), msg))
      end
      cb(nil, o.stdout or "")
    end)
  end)
  if not ok then
    cb("Could not run curl: " .. tostring(err))
  end
end

local function decode_json(body)
  local ok, data = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  if ok and type(data) == "table" then
    return data
  end
  return nil
end

local function split_id(id)
  if type(id) ~= "string" then
    return nil
  end
  local ns, name = id:match("^([%w%-_]+)%.([%w%-_.]+)$")
  return ns, name
end

-- search(query, cb): cb(err, results) with results as docs/extensions.md lists them.
function M.search(query, cb)
  ensure_loaded()
  local base = registry_url()
  local url = ("%s/api/-/search?query=%s&size=25&sortBy=relevance"):format(base, url_encode(query or ""))
  http_get(url, function(err, body)
    if err then
      return cb(err, {})
    end
    local data = decode_json(body)
    if not data then
      return cb(("The registry at %s answered with something that is not JSON."):format(base), {})
    end
    local results = {}
    for _, x in ipairs(list(data.extensions)) do
      if type(x) == "table" and type(x.namespace) == "string" and type(x.name) == "string" then
        local id = x.namespace .. "." .. x.name
        results[#results + 1] = {
          id = id,
          namespace = x.namespace,
          name = x.name,
          displayName = type(x.displayName) == "string" and x.displayName or x.name,
          description = type(x.description) == "string" and x.description or "",
          version = tostring(x.version or ""),
          downloads = tonumber(x.downloadCount) or 0,
          rating = tonumber(x.averageRating) or 0,
          timestamp = type(x.timestamp) == "string" and x.timestamp or "",
          installed = find(id) ~= nil,
        }
      end
    end
    cb(nil, results)
  end)
end

-- info(id, cb): cb(err, metadata) with files.download and files.sha256 among the rest.
function M.info(id, cb)
  local ns, name = split_id(id)
  if not ns then
    return cb(("An extension id looks like publisher.name, for example esbenp.prettier-vscode, not %q."):format(tostring(id)))
  end
  local base = registry_url()
  http_get(("%s/api/%s/%s"):format(base, ns, name), function(err, body, code)
    if err then
      if code == 404 then
        return cb(("%s is not on the registry at %s."):format(id, base))
      end
      return cb(err)
    end
    local data = decode_json(body)
    if not data then
      return cb(("The registry at %s answered with something that is not JSON."):format(base))
    end
    cb(nil, data)
  end)
end

---------------------------------------------------------------------------
-- Installing
---------------------------------------------------------------------------

local function build_entry(id, pkg, cls, vsix, old)
  local c = type(pkg.contributes) == "table" and pkg.contributes or {}
  local themes = {}
  for _, t in ipairs(list(c.themes)) do
    if type(t) == "table" then
      themes[#themes + 1] = tostring(t.label or t.id or t.path or "?")
    end
  end
  local languages = {}
  for _, l in ipairs(list(c.languages)) do
    if type(l) == "table" and type(l.id) == "string" then
      languages[#languages + 1] = l.id
    end
  end
  local stat = uv.fs_stat(vsix)
  return {
    id = id,
    namespace = id:match("^([^.]+)%.") or pkg.publisher,
    name = pkg.name,
    version = tostring(pkg.version or ""),
    displayName = type(pkg.displayName) == "string" and pkg.displayName or pkg.name,
    description = type(pkg.description) == "string" and pkg.description or "",
    publisher = pkg.publisher,
    license = type(pkg.license) == "string" and pkg.license or nil,
    tier = cls.tier,
    why = cls.why,
    enabled = old == nil or old.enabled ~= false,
    installed_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    bytes = stat and stat.size or 0,
    main = cls.main,
    server = cls.server,
    activation = strings(pkg.activationEvents),
    languages = languages,
    -- The extension's l10n bundle folder (package.json "l10n"), which a bundled server
    -- expects to be told about the way VS Code's client tells it.
    l10n = type(pkg.l10n) == "string" and (pkg.l10n:gsub("^%./", ""):gsub("/+$", "")) or nil,
    engine = type(vim.tbl_get(pkg, "engines", "vscode")) == "string" and pkg.engines.vscode or nil,
    extensionKind = strings(pkg.extensionKind),
    extensionDependencies = strings(pkg.extensionDependencies),
    contributes = {
      themes = themes,
      iconThemes = #list(c.iconThemes),
      snippets = #list(c.snippets),
      languages = #languages,
      grammars = #list(c.grammars),
      commands = #list(c.commands),
    },
    converted = { colors = {}, filetypes = {}, snippets = false, skipped = {} },
    alt = M.alternative(id),
  }
end

-- Every file under dir, relative with forward slashes; node_modules is never entered.
local function list_files(dir)
  local out = {}
  local ok = pcall(function()
    for name, kind in vim.fs.dir(dir, {
      depth = 6,
      skip = function(d)
        return vim.fs.basename(d) ~= "node_modules"
      end,
    }) do
      if kind == "file" then
        out[#out + 1] = name
      end
    end
  end)
  if not ok then
    return {}
  end
  table.sort(out)
  return out
end

local function finish_install(vsix, stage, opts, cb)
  -- Progress is keyed by the extension id; until package.json has been read that is the
  -- file's base name (install(id) passes opts.id, so its stages all carry the real id).
  local pid = opts.id or vim.fn.fnamemodify(vsix, ":t:r")
  local function fail(msg)
    remove(stage)
    progress(pid, "error", msg)
    cb(msg)
  end
  local src = stage .. "/extension"
  local okp, pkg = jsonc.read(src .. "/package.json")
  if not okp or type(pkg) ~= "table" then
    return fail(("%s has no extension/package.json inside; is it a .vsix? (%s)"):format(vim.fn.fnamemodify(vsix, ":t"), tostring(pkg)))
  end
  pkg = nilify(pkg)
  if type(pkg.name) ~= "string" or pkg.name == "" or type(pkg.publisher) ~= "string" or pkg.publisher == "" then
    return fail(("%s: its package.json names no publisher and name."):format(vim.fn.fnamemodify(vsix, ":t")))
  end
  -- The folder and the entry follow package.json, not the id that was typed: install(id)
  -- passes the registry id in opts.id, and an archive whose package names another
  -- publisher.name is not the extension that was asked for. Progress keeps the caller's
  -- key (the id it asked for, in its spelling) so the shell's row stays the same.
  local id = pkg.publisher .. "." .. pkg.name
  if not id:match("^[%w%-_]+%.[%w%-_.]+$") then
    return fail(("%q is not a usable extension id."):format(id))
  end
  if type(opts.id) == "string" and opts.id:lower() ~= id:lower() then
    return fail(("%s contains %s (its package.json names publisher %s and name %s), not %s; nothing was installed."):format(vim.fn.fnamemodify(vsix, ":t"), id, pkg.publisher, pkg.name, opts.id))
  end
  pid = opts.id or id
  local old = find(id)
  if old then
    stop_entry(old)
  end
  local dest = ext_dir(id)
  local aside = dest .. ".old"
  remove(aside)
  vim.fn.mkdir(M.dir() .. "/extensions", "p")

  local function place()
    if exists(dest) then
      local ok, err = uv.fs_rename(dest, aside)
      if not ok then
        return false, ("Could not move the old version aside (%s): %s. Is a language server from it still running?"):format(dest, tostring(err))
      end
    end
    local ok, err = uv.fs_rename(src, dest)
    if not ok then
      if exists(aside) and not exists(dest) then
        uv.fs_rename(aside, dest)
      end
      return false, ("Could not move the unpacked extension into %s: %s"):format(dest, tostring(err))
    end
    return true
  end

  local function complete()
    remove(stage)
    progress(pid, "convert", "Sorting " .. id .. " into a tier")
    local files = list_files(dest)
    local cls = M.classify(pkg, files, nil)
    if cls.main then
      -- The webview check needs the bundle's text; classify is pure, so read it here.
      local text = read_file(dest .. "/" .. cls.main)
      if text then
        cls = M.classify(pkg, files, text)
      end
    end
    local entry = build_entry(id, pkg, cls, vsix, old)
    if opts.digest then
      entry.sha256 = opts.digest
    end
    add_rtp()
    convert_all(entry, pkg, dest)
    local _, index = find(id)
    if index then
      registry.extensions[index] = entry
    else
      registry.extensions[#registry.extensions + 1] = entry
    end
    save_registry()
    local aok, aerr = pcall(apply_entry, entry)
    if not aok then
      table.insert(entry.converted.skipped, "apply: " .. tostring(aerr))
    end
    refresh_snippet_paths()
    remove(aside)
    local msg = ("Installed %s %s (%s tier)"):format(entry.displayName, entry.version, entry.tier)
    progress(pid, "done", msg)
    notify(msg)
    changed()
    cb(nil, entry)
  end

  -- The old version's server may take a moment to let go of its files (Windows).
  local function try_place(n)
    local ok, err = place()
    if ok then
      return complete()
    end
    if n < 5 and old then
      return vim.defer_fn(function()
        try_place(n + 1)
      end, 300)
    end
    fail(err)
  end
  try_place(1)
end

-- install_file(vsix, cb, opts): the offline half of install. Unpack the archive into
-- extensions/<id>/ (an older version is moved aside first and removed only after success),
-- classify, convert, register in vsx.json and apply to the running session. cb(err, entry).
-- opts.id is the registry id the caller asked for: progress is keyed by it, and an archive
-- whose package.json names a different publisher.name is refused. opts.digest is the
-- verified sha256.
function M.install_file(vsix, cb, opts)
  cb = cb or function() end
  opts = opts or {}
  ensure_loaded()
  local pid = opts.id or vim.fn.fnamemodify(tostring(vsix), ":t:r")
  local function fail(msg)
    progress(pid, "error", msg)
    cb(msg)
  end
  if type(vsix) ~= "string" or not exists(vsix) then
    return fail(("There is no file at %s."):format(tostring(vsix)))
  end
  local stage = ("%s/unpack-%d-%d"):format(downloads_dir(), uv.os_getpid(), uv.hrtime() % 1000000)
  local argv = unzip_argv(vsix, stage)
  if not argv then
    return fail(UNZIP_MISSING)
  end
  vim.fn.mkdir(stage, "p")
  progress(pid, "unpack", "Unpacking " .. vim.fn.fnamemodify(vsix, ":t"))
  local ok, err = pcall(vim.system, argv, { text = true }, function(o)
    vim.schedule(function()
      if o.code ~= 0 then
        remove(stage)
        return fail(("Could not unpack %s: %s"):format(vsix, first_line(o.stderr)))
      end
      local fok, ferr = pcall(finish_install, vsix, stage, opts, cb)
      if not fok then
        remove(stage)
        fail("Installing failed: " .. tostring(ferr))
      end
    end)
  end)
  if not ok then
    remove(stage)
    fail(("Could not run %s: %s"):format(argv[1], tostring(err)))
  end
end

-- install(id, cb): registry metadata, download, checksum, then install_file. cb(err, entry).
function M.install(id, cb)
  cb = cb or function() end
  ensure_loaded()
  local function fail(msg)
    progress(tostring(id), "error", msg)
    cb(msg)
  end
  if not split_id(id) then
    return fail(("An extension id looks like publisher.name, for example esbenp.prettier-vscode, not %q."):format(tostring(id)))
  end
  if not unzip_argv("", "") then
    return fail(UNZIP_MISSING)
  end
  progress(id, "download", "Looking up " .. id)
  M.info(id, function(err, meta)
    if err then
      return fail(err)
    end
    local url = type(meta.files) == "table" and meta.files.download or nil
    if type(url) ~= "string" then
      return fail(("%s has no download on the registry."):format(id))
    end
    vim.fn.mkdir(downloads_dir(), "p")
    local file = ("%s/%s-%s.vsix"):format(downloads_dir(), id, tostring(meta.version or "latest"))
    remove(file)
    progress(id, "download", ("Downloading %s %s"):format(meta.displayName or id, tostring(meta.version or "")))
    local dok, derr = pcall(vim.system, { "curl", "-sSL", "--fail", "--max-time", "600", "-o", file, url }, { text = true }, function(o)
      vim.schedule(function()
        if o.code ~= 0 then
          remove(file)
          return fail(("The download from %s failed: %s"):format(url, curl_message(o.stderr)))
        end
        local sha_url = type(meta.files) == "table" and meta.files.sha256 or nil
        local function unpack(digest)
          M.install_file(file, function(ierr, entry)
            remove(file)
            if ierr then
              return cb(ierr)
            end
            cb(nil, entry)
          end, { id = id, digest = digest })
        end
        if type(sha_url) ~= "string" then
          progress(id, "verify", "The registry publishes no checksum for this version; skipping the check")
          return unpack(nil)
        end
        progress(id, "verify", "Checking the download against the registry's checksum")
        http_get(sha_url, function(herr, body)
          if herr then
            remove(file)
            return fail("The checksum file could not be fetched: " .. herr)
          end
          local expected = hex_digest(body)
          if not expected then
            remove(file)
            return fail(("The registry's checksum file (%s) was not understood."):format(sha_url))
          end
          M.verify_file(file, expected, function(verr, digest)
            if verr then
              remove(file)
              return fail(verr)
            end
            progress(id, "verify", ("Checksum matches (%s…)"):format(digest:sub(1, 12)))
            unpack(digest)
          end)
        end)
      end)
    end)
    if not dok then
      fail("Could not run curl: " .. tostring(derr))
    end
  end)
end

return M
