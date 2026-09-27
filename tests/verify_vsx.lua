-- Headless checks for the extension system (runtime/lua/nvs/vsx.lua, docs/extensions.md).
-- Run from the repo root inside the test sandbox; tests/run.ps1 sets that up:
--   nvim --headless -c "luafile tests/verify_vsx.lua"
-- Offline by default: classify() runs on the fixture package.json/files.txt pairs, and the
-- installer runs on the synthetic fixture.vsix archives under tests/fixtures/vsx/<id>/
-- (built by make_vsix.lua: the real package.json, a stub language server in place of the
-- real bundles; acme.generic-ls and acme.silent-ls are synthetic lsp-tier packages whose
-- server nvim-lspconfig does not know). The stub servers are really started by Neovim's
-- LSP client, so node must be on PATH.
-- LIVE group: set NVS_VSX_LIVE=1 to also search Open VSX and install the real Catppuccin
-- extension, which exercises download, the sha256 check and unpack over the network.
-- Every line printed starts with PASS or FAIL and is one line (details are collapsed:
-- tests/run.ps1 lists anything else as noise). Everything is written under the sandbox's
-- stdpath("data")/vsx and removed at the end; a 150 s watchdog exits if something hangs.
local out = {}
local fails = 0

-- Headless Neovim prints vim.notify to the terminal, which would break the one-line-per-check
-- output; keep the installer's messages here instead (checks may read them).
local notes = {}
vim.notify = function(msg, level)
  notes[#notes + 1] = { msg = tostring(msg), level = level }
end
local inspect = vim.inspect
local function check(name, ok, detail)
  if not ok then
    fails = fails + 1
  end
  local extra = ""
  if detail ~= nil then
    extra = "  (" .. (tostring(detail):gsub("%s*[\r\n]+%s*", " ")) .. ")"
  end
  table.insert(out, (ok and "PASS " or "FAIL ") .. name .. extra)
end
-- vim.inspect on one line, for details.
local function show(x)
  return inspect(x, { newline = " ", indent = "" })
end
local function finish(code)
  io.write(table.concat(out, "\n") .. "\n")
  io.flush()
  os.exit(code)
end
local watchdog = (vim.uv or vim.loop).new_timer()
watchdog:start(150000, 0, function()
  table.insert(out, "FAIL vsx: watchdog fired after 150 s")
  finish(4)
end)

-- Waits for an async function that takes a callback; returns done, plus the callback's arguments.
local function sync(fn, timeout)
  local done, args = false, nil
  fn(function(...)
    done = true
    args = { ... }
  end)
  vim.wait(timeout or 20000, function()
    return done
  end, 50)
  return done, args and args[1], args and args[2]
end

local function has(t, x)
  return vim.tbl_contains(t or {}, x)
end

local function starts_with_any(t, prefix)
  for _, s in ipairs(t or {}) do
    if tostring(s):sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy", modeline = false })
vim.wait(300)

local vsx = require("nvs.vsx")
local jsonc = require("nvs.jsonc")
local fx = vim.fs.normalize(vim.fn.getcwd() .. "/tests/fixtures/vsx")
local root = vsx.dir()
vim.fn.delete(root, "rf")
vsx.setup()

local changes = 0
vim.api.nvim_create_autocmd("User", {
  pattern = "NvsVsxChanged",
  callback = function()
    changes = changes + 1
  end,
})
local stages = {}
vsx.on_progress = function(id, stage, message)
  table.insert(stages, { id = id, stage = stage, message = message })
end
-- Stages for an id; before package.json is read install_file keys them by the file's base
-- name ("fixture" for the fixtures), so that name is accepted too.
local function stages_of(id)
  local list = {}
  for _, s in ipairs(stages) do
    if s.id == id or s.id == "fixture" then
      table.insert(list, s.stage)
    end
  end
  return list
end

local function fixture(id)
  local ok, pkg = jsonc.read(fx .. "/" .. id .. "/package.json")
  assert(ok, tostring(pkg))
  return pkg, vim.fn.readfile(fx .. "/" .. id .. "/files.txt")
end

---------------------------------------------------------------------------
-- classify() on the fixtures (pure)
---------------------------------------------------------------------------
local cat_pkg, cat_files = fixture("Catppuccin.catppuccin-vsc")
local c = vsx.classify(cat_pkg, cat_files)
check("classify: Catppuccin is t1", c.tier == "t1", c.tier .. ": " .. c.why)
check("classify: Catppuccin keeps its main", c.main == "dist/main.cjs", c.main)

local eslint_pkg, eslint_files = fixture("dbaeumer.vscode-eslint")
c = vsx.classify(eslint_pkg, eslint_files)
check("classify: vscode-eslint is lsp", c.tier == "lsp", c.tier .. ": " .. c.why)
check("classify: eslint server path", c.server and c.server.path == "server/out/eslintServer.js", c.server and c.server.path)
check("classify: eslint lspconfig name", c.server and c.server.lspconfig == "eslint", c.server and c.server.lspconfig)
check("classify: eslint main resolved to .js", c.main == "client/out/extension.js", c.main)

local yaml_pkg, yaml_files = fixture("redhat.vscode-yaml")
c = vsx.classify(yaml_pkg, yaml_files)
check("classify: vscode-yaml is lsp", c.tier == "lsp", c.tier .. ": " .. c.why)
check("classify: yaml server is dist/languageserver.js, not -web", c.server and c.server.path == "dist/languageserver.js", c.server and c.server.path)
check("classify: yaml lspconfig name", c.server and c.server.lspconfig == "yamlls", c.server and c.server.lspconfig)

local prettier_pkg, prettier_files = fixture("esbenp.prettier-vscode")
c = vsx.classify(prettier_pkg, prettier_files)
check("classify: prettier is t2", c.tier == "t2", c.tier .. ": " .. c.why)
check("classify: prettier main", c.main == "dist/extension.js", c.main)
check("classify: prettier's node_modules are ignored", c.server == nil)

c = vsx.classify(prettier_pkg, prettier_files, "function activate(){ vscode.window.createWebviewPanel('x') }")
check("classify: webview in the bundle makes it t3", c.tier == "t3", c.tier .. ": " .. c.why)

-- A server is found by the WORDS of a file name (docs/extensions.md step 2, "whose name
-- matches"), not by a substring: lib/observer.js, dist/elspeth.js and
-- out/serverless-helpers.js are helpers, and taking one for the server would put a t2
-- extension in the lsp tier with `node <helper> --stdio` spawned per buffer.
local function server_of(files)
  local r = vsx.classify({ name = "x", publisher = "y", main = "out/e.js" }, files)
  return r.server and r.server.path or "none", r.server and r.server.lspconfig or "-", r.tier
end
for _, helper in ipairs({ "lib/observer.js", "dist/elspeth.js", "out/serverless-helpers.js", "dist/lspClient.js", "out/languageServerClient.js", "dist/webserver.js" }) do
  local path, _, tier = server_of({ "out/e.js", helper })
  check("classify: " .. helper .. " is not a server (t2)", path == "none" and tier == "t2", path .. " " .. tier)
end
for _, srv in ipairs({ "dist/fooServer.js", "out/yaml-language-server.js", "out/LSPServer.js", "lib/langserver.mjs", "server/lsp.js", "bin/server.bundle.js", "dist/languageserver.js" }) do
  local path, _, tier = server_of({ "out/e.js", srv })
  check("classify: " .. srv .. " is a server (lsp)", path == srv and tier == "lsp", path .. " " .. tier)
end
local kpath, kcfg = server_of({ "out/e.js", "out/jsonServerMain.js" })
check("classify: out/jsonServerMain.js -> jsonls through KNOWN_SERVERS", kpath == "out/jsonServerMain.js" and kcfg == "jsonls", kpath .. " " .. kcfg)
local wpath = server_of({ "out/e.js", "dist/languageserver-web.js", "dist/server.worker.js", "dist/browserServer.js" })
check("classify: -web, .worker and browser server files are skipped", wpath == "none", wpath)

local t3_pkg = {
  name = "tree",
  publisher = "acme",
  main = "./out/extension.js",
  contributes = { views = { explorer = { { id = "acme.tree", name = "Acme" } } }, commands = { { command = "acme.go", title = "Go" } } },
}
c = vsx.classify(t3_pkg, { "package.json", "out/extension.js" })
check("classify: synthetic package with views is t3", c.tier == "t3", c.tier .. ": " .. c.why)

local snip_pkg, snip_files = fixture("nvs.snippets-fixture")
c = vsx.classify(snip_pkg, snip_files)
check("classify: snippets-only package is t1", c.tier == "t1", c.tier .. ": " .. c.why)

check("scheme_name: Catppuccin Mocha", vsx.scheme_name("Catppuccin Mocha") == "catppuccin-mocha", vsx.scheme_name("Catppuccin Mocha"))
check("scheme_name: punctuation collapses", vsx.scheme_name("One Dark Pro (Darker)") == "one-dark-pro-darker", vsx.scheme_name("One Dark Pro (Darker)"))
check("filetype_of: shellscript -> sh", vsx.filetype_of("shellscript") == "sh")
check("alternative: prettier -> conform", (vsx.alternative("esbenp.prettier-vscode") or ""):find("conform") ~= nil)

---------------------------------------------------------------------------
-- The checksum path, offline
---------------------------------------------------------------------------
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local sample = tmp .. "/sample.bin"
local f = assert(io.open(sample, "wb"))
f:write("nvs.ide checksum sample\n")
f:close()
local expected = vim.fn.sha256("nvs.ide checksum sample\n")
local done, err, hex = sync(function(cb)
  vsx.sha256_file(sample, cb)
end)
check("sha256_file matches vim.fn.sha256", done and err == nil and hex == expected, tostring(err or hex))
done, err, hex = sync(function(cb)
  vsx.verify_file(sample, expected, cb)
end)
check("verify_file accepts the right digest", done and err == nil and hex == expected, tostring(err))
done, err = sync(function(cb)
  vsx.verify_file(sample, ("0"):rep(64), cb)
end)
check("verify_file rejects a wrong digest", done and type(err) == "string" and err:find("checksum") ~= nil, tostring(err))

---------------------------------------------------------------------------
-- install_file: a bundled server (eslint), registered once nvim-lspconfig has loaded
---------------------------------------------------------------------------
local lazy_cfg = require("lazy.core.config")
local lspconfig_loaded_before = lazy_cfg.plugins["nvim-lspconfig"] and lazy_cfg.plugins["nvim-lspconfig"]._.loaded ~= nil
check("precondition: nvim-lspconfig not loaded at VeryLazy", not lspconfig_loaded_before)

local eslint_entry
done, err, eslint_entry = sync(function(cb)
  vsx.install_file(fx .. "/dbaeumer.vscode-eslint/fixture.vsix", cb)
end)
check("install_file eslint: no error", done and err == nil, tostring(err))
check("install_file eslint: tier lsp", eslint_entry and eslint_entry.tier == "lsp", eslint_entry and eslint_entry.tier)
check("install_file eslint: server recorded", eslint_entry and eslint_entry.server and eslint_entry.server.path == "server/out/eslintServer.js" and eslint_entry.server.lspconfig == "eslint" and eslint_entry.server.args[1] == "--stdio")
check("install_file eslint: waits for nvim-lspconfig before registering", not vim.lsp.is_enabled("vsx_vscode-eslint"))
require("lazy").load({ plugins = { "nvim-lspconfig" } })
vim.wait(3000, function()
  return vim.lsp.is_enabled("vsx_vscode-eslint")
end, 50)
check("precondition: lspconfig's eslint config is visible", vim.lsp.config.eslint ~= nil)
check("eslint: vim.lsp.config vsx_vscode-eslint enabled after lspconfig loaded", vim.lsp.is_enabled("vsx_vscode-eslint"))
local cfg = vim.lsp.config["vsx_vscode-eslint"]
check("eslint: cmd starts with node", cfg and type(cfg.cmd) == "table" and cfg.cmd[1] == "node", cfg and vim.inspect(cfg.cmd))
check("eslint: cmd runs the bundled server", cfg and type(cfg.cmd) == "table" and tostring(cfg.cmd[2]):find("server/out/eslintServer%.js$") ~= nil and cfg.cmd[2]:find(root, 1, true) == 1, cfg and cfg.cmd[2])
check("eslint: cmd ends with --stdio", cfg and type(cfg.cmd) == "table" and cfg.cmd[#cfg.cmd] == "--stdio")
check("eslint: filetypes include javascript (from lspconfig)", cfg and has(cfg.filetypes, "javascript"), cfg and vim.inspect(cfg.filetypes))
check("eslint: lspconfig settings reused", cfg and cfg.settings and cfg.settings.validate == "on" and type(cfg.root_dir) == "function")
check("eslint: languages recorded", eslint_entry and vim.deep_equal(eslint_entry.languages, { "ignore", "jsonc" }), eslint_entry and vim.inspect(eslint_entry.languages))
check("eslint: .eslintignore gets a filetype rule", (vim.filetype.match({ filename = ".eslintignore" })) == "gitignore" and has(eslint_entry.converted.filetypes, "gitignore"), vim.inspect(eslint_entry and eslint_entry.converted.filetypes))
check("eslint: alternative is nvim-lint", eslint_entry and tostring(eslint_entry.alt):find("nvim%-lint") ~= nil, eslint_entry and eslint_entry.alt)
check("eslint: commands noted as not available", starts_with_any(eslint_entry and eslint_entry.converted.skipped, "commands:"), vim.inspect(eslint_entry and eslint_entry.converted.skipped))

---------------------------------------------------------------------------
-- install_file: a theme (Catppuccin)
---------------------------------------------------------------------------
local cat_id = "Catppuccin.catppuccin-vsc"
local cat_entry
stages = {}
done, err, cat_entry = sync(function(cb)
  vsx.install_file(fx .. "/Catppuccin.catppuccin-vsc/fixture.vsix", cb)
end)
check("install_file catppuccin: no error", done and err == nil, tostring(err))
check("install_file catppuccin: progress unpack, convert, done", vim.deep_equal(stages_of(cat_id), { "unpack", "convert", "done" }), vim.inspect(stages_of(cat_id)))
check("install_file catppuccin: extensions/<id>/ created", vim.fn.filereadable(root .. "/extensions/" .. cat_id .. "/package.json") == 1)
check("install_file catppuccin: theme files unpacked", vim.fn.filereadable(root .. "/extensions/" .. cat_id .. "/themes/mocha.json") == 1)
local ok_json, saved = jsonc.read(root .. "/vsx.json")
check("vsx.json written", ok_json and type(saved) == "table" and saved.version == 1 and #saved.extensions == 2, ok_json and vim.inspect(saved and saved.version) or tostring(saved))
local rec
for _, e in ipairs(ok_json and saved.extensions or {}) do
  if e.id == cat_id then
    rec = e
  end
end
check("vsx.json: identity fields", rec and rec.namespace == "Catppuccin" and rec.name == "catppuccin-vsc" and rec.version == "3.19.0" and rec.displayName == "Catppuccin for VSCode" and rec.publisher == "Catppuccin" and rec.license == "MIT", rec and vim.inspect({ rec.namespace, rec.name, rec.version, rec.displayName, rec.publisher, rec.license }))
check("vsx.json: tier and why", rec and rec.tier == "t1" and type(rec.why) == "string" and rec.why:find("themes") ~= nil, rec and rec.why)
check("vsx.json: enabled, installed_at, bytes, main", rec and rec.enabled == true and tostring(rec.installed_at):match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil and type(rec.bytes) == "number" and rec.bytes > 1000 and rec.main == "dist/main.cjs", rec and vim.inspect({ rec.enabled, rec.installed_at, rec.bytes, rec.main }))
check("vsx.json: server is null for t1", rec and rec.server == vim.NIL)
check("vsx.json: activation and contributes", rec and vim.deep_equal(rec.activation, { "onStartupFinished" }) and #rec.contributes.themes == 4 and rec.contributes.themes[1] == "Catppuccin Mocha" and rec.contributes.snippets == 0, rec and vim.inspect(rec.contributes))
check("vsx.json: converted has colors, filetypes, snippets, skipped", rec and type(rec.converted) == "table" and type(rec.converted.colors) == "table" and type(rec.converted.filetypes) == "table" and rec.converted.snippets == false and type(rec.converted.skipped) == "table")
check("vsx.json: alt is null when unknown", rec and rec.alt == vim.NIL)
-- Where the vsx folder sits on 'runtimepath': the contract says PREPEND, so a converted
-- scheme wins over a plugin's colors/ file of the same name.
local function rtp_pos()
  local rtp = vim.opt.runtimepath:get()
  for i, p in ipairs(rtp) do
    if vim.fs.normalize(p):lower() == vim.fs.normalize(root):lower() then
      return i, #rtp
    end
  end
  return nil, #rtp
end
local pos, count = rtp_pos()
check("vsx folder is FIRST on runtimepath (prepended)", pos == 1, ("position %s of %d"):format(tostring(pos), count))
-- lazy.nvim rebuilds 'runtimepath' from existing folders when it loads a plugin; the vsx
-- folder must survive that (it exists now), or converted schemes would vanish from :colorscheme.
local was_loaded = lazy_cfg.plugins["grug-far.nvim"] and lazy_cfg.plugins["grug-far.nvim"]._.loaded ~= nil
require("lazy").load({ plugins = { "grug-far.nvim" } })
check("precondition: grug-far was not loaded before (so the load really rebuilt rtp)", was_loaded == false)
pos, count = rtp_pos()
check("vsx folder survives a lazy.nvim plugin load, still first", pos == 1, ("position %s of %d"):format(tostring(pos), count))
local have_converter = pcall(require, "nvs.vsx_theme")
if have_converter then
  check("themes converted: colors/catppuccin-mocha.lua exists", vim.fn.filereadable(root .. "/colors/catppuccin-mocha.lua") == 1 and has(cat_entry.converted.colors, "catppuccin-mocha"), vim.inspect(cat_entry.converted))
  check("themes converted: scheme completes for :colorscheme", has(vim.fn.getcompletion("catppuccin-mo", "color"), "catppuccin-mocha"), vim.inspect(vim.fn.getcompletion("catppuccin", "color")))
  check("themes converted: missing theme files are reported, not fatal", starts_with_any(cat_entry.converted.skipped, "theme Catppuccin Macchiato: cannot read"), vim.inspect(cat_entry.converted.skipped))
  local rep = cat_entry.converted.reports and cat_entry.converted.reports["catppuccin-mocha"]
  check("themes converted: report counts kept", rep and rep.colors > 10 and rep.tokens > 0, vim.inspect(rep))
  -- The case the contract names: LazyVim ships catppuccin.nvim, whose colors/catppuccin-mocha.lua
  -- shadows the installed theme when the vsx folder is appended instead of prepended. Load the
  -- plugin (what happens once anyone picks or previews it) and see which file :colorscheme sources.
  local cat_plugin = lazy_cfg.plugins["catppuccin"]
  check("precondition: catppuccin.nvim not loaded before", cat_plugin ~= nil and cat_plugin._.loaded == nil)
  local converted = root .. "/colors/catppuccin-mocha.lua"
  local mf = assert(io.open(converted, "ab"))
  mf:write("\nvim.g.nvs_vsx_test_sourced = 'vsx'\n")
  mf:close()
  require("lazy").load({ plugins = { "catppuccin" } })
  local found = vim.api.nvim_get_runtime_file("colors/catppuccin-mocha.lua", true)
  check("themes: with catppuccin.nvim loaded, the installed scheme is found first", #found >= 2 and vim.fs.normalize(found[1]):lower() == vim.fs.normalize(converted):lower(), show(found))
  pos, count = rtp_pos()
  check("vsx folder still first after catppuccin.nvim loaded", pos == 1, ("position %s of %d"):format(tostring(pos), count))
  vim.g.nvs_vsx_test_sourced = "none"
  local cok, cerr = pcall(vim.cmd.colorscheme, "catppuccin-mocha")
  check("themes: :colorscheme catppuccin-mocha sources the installed theme, not the plugin's", cok and vim.g.nvs_vsx_test_sourced == "vsx", cok and ("sourced: " .. tostring(vim.g.nvs_vsx_test_sourced)) or tostring(cerr))
else
  check("themes not converted yet: skipped says so", starts_with_any(cat_entry.converted.skipped, "themes:"), vim.inspect(cat_entry.converted.skipped))
end
check("list() has both entries", #vsx.list() == 2)

done, err = sync(function(cb)
  vsx.install_file(fx .. "/Catppuccin.catppuccin-vsc/fixture.vsix", cb)
end)
check("re-install replaces the folder", done and err == nil and vim.fn.isdirectory(root .. "/extensions/" .. cat_id) == 1 and vim.fn.isdirectory(root .. "/extensions/" .. cat_id .. ".old") == 0 and #vsx.list() == 2, tostring(err))

---------------------------------------------------------------------------
-- install_file: a bundled server that really starts (yaml, stub server)
---------------------------------------------------------------------------
local yaml_entry
done, err, yaml_entry = sync(function(cb)
  vsx.install_file(fx .. "/redhat.vscode-yaml/fixture.vsix", cb)
end)
check("install_file yaml: no error", done and err == nil, tostring(err))
check("install_file yaml: lsp with yamlls", yaml_entry and yaml_entry.tier == "lsp" and yaml_entry.server.lspconfig == "yamlls" and yaml_entry.server.path == "dist/languageserver.js", yaml_entry and vim.inspect(yaml_entry.server))
cfg = vim.lsp.config["vsx_vscode-yaml"]
check("yaml: config enabled with node cmd", vim.lsp.is_enabled("vsx_vscode-yaml") and cfg and cfg.cmd[1] == "node" and tostring(cfg.cmd[2]):find("dist/languageserver%.js$") ~= nil and cfg.cmd[3] == "--stdio", cfg and vim.inspect(cfg.cmd))
check("yaml: filetypes and settings from lspconfig", cfg and has(cfg.filetypes, "yaml") and vim.tbl_get(cfg, "settings", "redhat", "telemetry", "enabled") == false, cfg and vim.inspect(cfg.filetypes))
check("yaml: l10n bundle passed as VS Code's client does", cfg and tostring(vim.tbl_get(cfg, "init_options", "l10nPath")):find("redhat%.vscode%-yaml/dist/l10n$") ~= nil and tostring(vim.tbl_get(cfg, "cmd_env", "VSCODE_L10N_BUNDLE_LOCATION")):match("^file:///.*bundle%.l10n%.json$") ~= nil and yaml_entry.l10n == "dist/l10n", cfg and vim.inspect({ cfg.init_options, cfg.cmd_env }))
check("yaml: x.eyaml is yaml", (vim.filetype.match({ filename = "x.eyaml" })) == "yaml")
check("yaml: x.eyml (unknown to Neovim) is yaml through the new rule", (vim.filetype.match({ filename = "x.eyml" })) == "yaml" and has(yaml_entry.converted.filetypes, "yaml"), vim.inspect(yaml_entry and yaml_entry.converted.filetypes))
check("yaml: rules Neovim already had are counted, not clobbered", starts_with_any(yaml_entry.converted.skipped, "languages:"), vim.inspect(yaml_entry.converted.skipped))

local probe = tmp .. "/probe.yaml"
vim.cmd.edit(vim.fn.fnameescape(probe))
local buf = vim.api.nvim_get_current_buf()
check("yaml: probe buffer has filetype yaml", vim.bo[buf].filetype == "yaml", vim.bo[buf].filetype)
local client
vim.wait(15000, function()
  client = vim.lsp.get_clients({ name = "vsx_vscode-yaml", bufnr = buf })[1]
  return client ~= nil and client.initialized == true
end, 100)
check("yaml: bundled server started with node and attached", client ~= nil and client.initialized == true and client.server_info and client.server_info.name == "nvs-stub-server", client and vim.inspect(client.server_info))

vsx.set_enabled("redhat.vscode-yaml", false)
check("set_enabled false: config disabled", not vim.lsp.is_enabled("vsx_vscode-yaml"))
vim.wait(8000, function()
  return #vim.lsp.get_clients({ name = "vsx_vscode-yaml" }) == 0
end, 100)
check("set_enabled false: client stopped", #vim.lsp.get_clients({ name = "vsx_vscode-yaml" }) == 0)
ok_json, saved = jsonc.read(root .. "/vsx.json")
local yrec
for _, e in ipairs(ok_json and saved.extensions or {}) do
  if e.id == "redhat.vscode-yaml" then
    yrec = e
  end
end
check("set_enabled false: saved in vsx.json", yrec and yrec.enabled == false)
vsx.set_enabled("redhat.vscode-yaml", true)
check("set_enabled true: config enabled again", vim.lsp.is_enabled("vsx_vscode-yaml"))
-- The probe buffer is still open: the contract says already-open matching buffers get the client.
client = nil
vim.wait(15000, function()
  client = vim.lsp.get_clients({ name = "vsx_vscode-yaml", bufnr = buf })[1]
  return client ~= nil and client.initialized == true
end, 100)
check("set_enabled true: attaches to the already-open yaml buffer", client ~= nil and client.initialized == true)
vim.cmd("bdelete! " .. buf)
vim.wait(2000, function()
  return #vim.lsp.get_clients({ name = "vsx_vscode-yaml" }) == 0
end, 100)

---------------------------------------------------------------------------
-- install_file: a bundled server nvim-lspconfig does not know
---------------------------------------------------------------------------
-- acme.generic-ls activates on onStartupFinished and contributes the language "acme": its
-- server is for .acme files, never for every buffer (that is the extension host's rule).
-- acme.silent-ls declares no language at all, so it cannot be enabled and the entry says why.
local gen_entry
done, err, gen_entry = sync(function(cb)
  vsx.install_file(fx .. "/acme.generic-ls/fixture.vsix", cb)
end)
check("install_file generic-ls: lsp tier with a server nvim-lspconfig does not know", done and err == nil and gen_entry.tier == "lsp" and gen_entry.server.path == "dist/server.js" and gen_entry.server.lspconfig == nil, tostring(err or (gen_entry and show(gen_entry.server))))
cfg = vim.lsp.config["vsx_generic-ls"]
check("generic-ls: filetypes from contributes.languages, not every filetype", cfg and vim.deep_equal(cfg.filetypes, { "acme" }), cfg and show(cfg.filetypes))
check("generic-ls: enabled, no error", vim.lsp.is_enabled("vsx_generic-ls") and gen_entry.error == nil, tostring(gen_entry and gen_entry.error))
check("generic-ls: x.acme gets filetype acme", (vim.filetype.match({ filename = "x.acme" })) == "acme")
local lua_probe = tmp .. "/probe.lua"
vim.cmd.edit(vim.fn.fnameescape(lua_probe))
local lua_buf = vim.api.nvim_get_current_buf()
vim.wait(700)
check("generic-ls: does not attach to a .lua buffer", vim.bo[lua_buf].filetype == "lua" and #vim.lsp.get_clients({ name = "vsx_generic-ls", bufnr = lua_buf }) == 0 and #vim.lsp.get_clients({ name = "vsx_generic-ls" }) == 0, show(vim.tbl_map(function(c2)
  return c2.name
end, vim.lsp.get_clients({ bufnr = lua_buf }))))
vim.cmd("bdelete! " .. lua_buf)
local acme_probe = tmp .. "/probe.acme"
vim.cmd.edit(vim.fn.fnameescape(acme_probe))
local acme_buf = vim.api.nvim_get_current_buf()
check("generic-ls: probe buffer has filetype acme", vim.bo[acme_buf].filetype == "acme", vim.bo[acme_buf].filetype)
client = nil
vim.wait(15000, function()
  client = vim.lsp.get_clients({ name = "vsx_generic-ls", bufnr = acme_buf })[1]
  return client ~= nil and client.initialized == true
end, 100)
check("generic-ls: bundled server started and attached to the .acme buffer", client ~= nil and client.initialized == true and client.server_info and client.server_info.name == "nvs-stub-server", client and show(client.server_info))
vim.cmd("bdelete! " .. acme_buf)

local silent_entry
done, err, silent_entry = sync(function(cb)
  vsx.install_file(fx .. "/acme.silent-ls/fixture.vsix", cb)
end)
check("install_file silent-ls: installs as lsp without error", done and err == nil and silent_entry.tier == "lsp" and silent_entry.server.path == "dist/server.js", tostring(err))
check("silent-ls: config registered but NOT enabled (no language declared)", vim.lsp.config["vsx_silent-ls"] ~= nil and vim.lsp.config["vsx_silent-ls"].filetypes == nil and not vim.lsp.is_enabled("vsx_silent-ls"))
check("silent-ls: entry.error says why", type(silent_entry.error) == "string" and silent_entry.error:find("declares no languages", 1, true) ~= nil and silent_entry.error:find("dist/server.js", 1, true) ~= nil, tostring(silent_entry.error))
vsx.set_enabled("acme.silent-ls", true)
check("silent-ls: set_enabled true still does not enable it", not vim.lsp.is_enabled("vsx_silent-ls") and type(silent_entry.error) == "string")

---------------------------------------------------------------------------
-- install_file: snippets
---------------------------------------------------------------------------
local snip_entry
done, err, snip_entry = sync(function(cb)
  vsx.install_file(fx .. "/nvs.snippets-fixture/fixture.vsix", cb)
end)
local snip_dir = vim.fs.normalize(root .. "/extensions/nvs.snippets-fixture")
check("install_file snippets: t1 with snippets", done and err == nil and snip_entry.tier == "t1" and snip_entry.converted.snippets == true, tostring(err))
check("snippets: folder added to vim.g.nvs_vsx_snippet_paths", has(vim.g.nvs_vsx_snippet_paths, snip_dir), vim.inspect(vim.g.nvs_vsx_snippet_paths))
check("snippets: restart noted, grammars skipped", starts_with_any(snip_entry.converted.skipped, "snippets:") and starts_with_any(snip_entry.converted.skipped, "grammars:"), vim.inspect(snip_entry.converted.skipped))
vsx.set_enabled("nvs.snippets-fixture", false)
check("snippets: disabled folder leaves the snippet paths", not has(vim.g.nvs_vsx_snippet_paths, snip_dir))
vsx.set_enabled("nvs.snippets-fixture", true)
check("snippets: enabled folder returns", has(vim.g.nvs_vsx_snippet_paths, snip_dir))

---------------------------------------------------------------------------
-- install_file: t2 (prettier) and the extension host config shape
---------------------------------------------------------------------------
local pr_entry
done, err, pr_entry = sync(function(cb)
  vsx.install_file(fx .. "/esbenp.prettier-vscode/fixture.vsix", cb)
end)
check("install_file prettier: t2", done and err == nil and pr_entry.tier == "t2", tostring(err))
cfg = vim.lsp.config["vsx_prettier-vscode"]
local want_cmd = {
  "node",
  vim.fn.stdpath("config") .. "/exthost/host.js",
  "--extension",
  root .. "/extensions/esbenp.prettier-vscode",
  "--data",
  root,
  "--log",
  root .. "/logs/esbenp.prettier-vscode.log",
  "--stdio",
}
check("t2: host cmd exactly as the contract says", cfg and vim.deep_equal(cfg.cmd, want_cmd), cfg and vim.inspect(cfg.cmd))
check("t2: every filetype for onStartupFinished", cfg and cfg.filetypes == nil, cfg and vim.inspect(cfg.filetypes))
-- The host itself is runtime/exthost/host.js; the config is enabled only when it is there.
local host_present = vim.fn.filereadable(vim.fn.stdpath("config") .. "/exthost/host.js") == 1
if host_present then
  check("t2: enabled on demand (host.js present)", vim.lsp.is_enabled("vsx_prettier-vscode") and pr_entry.error == nil, tostring(pr_entry.error))
else
  check("t2: not enabled while host.js is missing, and the entry says so", not vim.lsp.is_enabled("vsx_prettier-vscode") and tostring(pr_entry.error):find("extension host") ~= nil, tostring(pr_entry.error))
end
check("t2: alternative is conform.nvim", tostring(pr_entry.alt):find("conform") ~= nil, pr_entry.alt)
check("t2: languages -> filetypes (graphql already known, so none new)", vim.deep_equal(pr_entry.languages, { "json", "ignore", "graphql", "vue", "handlebars" }), vim.inspect(pr_entry.languages))
vim.wait(3000, function()
  return vsx.status().node_version ~= nil
end, 50)
local st = vsx.status()
check("status(): host and registry", st.host.mode == "demand" and st.host.extensions == 1 and st.host.running == false and st.host.node == "node" and st.registry == "https://open-vsx.org", vim.inspect(st))
check("status(): node_version probed", type(st.node_version) == "string" and st.node_version:match("^v%d+") ~= nil, tostring(st.node_version))
vsx.apply_host_mode("never")
check("apply_host_mode never: t2 config disabled", not vim.lsp.is_enabled("vsx_prettier-vscode"))
vsx.apply_host_mode("demand")
check("apply_host_mode demand: t2 config enabled when the host can run", vim.lsp.is_enabled("vsx_prettier-vscode") == host_present)
check("NvsVsxChanged fired on state changes", changes >= 8, tostring(changes))

c = vsx.classify({ name = "x", publisher = "y", main = "out/ext.js" }, { "out/ext.js" })
check("classify: plain main is t2", c.tier == "t2")

---------------------------------------------------------------------------
-- Errors are sentences
---------------------------------------------------------------------------
local junk = tmp .. "/junk.vsix"
f = assert(io.open(junk, "wb"))
f:write("this is not a zip\n")
f:close()
done, err = sync(function(cb)
  vsx.install_file(junk, cb)
end)
check("install_file on a non-archive fails with a sentence", done and type(err) == "string" and err:find("unpack") ~= nil, tostring(err))
done, err = sync(function(cb)
  vsx.install_file(tmp .. "/missing.vsix", cb)
end)
check("install_file on a missing file fails with a sentence", done and type(err) == "string" and err:find("no file") ~= nil, tostring(err))
local okr, why = vsx.uninstall("nobody.nothing")
check("uninstall of an unknown id says so", okr == false and tostring(why):find("not installed") ~= nil, tostring(why))

-- install(id) passes the registry id as opts.id. The folder and the entry follow
-- package.json; an archive that names another publisher.name is refused, and a typed id
-- that differs only in case installs under the package's own spelling.
local entries_before = #vsx.list()
stages = {}
done, err = sync(function(cb)
  vsx.install_file(fx .. "/Catppuccin.catppuccin-vsc/fixture.vsix", cb, { id = "someone.else" })
end)
check("install_file with a mismatching opts.id fails with a sentence", done and type(err) == "string" and err:find("Catppuccin.catppuccin-vsc", 1, true) ~= nil and err:find("someone.else", 1, true) ~= nil, tostring(err))
check("install_file with a mismatching opts.id creates no folder and no entry", not has(vim.fn.readdir(root .. "/extensions"), "someone.else") and #vsx.list() == entries_before and #vim.fn.glob(root .. "/downloads/*", false, true) == 0, show(vim.fn.readdir(root .. "/extensions")))
check("install_file with a mismatching opts.id reports error under that id", stages[#stages] and stages[#stages].id == "someone.else" and stages[#stages].stage == "error", show(stages))
check("install_file with a mismatching opts.id leaves the installed Catppuccin alone", vim.fn.filereadable(root .. "/extensions/" .. cat_id .. "/package.json") == 1 and vim.lsp.is_enabled("vsx_vscode-eslint"))
local typed = "catppuccin.CATPPUCCIN-VSC"
stages = {}
local typed_entry
done, err, typed_entry = sync(function(cb)
  vsx.install_file(fx .. "/Catppuccin.catppuccin-vsc/fixture.vsix", cb, { id = typed })
end)
local dup = 0
for _, e in ipairs(vsx.list()) do
  if e.id:lower() == cat_id:lower() then
    dup = dup + 1
  end
end
check("install_file with a differently-cased opts.id installs under package.json's id", done and err == nil and typed_entry.id == cat_id and typed_entry.namespace == "Catppuccin" and has(vim.fn.readdir(root .. "/extensions"), cat_id) and dup == 1 and #vsx.list() == entries_before, tostring(err or (typed_entry and typed_entry.id)) .. " " .. show(vim.fn.readdir(root .. "/extensions")))
check("install_file keeps progress keyed by the id the caller asked for", vim.deep_equal(stages_of(typed), { "unpack", "convert", "done" }), show(stages))

---------------------------------------------------------------------------
-- uninstall removes everything
---------------------------------------------------------------------------
for _, id in ipairs({ cat_id, "dbaeumer.vscode-eslint", "redhat.vscode-yaml", "acme.generic-ls", "acme.silent-ls", "nvs.snippets-fixture", "esbenp.prettier-vscode" }) do
  local u = vsx.uninstall(id)
  check("uninstall " .. id, u == true)
end
vim.wait(3000, function()
  return vim.fn.isdirectory(root .. "/extensions/" .. cat_id) == 0 and vim.fn.isdirectory(root .. "/extensions/redhat.vscode-yaml") == 0 and vim.fn.isdirectory(root .. "/extensions/acme.generic-ls") == 0
end, 100)
check("uninstall: folders removed", vim.fn.isdirectory(root .. "/extensions/" .. cat_id) == 0 and vim.fn.isdirectory(root .. "/extensions/dbaeumer.vscode-eslint") == 0 and vim.fn.isdirectory(root .. "/extensions/redhat.vscode-yaml") == 0 and vim.fn.isdirectory(root .. "/extensions/esbenp.prettier-vscode") == 0 and vim.fn.isdirectory(root .. "/extensions/acme.generic-ls") == 0 and vim.fn.isdirectory(root .. "/extensions/acme.silent-ls") == 0, show(vim.fn.readdir(root .. "/extensions")))
check("uninstall: converted colours removed", vim.fn.filereadable(root .. "/colors/catppuccin-mocha.lua") == 0)
ok_json, saved = jsonc.read(root .. "/vsx.json")
check("uninstall: vsx.json empty", ok_json and #saved.extensions == 0 and #vsx.list() == 0)
check("uninstall: LSP configs disabled", not vim.lsp.is_enabled("vsx_vscode-eslint") and not vim.lsp.is_enabled("vsx_vscode-yaml") and not vim.lsp.is_enabled("vsx_prettier-vscode") and not vim.lsp.is_enabled("vsx_generic-ls") and not vim.lsp.is_enabled("vsx_silent-ls"))
check("uninstall: snippet paths empty", #(vim.g.nvs_vsx_snippet_paths or {}) == 0)

---------------------------------------------------------------------------
-- LIVE: the real registry (NVS_VSX_LIVE=1)
---------------------------------------------------------------------------
if vim.env.NVS_VSX_LIVE == "1" then
  local results
  done, err, results = sync(function(cb)
    vsx.search("catppuccin", cb)
  end, 60000)
  check("live search: no error", done and err == nil, tostring(err))
  local hit
  for _, r in ipairs(results or {}) do
    if r.id == cat_id then
      hit = r
    end
  end
  check("live search: Catppuccin found with the contract's fields", hit ~= nil and hit.namespace == "Catppuccin" and hit.name == "catppuccin-vsc" and type(hit.version) == "string" and hit.downloads > 0 and hit.installed == false and type(hit.displayName) == "string", hit and vim.inspect(hit) or vim.inspect(results))
  stages = {}
  local live_entry
  done, err, live_entry = sync(function(cb)
    vsx.install(cat_id, cb)
  end, 120000)
  check("live install: no error", done and err == nil, tostring(err))
  check("live install: t1 entry", live_entry and live_entry.tier == "t1" and live_entry.id == cat_id, live_entry and live_entry.tier)
  check("live install: sha256 verified and recorded", live_entry and type(live_entry.sha256) == "string" and #live_entry.sha256 == 64, live_entry and tostring(live_entry.sha256))
  local seen = stages_of(cat_id)
  check("live install: stages download, verify, unpack, convert, done", has(seen, "download") and has(seen, "verify") and has(seen, "unpack") and has(seen, "convert") and seen[#seen] == "done", vim.inspect(seen))
  local matched = false
  for _, s in ipairs(stages) do
    if s.stage == "verify" and s.message:find("Checksum matches") then
      matched = true
    end
  end
  check("live install: the verify stage reported a matching checksum", matched)
  check("live install: download removed afterwards", #vim.fn.glob(root .. "/downloads/*.vsix", false, true) == 0)
  check("live install: unpacked", vim.fn.filereadable(root .. "/extensions/" .. cat_id .. "/themes/mocha.json") == 1)
  done, err = sync(function(cb)
    vsx.info("nobody.nothing-here-xyz", cb)
  end, 60000)
  check("live info: unknown id is a sentence", done and type(err) == "string" and err:find("not on the registry") ~= nil, tostring(err))
  vsx.uninstall(cat_id)
end

local msgs = vim.api.nvim_exec2("messages", { output = true }).output
check("no errors in :messages", not msgs:find("E%d+:") and not msgs:find("quit with exit code"), msgs:sub(1, 300))

vim.wait(1500, function()
  return vim.fn.isdirectory(root .. "/extensions/nvs.snippets-fixture") == 0
end, 100)
vim.fn.delete(root, "rf")
vim.fn.delete(tmp, "rf")
finish(fails > 0 and 1 or 0)
