# The extension host

`runtime/exthost/` runs one VS Code extension for nvs.ide. Neovim starts it as a
language server; the extension sees a `vscode` module; the host turns what the
extension registers into LSP answers. Plain JavaScript for Node 18.19 or newer,
CommonJS, no dependencies, no build step. The contract it implements is
`docs/extensions.md`, section "The extension host".

```
host.js       entry: flags, log, stdout guard, module hooks, activation, LSP handlers
lsp.js        JSON-RPC 2.0 over stdio with Content-Length framing
vscode.js     the `vscode` module: types, namespaces, registries, LSP conversions
documents.js  the TextDocument store, synced from textDocument/did* notifications
package.json  { "type": "commonjs" } so these files load as CommonJS from any folder
```

## Starting it

```
node host.js --extension <dir> --data <vsxdir> --log <file> [--settings <json-file>] --stdio
```

| flag | meaning |
|---|---|
| `--extension <dir>` | the unpacked extension folder: `<dir>/package.json` is read, `main` is loaded relative to it. Required. |
| `--data <vsxdir>` | the vsx folder. Extension state lands in `<vsxdir>/state/<publisher.name>/` (`globalState.json`, `workspaceState.json`, `config.json`, `globalStorage/`, `workspaceStorage/<hash>/`). Defaults to two folders above `--extension`. |
| `--log <file>` | the log file, appended to; past 1 MB it moves to `<file>.1` when the host starts (two files at most). Without it the log goes to stderr (Neovim keeps that in its own LSP log). |
| `--settings <file>` | a JSON file with the person's settings, either flat dotted keys (`{"prettier.semi": false}`) or nested (`{"prettier": {"semi": false}}`). Optional. |
| `--stdio` | speak LSP on stdin/stdout. It is the only transport, so it is accepted and assumed. |

From Neovim, as `runtime/lua/nvs/vsx.lua` does it:

```lua
vim.lsp.config("vsx_prettier", {
  cmd = { "node", runtime .. "/exthost/host.js", "--extension", dir, "--data", vsxdir, "--log", logfile, "--stdio" },
  filetypes = { "javascript", "typescript", "json", "css", "markdown", "yaml" },
})
vim.lsp.enable("vsx_prettier")
```

The host exits when stdin closes (Neovim is gone), on `exit`, and with code 1 on
`exit` without a preceding `shutdown`. `shutdown` disposes the extension's
subscriptions and calls its `deactivate` (given two seconds).

## What happens at startup

1. `require("vscode")` and `import ... from "vscode"` are both pointed at `vscode.js`:
   a `Module._resolveFilename` hook covers CommonJS, and a `module.register` resolve
   hook (loaded from a `data:` URL, so there is no extra file) covers ESM. Prettier
   ships as ESM (`"type": "module"`), which is why the second hook exists. Both paths
   hand out the same module instance.
2. `process.stdout.write` is replaced by a logger and `console.*` is redirected to
   the log, so an extension cannot put bytes between LSP frames. The transport keeps
   the original write.
3. On `initialize` the host reads the client's capabilities and workspace folders,
   builds the `ExtensionContext`, loads `main` (`import()` for ESM, `require()` for
   CommonJS) and awaits `activate(context)`, for at most 20 seconds. Then it answers
   with the capabilities that match what was registered: `completionProvider` (trigger
   characters, resolve), `hoverProvider`, `definitionProvider`, `declarationProvider`,
   `implementationProvider`, `typeDefinitionProvider`, `referencesProvider`,
   `documentHighlightProvider`, `documentSymbolProvider`, `workspaceSymbolProvider`,
   `codeActionProvider` (kinds, resolve), `codeLensProvider`, `documentLinkProvider`,
   `foldingRangeProvider`, `renameProvider` (prepare), `signatureHelpProvider`,
   `documentFormattingProvider`, `documentRangeFormattingProvider`,
   `executeCommandProvider` (the commands registered through
   `vscode.commands.registerCommand`), incremental `textDocumentSync` and
   `positionEncoding: "utf-16"` (VS Code positions are UTF-16 code units, like
   JavaScript strings, so nothing is converted).
4. If `activate` throws, the error is logged, the person gets a `window/showMessage`
   error, and `initialize` is answered with `capabilities: {}`. The host keeps
   running so Neovim's client does not error.
5. After `initialized`, the host asks `workspace/configuration` for every top-level
   section the extension contributes (Neovim answers from `vim.lsp.config.settings`)
   and fires `onDidChangeConfiguration` if anything changed.

Providers registered after the `initialize` response are announced with
`client/registerCapability` when the client's capabilities allow dynamic
registration for that method, and withdrawn with `client/unregisterCapability` on
dispose. The host reads the client's capabilities rather than assuming; for the
record, Neovim 0.12.1 (`runtime/lua/vim/lsp/protocol.lua`) registers these
dynamically: hover, definition, formatting, range formatting, code action, rename,
inlay hint, pull diagnostics and document colour. It does NOT for completion,
signature help, references, document highlight, document symbol, workspace symbol,
code lens, document link, folding range, selection range, linked editing range,
on-type formatting, call hierarchy, semantic tokens, inline completion, file
operations and configuration changes. A late registration of one of those is logged
as unreachable until the host restarts. Commands registered late are logged too:
Neovim only executes commands listed in the initialize result.

An `activate()` that awaits a request the host may send only after `initialized`
(workspace/configuration, workspace/applyEdit, window/showDocument,
window/workDoneProgress/create) makes the host answer `initialize` at once with what
is registered so far, rather than wait out the 20 s activation timeout; the log says
which request it was. What activate registers afterwards follows the rule above.

## Settings

`workspace.getConfiguration(section)` merges, lowest first: the defaults from the
extension's `contributes.configuration` (a property without `default` gets the
default of its type: `false`, `0`, `""`, `[]`, `{}`), values the extension wrote with
`config.update()` (persisted in `<vsxdir>/state/<id>/config.json`), the `--settings`
file, and what the client sent (`initializationOptions.settings`,
`workspace/didChangeConfiguration`, `workspace/configuration`). Keys are looked up
dotted, so `getConfiguration("prettier").get("semi")` and
`getConfiguration().get("prettier.semi")` agree. Language-scoped overrides
(`"[javascript]": {...}`) are ignored.

## What is routed where

| the extension calls | Neovim sees |
|---|---|
| `languages.register*Provider` | the capability above, requests routed by `DocumentSelector` match (string, `{ language, scheme, pattern }`, `RelativePattern`, arrays; best score first). Hover, definition-like and reference results from several providers are merged; formatting takes the first provider that answers. |
| `languages.createDiagnosticCollection` | `textDocument/publishDiagnostics` (collections for the same uri are merged) |
| `window.show{Information,Warning,Error}Message` | `window/showMessage`, or `window/showMessageRequest` when choices are offered (the chosen title comes back as the item) |
| `window.showQuickPick` | `window/showMessageRequest` with the labels as actions (`vim.ui.select`) |
| `window.createOutputChannel` | each line to the log file and `window/logMessage` |
| `window.createStatusBarItem` | its text to the log and `window/logMessage` when shown or changed (there is no status bar to draw it in) |
| `window.withProgress` | `window/workDoneProgress/create` and `$/progress` begin/report/end |
| `window.showTextDocument`, `commands.executeCommand("vscode.open")`, `env.openExternal` | `window/showDocument` (`external` for http(s)) |
| `workspace.applyEdit`, the editor from `showTextDocument` | `workspace/applyEdit` |
| `workspace.fs`, `findFiles`, `createFileSystemWatcher`, `openTextDocument` | the real file system (`fs.watch` recursive for watchers; files opened from disk are adopted by `didOpen` later) |
| `commands.registerCommand` | `workspace/executeCommand` |
| `commands.executeCommand("setContext", ...)`, `editor.action.formatDocument`, `workbench.action.files.save` | accepted, no-op |

Requests carry a `CancellationToken` that `$/cancelRequest` cancels. Items handed
to the client (completion, code action, code lens, document link) carry
`data: { gen, nvs }` so the resolve requests find the original objects.

Not implemented, on purpose: webviews, tree views, terminals, text editor
decorations, input boxes, dialogs, `env.clipboard` (resolves empty), notebooks,
debugging, tasks, tests, chat and language models, `TextDocument.save()`. Every one
of those is a phantom (see below), so an extension that touches them keeps running.

## The log

One line per entry, appended to `--log`:

```
<ISO-8601 UTC time> <LEVEL> <message>
2026-09-25T13:02:11.417Z INFO  nvs-exthost 0.1.0 on node v24.15.0 for esbenp.prettier-vscode 12.4.0 at C:\...\esbenp.prettier-vscode
2026-09-25T13:02:11.420Z INFO  initialize from Neovim 0.12.1; workspace C:\Users\you\project
2026-09-25T13:02:12.180Z DEBUG registered formatting provider formatting-2 for [{"language":"javascript"},...]
2026-09-25T13:02:12.181Z INFO  activated esbenp.prettier-vscode in 45 ms (esm)
2026-09-25T13:02:12.182Z INFO  capabilities: positionEncoding, textDocumentSync, codeActionProvider, documentFormattingProvider, ...
2026-09-25T13:02:12.190Z WARN  unsupported: vscode.window.createTreeView
2026-09-25T13:02:15.301Z INFO  [Prettier] ["INFO" - 1:02:15 PM] Formatting file:///c%3A/...
```

Levels: `ERROR` (an extension threw, a request failed, activation failed), `WARN`
(unsupported members, late registrations, stray stdout writes), `INFO` (lifecycle,
registrations, output channels, status bar, `console.*` from the extension) and
`DEBUG` (configuration changes, provider bookkeeping). A multi-line message is
indented under its first line. Continuation lines start with six spaces.

`unsupported: vscode.<path>` is logged once per path and names the API member an
extension touched that the shim does not implement. The value it received is a
phantom: callable, awaitable (resolves to `undefined`), disposable, and every
property of it is another phantom, so the extension keeps running instead of
crashing. When a real extension logs one of these, that line is the to-do list.

## Testing

- `node tests/exthost/run.mjs`: Node only, no Neovim, runs in CI. A synthetic
  extension (`tests/exthost/fixtures/nvs.synthetic`) exercises completion, hover,
  diagnostics, a command with progress, formatting, a code action, settings from the
  client and from `--settings`, dynamic registration, state on disk, stdout hygiene
  and the unsupported-member log line; `nvs.throws` proves a throwing `activate`
  still answers `initialize`. Also: a request before `initialize` is refused, an
  unknown method is refused, closing stdin ends the process.
- `tests/exthost/prettier_probe.lua`: opt-in, a headless Neovim in the sandbox
  formats a JavaScript buffer through the real Prettier extension. Its header says
  how to run it.
