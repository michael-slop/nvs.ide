# VS Code extensions in nvs.ide

nvs.ide installs extensions from [Open VSX](https://open-vsx.org), the open
registry VSCodium uses. Neovim cannot run VS Code extensions as they are, so
each one is sorted into a tier at install time and handled the way that tier
allows. Every tier is a real path that works today, and the Plugins screen
says which tier an extension landed in and why.

This file is the contract between the parts: the registry client
(`runtime/lua/nvs/vsx.lua`), the theme converter (`runtime/lua/nvs/vsx_theme.lua`),
the extension host (`runtime/exthost/`), the bridge (`runtime/lua/nvs/bridge.lua`)
and the window (`shell/src/workbench/plugins.rs`).

## Tiers

| Tier | What the extension is | How nvs.ide runs it |
|---|---|---|
| `t1` | Declarative: colour themes, snippets, language ids, grammars. Has no code that matters, even if `package.json` names a `main` (theme packs often ship one for a settings command). | Converted at install time. Themes become Neovim colour schemes, snippets are given to blink.cmp as they are, language ids become filetype rules. Grammars are skipped: Neovim highlights with tree-sitter. Nothing runs afterwards. |
| `lsp` | A language-server client that ships its server (ESLint, YAML, most "X language support" extensions). | The bundled server is started by Neovim's own LSP client with `node <server> --stdio`. The extension's client code never runs. When nvim-lspconfig knows the server (by its file name), its settings and root detection are reused. |
| `t2` | Code that registers providers or commands through the `vscode` API (formatters, completions, hovers, commands). | Runs in the extension host, a Node program that loads the extension with a `vscode` shim and speaks LSP to Neovim over stdio. To Neovim it is one more language server. The host runs only while a `t2` extension is enabled (setting `exthost`: on demand, always, never). |
| `t3` | Needs webviews, custom editors, tree views or notebooks. | Not supported. Listed so the person knows why, with the Neovim-native alternative when one is known. |

### Classification (`vsx.classify(pkg, files, main_text?)`), in this order

`pkg` is the parsed `extension/package.json`; `files` the list of paths inside
`extension/`; `main_text` the text of the main bundle when the caller has read
it (`install_file` does), used only by the webview check. The function is pure
and unit-tested with fixtures.

1. `t3` if `contributes` has any of `viewsContainers`, `views`, `customEditors`,
   `notebooks`, `notebookRenderer`, `walkthroughs`, or the main bundle's text
   contains `createWebviewPanel` or `registerWebviewViewProvider`.
2. `lsp` if a bundled server is found: a file under `server/`, `dist/`, `out/`,
   `lib/` or `bin/` (depth at most 4, never under `node_modules`) whose name
   matches `server`, `languageserver`, `language-server`, `lsp` or `langserver`
   and ends in `.js` or `.mjs`; prefer the shortest path, and among equals the
   one whose name contains `server`. Skip `*-web.js`, `*browser*`, `*.worker.js`.
   A name in `KNOWN_SERVERS` decides directly:
   `eslintServer.js -> eslint`, `languageserver.js` in `redhat.vscode-yaml` ->
   `yamlls`, `jsonServerMain.js -> jsonls`, `htmlServerMain.js -> html`,
   `cssServerMain.js -> cssls`, `pyright-langserver` or `server.bundle.js` in
   `ms-pyright.pyright -> pyright`, `tailwindServer.js -> tailwindcss`,
   `astro-ls`, `svelte-language-server -> svelte`, `lua-language-server` (a
   native binary, not js, run as is). The value is the nvim-lspconfig name
   whose `settings`, `filetypes` and `root_markers` are reused when that
   config exists in the running Neovim (`vim.lsp.config[name]` is non-nil).
3. `t1` if `contributes` has `themes`, `iconThemes`, `snippets`, `grammars` or
   `languages` and has none of `commands` with a corresponding `main` that does
   more than configuration, judged as: no `main`, or `categories` contains
   `Themes` or `Snippets`, or the only `contributes` keys are in
   `{themes, iconThemes, snippets, grammars, languages, configuration,
   configurationDefaults, jsonValidation, keybindings, colors, semanticTokenScopes}`.
4. `t2` otherwise (there is a `main` or `browser` entry).

`extensionKind`, `engines.vscode` and `extensionDependencies` are recorded but
do not change the tier. An extension can be `t1` for its themes and still have
its snippets and languages installed: the converters run for every `t1`
contribution regardless of the tier the code landed in (an `lsp` extension's
`languages` still add filetypes; a `t2` extension's snippets still load).

## Storage

`stdpath("data")/vsx/` (`%LOCALAPPDATA%\nvs-ide-data\vsx\` on Windows, `~/.local/share/nvs-ide/vsx/` on Linux):

```
vsx.json                   the installed registry (below)
extensions/<ns>.<name>/    the unpacked vsix `extension/` folder, as shipped
colors/<scheme>.lua        converted themes; the vsx folder is on 'runtimepath'
logs/<ns>.<name>.log       the extension host's log for that extension
downloads/                 .vsix files while installing; removed afterwards
```

`vsx.json`:

```json
{ "version": 1, "extensions": [ {
  "id": "esbenp.prettier-vscode", "namespace": "esbenp", "name": "prettier-vscode",
  "version": "12.4.0", "displayName": "Prettier - Code formatter",
  "description": "...", "publisher": "esbenp", "license": "MIT",
  "tier": "t2", "why": "registers providers through the vscode API",
  "enabled": true, "installed_at": "2026-09-25T12:00:00Z", "bytes": 3644000,
  "main": "dist/extension.js",
  "server": null,
  "activation": ["onStartupFinished"],
  "languages": ["json", "ignore", "graphql", "vue", "handlebars"],
  "contributes": { "themes": ["Catppuccin Mocha"], "snippets": 2, "languages": 5, "grammars": 1, "commands": 4 },
  "converted": { "colors": ["catppuccin-mocha"], "filetypes": ["vue", "handlebars"], "snippets": true, "skipped": ["grammars: Neovim uses tree-sitter"] },
  "alt": "stevearc/conform.nvim"
} ] }
```

`server`, for the `lsp` tier: `{ "path": "server/out/eslintServer.js",
"lspconfig": "eslint", "args": ["--stdio"] }`. When `package.json` declares
`l10n` and `<dir>/<l10n>/bundle.l10n.json` exists, the config also passes
`init_options.l10nPath` and `cmd_env.VSCODE_L10N_BUNDLE_LOCATION`, as VS Code's
client does (the YAML server needs it).

`converted.filetypes` lists the Neovim filetype names that gained a rule from
`contributes.languages`; rules are added only for extensions and file names
Neovim does not already detect, and the ones it already knew are counted in
`converted.skipped`. `vim.filetype` has no way to remove a rule, so a disabled
or uninstalled extension's rules last until the next start.

`alt` comes from `vsx.ALTERNATIVES`, a table of extension ids to the Neovim
plugin that does the same job natively (prettier -> conform.nvim, eslint ->
nvim-lint, gitlens -> gitsigns.nvim, errorlens -> trouble.nvim, path
intellisense -> blink.cmp's path source, and so on). Unknown ids have `null`.

## Registry client (`runtime/lua/nvs/vsx.lua`)

All network work goes through `curl` with `vim.system` and a callback; nothing
blocks the editor. The registry base URL is the `openvsx` setting (default
`https://open-vsx.org`).

- `M.search(query, cb)`: `GET <base>/api/-/search?query=<q>&size=25&sortBy=relevance`;
  `cb(err, { { id, namespace, name, displayName, description, version,
  downloads, rating, timestamp, installed = bool } })`.
- `M.info(id, cb)`: `GET <base>/api/<ns>/<name>`; `cb(err, metadata)` with the
  fields the registry returns plus `files.download` and `files.sha256`.
- `M.install(id, cb)`: info, download the vsix to `downloads/`, fetch the
  `.sha256` file and compare (`certutil -hashfile` on Windows, `sha256sum`
  elsewhere; mismatch is an error and the file is removed), unpack with
  a zip reader (Windows' System32 `tar.exe` and macOS's `tar` are bsdtar; on
  Linux, whose `tar` is GNU tar and cannot read zip, `bsdtar` or `unzip`) into
  `extensions/<id>/` (replacing an older version, whose folder is renamed
  aside first and removed only after success), read `package.json`
  (JSONC-tolerant through `nvs.jsonc`), classify, run the converters, write
  `vsx.json`, apply the extension to the running session (below), send
  progress through `M.on_progress(id, stage, message)` for the stages
  `download`, `verify`, `unpack`, `convert`, `done`, `error`, and `cb(err,
  entry)`.
- `M.install_file(path_to_vsix, cb, opts?)`: the offline half of install (unpack,
  classify, convert, register, apply) so tests need no network; `opts = { id =
  registry id, digest = verified sha256 }` lets `install` keep its progress keyed
  by the registry id.
- `M.uninstall(id)`: remove the folder, its converted colours and log, drop
  it from `vsx.json`, stop its LSP client or host, notify.
- `M.set_enabled(id, on)`: keep the files, toggle `enabled`, apply or stop.
- `M.list()`: the `extensions` array from `vsx.json`.
- `M.status()`: `{ host = { running = bool, mode = "demand"|"always"|"never",
  node = "node"|path|nil, extensions = n }, registry = base, node_version = "v24.15.0"|nil }`.
- `M.setup()`, called from `nvs.setup()`: PREPEND the vsx folder to
  `runtimepath` (`vim.opt.runtimepath:prepend(vsxdir)`), so a converted scheme
  wins over a plugin's `colors/` file of the same name (LazyVim ships
  catppuccin.nvim, whose `colors/catppuccin-mocha.lua` would otherwise be
  sourced instead of the theme the person installed), register filetypes for every installed extension's
  `languages`, add every enabled extension folder that contributes snippets
  to `vim.g.nvs_vsx_snippet_paths` (read by `plugins/nvs.lua` into blink's
  `sources.providers.snippets.opts.search_paths`), and register LSP configs:
  for `lsp` entries `vim.lsp.config("vsx_" .. name, { cmd = { node, path, args... }, filetypes, root_markers })`
  merged over `vim.lsp.config[lspconfig]` when that exists, then
  `vim.lsp.enable(...)`; for `t2` entries with the host allowed,
  `vim.lsp.config("vsx_" .. name, { cmd = { node, <runtime>/exthost/host.js,
  "--extension", dir, "--data", vsxdir, "--log", logfile, "--stdio" },
  filetypes = from activation events and contributed languages, or every
  filetype for `onStartupFinished` / `*` })` and enable it.
- Apply after install without a restart where Neovim allows it: filetype
  rules and `runtimepath` take effect at once; a converted colour scheme can
  be chosen at once; LSP configs are enabled and attach to buffers opened from
  then on (and `vim.lsp.start` is called for already-open matching buffers);
  snippets need a restart (blink reads its paths once) and the entry says so.

Errors are plain sentences a person can act on: the registry was unreachable,
the checksum did not match, no zip reader or no `node` (with the command that
installs it), the extension needs webviews.

## Theme conversion (`runtime/lua/nvs/vsx_theme.lua`)

`M.convert(theme_path, scheme_name) -> lua_source, report` turns one VS Code
colour theme file into the source of a Neovim colour scheme file (the caller
writes it to `colors/<scheme_name>.lua`). `scheme_name` is the theme label
lower-cased with spaces and punctuation as `-` (`Catppuccin Mocha` ->
`catppuccin-mocha`). Themes are JSONC and may `include` another file; both are
handled. The generated file must:

- start with `vim.cmd("hi clear")`, set `vim.g.colors_name`, set
  `vim.o.background` from `type` (`dark`/`light`, `vs-dark`/`vs` in
  `uiTheme`), and end with nothing left undefined that Neovim's defaults would
  show in stock colours for the groups the necronomicon scheme defines
  (`runtime/colors/necronomicon.lua` is the list of groups to cover);
- map workbench `colors` keys to editor groups: at least `editor.background`,
  `editor.foreground`, `editorLineNumber.foreground`,
  `editorLineNumber.activeForeground`, `editorCursor.foreground`,
  `editor.selectionBackground`, `editor.lineHighlightBackground`,
  `editorWhitespace.foreground`, `editorIndentGuide.background`,
  `editorGutter.background`, `sideBar.background`, `statusBar.background`,
  `statusBar.foreground`, `tab.activeBackground`, `tab.inactiveBackground`,
  `editorWidget.background`, `editorSuggestWidget.*`, `list.activeSelectionBackground`,
  `editorError.foreground`, `editorWarning.foreground`, `editorInfo.foreground`,
  `editorHint.foreground`, `diffEditor.insertedTextBackground`,
  `diffEditor.removedTextBackground`, `editorBracketMatch.*`, `focusBorder`,
  `editorLink.activeForeground`, `terminal.ansi*` (to `vim.g.terminal_color_0..15`);
- map `tokenColors` TextMate scopes to syntax and tree-sitter groups:
  `comment -> Comment, @comment`, `keyword -> Keyword, @keyword` (with
  `keyword.control -> Conditional/Repeat/@keyword.conditional`,
  `keyword.operator -> Operator/@operator`), `string -> String, @string`,
  `constant.numeric -> Number/@number`, `constant.language -> Boolean/@boolean`,
  `constant -> Constant/@constant`, `entity.name.function -> Function/@function`,
  `support.function -> @function.builtin`, `entity.name.type`,
  `entity.name.class`, `support.type`, `support.class -> Type/@type`,
  `variable -> Identifier/@variable`, `variable.parameter -> @variable.parameter`,
  `entity.name.tag -> Tag/@tag`, `entity.other.attribute-name -> @tag.attribute`,
  `storage.type`, `storage.modifier -> Type/StorageClass/@keyword.type`,
  `punctuation -> Delimiter/@punctuation`, `markup.heading -> Title/@markup.heading`,
  `markup.bold -> @markup.strong`, `markup.italic -> @markup.italic`,
  `markup.underline.link -> Underlined/@markup.link.url`,
  `invalid -> Error`, `meta.diff.header`, `markup.inserted`, `markup.deleted`,
  `markup.changed -> DiffAdd/DiffDelete/DiffChange`; when several rules match
  a scope, the most specific (longest) scope wins, as in VS Code; `fontStyle`
  `bold`/`italic`/`underline` carry over;
- keep `semanticTokenColors` if present, mapped to `@lsp.type.*` groups;
- return a `report` with counts: colours mapped, token rules mapped, scopes
  it did not understand (listed), and warnings.

The converter is pure (reads files, returns text) and is unit-tested against
the Catppuccin themes. A converted scheme is loaded with `:colorscheme` like
any other and appears in the Settings screen's colour scheme list.

## The extension host (`runtime/exthost/`)

Plain JavaScript for Node 18 or newer, no npm dependencies, no build step:

```
host.js      entry: parses flags, starts the LSP transport, activates the extension
lsp.js       JSON-RPC over stdio with Content-Length framing; request/notify/handlers
vscode.js    the `vscode` module the extension requires: the API shim
documents.js the TextDocument store, kept in sync from textDocument/did* notifications
package.json { "name": "nvs-exthost", "private": true, "type": "commonjs" }
```

Started by Neovim as an LSP server:
`node host.js --extension <dir> --data <vsxdir> --log <file> [--settings <json-file>] --stdio`.

Startup order: read `<dir>/package.json`; install the `vscode` shim into
Node's module resolution (a `Module._resolveFilename` hook or an
`NODE_PATH`-free `require.cache` entry, so `require("vscode")` inside the
extension and its bundled dependencies returns the shim); on `initialize`
build the `ExtensionContext` (`subscriptions`, `extensionPath`, `extensionUri`,
`globalState`/`workspaceState` backed by JSON files under `<vsxdir>/state/`,
`globalStorageUri`, `logUri`, `extensionMode`), call `activate(context)`, and
answer with capabilities that reflect what the extension registered:
`documentFormattingProvider`, `documentRangeFormattingProvider`,
`completionProvider` (with trigger characters), `hoverProvider`,
`definitionProvider`, `referencesProvider`, `documentSymbolProvider`,
`codeActionProvider`, `renameProvider`, `signatureHelpProvider`, `executeCommandProvider`
(the commands registered through `vscode.commands.registerCommand`), and
`textDocumentSync` incremental. Providers registered after `initialize`
are announced with `client/registerCapability` (Neovim 0.10+ honours dynamic
registration for these methods), and unregistered on dispose.

Requests are routed to the matching provider by the document's language id
(`DocumentSelector` matching: string, `{ language, scheme, pattern }`, arrays)
and the results converted from `vscode` types to LSP types (`TextEdit`,
`CompletionItem`, `Hover` with `MarkdownString`, `Location`, `SymbolInformation`,
`CodeAction`, `WorkspaceEdit`). Diagnostics from `languages.createDiagnosticCollection`
go out as `textDocument/publishDiagnostics`. `window.showInformationMessage`,
`showWarningMessage`, `showErrorMessage` become `window/showMessage`
(`showMessageRequest` when they offer choices); `OutputChannel` text goes to
the log file and to `window/logMessage`; `StatusBarItem` text goes to
`window/logMessage` (there is no status bar to draw it in); progress becomes
`$/progress`. `workspace.getConfiguration(section)` answers from the
extension's `contributes.configuration` defaults overlaid with the
`--settings` file (nvs.ide writes the person's overrides there) and with
`workspace/configuration` from Neovim when the client supports it.
`workspace.workspaceFolders`, `rootPath`, `getWorkspaceFolder`, `asRelativePath`,
`findFiles` (a glob walk), `fs` (read, write, stat, readDirectory, delete,
createDirectory over the real file system), `openTextDocument`,
`textDocuments`, `onDid*` events, `createFileSystemWatcher` (fs.watch),
`env` (`appName = "nvs.ide"`, `appRoot`, `language`, `machineId`, `sessionId`,
`clipboard` via Neovim's `workspace/executeCommand`? no: unsupported, resolves
empty), `extensions.getExtension` (returns the extension itself and `undefined`
for others), `commands.executeCommand` (the extension's own commands and
`vscode.open`, `editor.action.formatDocument`, `setContext` as no-ops).

Every API member the shim does not implement logs `unsupported: vscode.<path>`
once to the log file and comes back as a phantom: a value that can be called,
awaited (it resolves to `undefined`), disposed, iterated (empty) and read further
(every property is another phantom), so `vscode.window.createTreeView(...).onDidChangeSelection(...)`
keeps running instead of throwing on the second step. A phantom is truthy, which an
extension testing for a feature's existence will take as support; the log names
each one, so the next person knows what to add.

Types implemented as real classes (the extension may `instanceof` them and
construct them): `Uri` (file, parse, joinPath, fsPath, toString, with),
`Position`, `Range`, `Selection`, `Location`, `TextEdit`, `WorkspaceEdit`,
`Diagnostic`, `DiagnosticSeverity`, `DiagnosticRelatedInformation`,
`CompletionItem`, `CompletionItemKind`, `CompletionList`, `SnippetString`,
`MarkdownString`, `Hover`, `SymbolInformation`, `DocumentSymbol`, `SymbolKind`,
`CodeAction`, `CodeActionKind`, `Command`, `Disposable`, `EventEmitter`,
`CancellationTokenSource`, `RelativePattern`, `ThemeColor`, `ThemeIcon`,
`StatusBarAlignment`, `ProgressLocation`, `ConfigurationTarget`,
`EndOfLine`, `ExtensionMode`, `LanguageStatusSeverity`, `TextDocument` (the
documents store: `getText(range?)`, `lineAt`, `lineCount`, `offsetAt`,
`positionAt`, `validateRange`, `getWordRangeAtPosition`, `uri`, `fileName`,
`languageId`, `version`, `isDirty`, `isUntitled`, `eol`; `save()` is not
supported: the buffer belongs to Neovim, so it logs and resolves `false`).

Proof required before the host is called done: with the Prettier extension
from Open VSX unpacked in a sandbox, a headless Neovim that starts the host
through `vim.lsp.start` formats a JavaScript buffer with `vim.lsp.buf.format`
and the buffer text changes to Prettier's output; plus a synthetic extension
under `tests/exthost/fixtures/` exercising completion, hover, diagnostics and
a command, driven by `tests/exthost/run.mjs` (Node only, no Neovim) that
speaks LSP to the host over a pipe. Both are opt-in tests documented in
their headers; the synthetic one runs in CI.

## The window

Bridge events (Neovim -> shell), all through `rpcnotify(chan, "nvs", event, payload)`:

- `vsx`: `{ installed = vsx.list(), status = vsx.status() }`, sent on setup and
  after every install, uninstall, enable and setting change.
- `vsx_search`: `{ query, results, error }`.
- `vsx_progress`: `{ id, stage, message }`.

Shell -> Neovim, through `nvim_exec_lua`: `require("nvs.bridge").vsx("search", query)`,
`vsx("install", id)`, `vsx("uninstall", id)`, `vsx("enable", id, true|false)`,
`vsx("refresh")`.

The Plugins screen gains a **Browse** tab (search box, results with tier
guesses where the registry metadata allows one, Install), shows installed
extensions in the **Installed** tab tagged `VSX` with their tier, and the
detail pane shows: how it runs (the tier sentence from the table above), what
was converted or skipped, the Neovim-native alternative when known, and
Enable/Disable/Uninstall. Settings > Plugins gains `exthost` (On demand /
Always / Never), `openvsx` (registry URL) and `vsx_node` (path to node).

## Out of scope, still

Webviews (`t3`), the marketplace's proprietary extensions that are not on
Open VSX, extension-to-extension APIs, and running an extension's `browser`
entry.
