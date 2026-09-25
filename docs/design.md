# nvs.ide design

nvs.ide is a stepping stone from VS Code to Neovim. It's stock Neovim running
LazyVim, with a layer of VS Code-style hand-holding that fades out as the user
learns, and eventually a native window with VS Code's workbench around it.

## Where it comes from

The original idea was to combine neovim/neovim and vscodium/vscodium. They can't
be merged as code, because **VSCodium contains no editor**: it's build scripts
and patches that repackage Microsoft's VS Code (Electron) without telemetry and
point it at the Open VSX registry. So each project does a different job:

| Project | What nvs.ide takes |
|---|---|
| neovim/neovim | The whole editing engine, unforked, embedded over its msgpack-RPC UI protocol |
| LazyVim/LazyVim | The plugin set and defaults: finder, explorer, completion, LSP, git, formatting |
| neovide/neovide | The starting point for the native window (Phase 1) |
| vscodium/vscodium | The Open VSX registry, the no-telemetry policy and the licensing approach |

Most "VS Code features" are external servers speaking open protocols: language
features over LSP and debugging over DAP. Neovim speaks both. What's missing for
a VS Code user is the workbench and the hand-holding, and that's the product.

## The transition layer (runtime/, works today)

### Stages

`:NvsStage 1-4`, stored in `stdpath("data")/nvs-ide.json`.

| Stage | Files open in | VS Code shortcuts | Coach |
|---|---|---|---|
| 1 · VS Code keys | Insert mode; Esc stays there | Ctrl+S, Z, /, P, F, B, Shift+K, Shift+F, Shift+P, F1 | On |
| 2 · Hybrid | Insert mode; Esc gives Normal | Same set | On |
| 3 · Modal with safety net | Normal mode | Same set | On |
| 4 · Pure Neovim | Normal mode | None; LazyVim's own keys | Quiet |

`lua/nvs/stages.lua` records any mapping it replaces (LazyVim's Ctrl+/
terminal, its Insert-mode Esc) and restores it when the stage changes. A
first-run welcome asks "where are you coming from?" and picks the stage.

### Coach

`lua/nvs/coach.lua`. Each VS Code-style shortcut also shows the Vim way once in
a notification ("Ctrl+Shift+K deleted the line. In Normal mode: dd"). Runs of
six or more arrow presses suggest counts (6j). Frequency: every time, first
three times, once, or off. Silent at Stage 4.

### Ask

`lua/nvs/ask.lua`, answers in `kb/ask.json`.

- 77 written answers, each with the phrasings people use, the Vim keys, the VS
  Code keys and an optional Ex command for Try it.
- Matching: normalise words (synonyms such as "yank" to "copy", stop words
  removed), then score each phrasing by IDF-weighted overlap in both
  directions. No network, no model.
- Below the confidence threshold, if local AI is on, the question goes to
  the local model with the closest written answers as context. Any `:command` in the reply is
  offered through a picker and runs only when chosen.
- Opens with F1 (Stages 1 to 3), `Space ?` or `:NvsAsk <question>`.

### Lessons

`tutor/nvs-ide.tutor` runs in Neovim's own tutor engine (`:NvsTutor`). Nine
lessons for VS Code users; exercise lines are checked against
`nvs-ide.tutor.json` and flip from ✗ to ✓.

### Completion and local AI

- blink.cmp (LazyVim's default) with documentation shown automatically and
  inline ghost text for the selected item.
- minuet-ai.nvim for Copilot-style ghost text from the local model, loaded
  only when `:NvsAI on`. Alt+A accepts. On llama.cpp, nvs.ide builds the
  fill-in-the-middle prompt for the model family (Qwen, DeepSeek, CodeLlama,
  StarCoder, CodeGemma); Ollama applies its own template.
- `lua/nvs/ai.lua` has three backends, all spoken to through the
  OpenAI-compatible API with curl through `vim.system`:
  - **llamacpp (default):** nvs.ide starts llama.cpp's `llama-server` in router
    mode (`--models-dir`) on 127.0.0.1. Every GGUF in the models folder is listed
    and loaded on first use, up to `models_max` at once. This gives Ollama's
    "run any model" without Ollama. `:NvsModel pull owner/repo:quant` looks the
    file up through the Hugging Face API, downloads it, and restarts the server,
    because the router only scans the folder at start. The server starts lazily
    and stops on `VimLeavePre`.
  - **ollama:** an Ollama server, default `http://localhost:11434`.
  - **openai:** any other OpenAI-compatible server (LM Studio, vLLM, llamafile),
    with an optional API key read from an environment variable.
- A model on another machine is reached by forwarding its port over SSH, never
  by opening it on the network.

## The native window (Phase 1 onward)

```
+--------------------------------------------------------------+
|  nvs.ide shell  (Rust, Neovide fork, GPU-rendered)           |
|  workbench chrome, Settings, Plugins, Ask, coach             |
+-----------+-----------------------------+--------------------+
            | msgpack-RPC (stdio)         | JSON-RPC (on demand)
+-----------v-----------+      +----------v---------------------+
|  nvim --embed          |<---->|  extension host (Node, optional)|
|  runtime/ (LazyVim +   |      |  subset of the vscode API,      |
|  nvs layer + bridge)   |      |  Open VSX extensions            |
+------------------------+      +--------------------------------+
```

- The shell renders Neovim's grids (`ext_multigrid`) and replaces the
  cmdline, popup menu and messages with native widgets.
- `lua/nvs/bridge.lua` streams diagnostics, symbols, tabs, debug state and
  option changes to the shell with `rpcnotify`. Shell actions go back as
  Neovim commands, so everything stays scriptable.
- **Settings screen:** 15 categories and 74 settings, searchable by Vim name,
  with User and Workspace scopes. It writes `lua/nvs/settings.lua` and
  imports VS Code's `settings.json` and `keybindings.json`.
- **Plugins view:** a front end for lazy.nvim and `:LazyExtras`, plus Open VSX.
  Searching a VS Code extension name finds the Neovim equivalent.
- **Extension host:** Tier 1 declarative contributions (themes, snippets,
  grammars) convert at install time; Tier 2 providers run in Node and reach
  Neovim as a virtual LSP server; Tier 3 webviews are deferred. The host only
  runs while a Tier 2 extension is installed.

## Budgets

- Cold start to an editable buffer under 150 ms, extension host not running.
- Idle memory under 80 MB without the extension host.
- The shell never blocks on Neovim.

## Look

The necronomicon palette (also `runtime/colors/necronomicon.lua`),
BigBlueTerm437 Nerd Font Mono, Win98 bevels, no rounded corners, icons drawn
rather than emoji.

## Phases

0. Design preview and the runtime (done)
1. Shell MVP: Neovide fork, workbench layout, native cmdline and messages
2. Panels: Problems, Outline, Search, Git, Terminal, Debug; Ask and coach in the window
3. Settings and Plugins screens
4. Extension host
5. Packaging, Windows first

## License

MIT (see LICENSE). nvs.ide is a community tool: forks, extra Ask answers and
new lessons are welcome.
